# ============================================================
# 一键同步部署脚本（开发机执行）
#
# 功能：在开发机重新构建镜像 → 导出 → 传到服务器 → 加载 → 重启 → 验证
#
# 用法（PowerShell）：
#   .\sync-deploy.ps1                    # 同步所有（frontend + backend + nginx）
#   .\sync-deploy.ps1 -Backend           # 只同步 backend
#   .\sync-deploy.ps1 -Frontend          # 只同步 frontend
#   .\sync-deploy.ps1 -Nginx             # 只同步 nginx
#   .\sync-deploy.ps1 -BuildOnly         # 只构建导出，不传服务器
#   .\sync-deploy.ps1 -SetupKey          # 【一次性】配置 SSH 密钥免密登录（见下方说明）
#
# 免密部署（重要）：
#   本脚本会多次调用 ssh/scp。为避免反复输密码，请先配置密钥免密登录：
#     .\sync-deploy.ps1 -SetupKey        # 只需运行一次，会引导输入一次服务器密码
#   之后所有部署（含本脚本）都自动免密，无需再装任何工具。
#   原理：把本机 ~/.ssh/id_ed25519.pub 装到服务器的 authorized_keys。
#   ⚠ Windows 上 SSH ControlMaster 多路复用不可靠（MSYS2/原生均如此），
#      故采用密钥免密而非连接复用。
#
# 参数：
#   -ServerIp       服务器 IP（默认从 .sync-config.json 读，首次运行会问）
#   -ServerUser     SSH 用户（默认 root）
#   -ServerPath     镜像包目录（tar.gz + manage.sh 存放处，默认 /opt/dataAgent/deerflow-offline-bundle）
#   -RemoteRunDir   运行目录（实际跑的 compose + .env.docker + workspace，默认 /opt/dataAgent/compose）
#                   ⚠ 远程容器由 $RemoteRunDir/docker-compose.offline.yml 管理，必须与镜像包目录分开配置
#   -Port           服务器端口（默认从 .sync-config.json 读）
# ============================================================

param(
    [switch]$Backend,
    [switch]$Frontend,
    [switch]$Nginx,
    [switch]$BuildOnly,
    [switch]$FirstDeploy,
    [switch]$BackendOnly,
    [switch]$SetupKey,
    [string]$ServerIp,
    [string]$ServerUser = "root",
    # 镜像包目录（tar.gz + manage.sh + diagnose.sh 存放处）
    [string]$ServerPath = "/opt/dataAgent/deerflow-offline-bundle",
    # 运行目录（实际跑的 compose + .env.docker + workspace）
    # 远程实际由 /opt/dataAgent/compose/docker-compose.offline.yml 管理容器，
    # 与镜像包目录分离，故独立配置。改这个值以适配不同服务器布局。
    [string]$RemoteRunDir = "/opt/dataAgent/compose",
    [string]$Port
)

$ErrorActionPreference = 'Stop'
$ScriptDir  = $PSScriptRoot
$DeerflowRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$SqlQueryRoot = if ($env:SQLQUERY_ROOT) { $env:SQLQUERY_ROOT } else { 'C:\Users\L\Documents\smartquerydata' }
$ConfigFile = Join-Path $ScriptDir '.sync-config.json'
$TempDir = Join-Path $env:TEMP 'dataagent-sync'

# ---- 颜色（提前定义，供 SetupKey 等早期流程使用）----
function Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  OK $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "  X $msg" -ForegroundColor Red }

# ---- SSH 免密密钥（默认用 ~/.ssh/id_ed25519，退化到 id_rsa）----
$DefaultKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if (-not (Test-Path $DefaultKey)) {
    $rsaKey = Join-Path $env:USERPROFILE '.ssh\id_rsa'
    if (Test-Path $rsaKey) { $DefaultKey = $rsaKey }
}

# ---- 配置文件管理 ----
function Load-Config {
    if (Test-Path $ConfigFile) {
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

# ---- 读取/确认服务器配置 ----
$cfg = Load-Config
if (-not $ServerIp) {
    if ($cfg -and $cfg.ServerIp) {
        $ServerIp = $cfg.ServerIp
        Write-Host "使用上次的服务器 IP：$ServerIp（删除 .sync-config.json 可重置）" -ForegroundColor DarkGray
    } else {
        $ServerIp = Read-Host "请输入服务器 IP（如 10.15.70.124）"
    }
}

# ============================================================
# -SetupKey 模式：一次性配置 SSH 密钥免密登录
# ============================================================
# 把本机公钥装到服务器 authorized_keys，之后所有部署免密。
# 只需运行一次；已配置则幂等跳过。
if ($SetupKey) {
    Write-Host "============================================================" -ForegroundColor White
    Write-Host " 配置 SSH 密钥免密登录" -ForegroundColor White
    Write-Host " 服务器: $ServerUser@$ServerIp" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor White

    # 1. 本机没有密钥就生成一个（无 passphrase，方便自动化）
    if (-not (Test-Path $DefaultKey)) {
        Step "本机未找到 SSH 密钥，生成新的 ed25519 密钥（无 passphrase）..."
        & ssh-keygen -t ed25519 -N '""' -f (Join-Path $env:USERPROFILE '.ssh\id_ed25519') -C "$env:USERNAME@dataagent-deploy"
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 生成密钥失败" }
        $DefaultKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
        OK "密钥已生成：$DefaultKey"
    } else {
        OK "使用已有密钥：$DefaultKey"
    }

    # 2. 先探测免密是否已经配好（幂等：配过就直接退出，不重复要密码）
    Step "检测免密登录是否已配置..."
    # 探测失败是预期的（公钥还没装），用 try/catch 接住，不让 Stop 模式的 stderr 异常中断流程
    $keyTest = $null
    try {
        $keyTest = & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${ServerUser}@${ServerIp}" 'echo KEYAUTH_OK' 2>$null
    } catch {
        # 探测失败 = 免密未配置，继续往下装公钥
    }
    if ($keyTest -and ($keyTest -match 'KEYAUTH_OK')) {
        OK "免密登录已配置，无需重复操作。直接跑 .\sync-deploy.ps1 即可。"
        exit 0
    }
    Warn "尚未配置免密，下面需要输入两次服务器密码来完成配置（一次性操作）。"

    # 3. 安装公钥到服务器 authorized_keys
    # ⚠ 不用 ssh-copy-id：它是无扩展名的 shell 脚本，PowerShell 无法直接执行
    #    （报「无法在管道中间运行文档」）。
    #    改用「scp 传公钥到临时文件 → 远程 append 到 authorized_keys」两步法，
    #    完全避免把公钥内联进命令字符串（两层 shell 解析会出转义问题）。
    Step "安装公钥到服务器（第 1/2 次密码：传输公钥）..."
    $pubKeyFile = "$DefaultKey.pub"
    $remoteTmpKey = "/tmp/.dataagent-pubkey-$([guid]::NewGuid().ToString('N').Substring(0,8)).pub"

    # 3a. scp 公钥到服务器临时位置（用密码认证，会要求输入密码）
    # -q 抑制进度（scp 进度走 stderr，Stop 模式会误触发异常）；try/catch 兜底接住 stderr 异常
    $scpOk = $true
    try {
        & scp -q -o StrictHostKeyChecking=accept-new $pubKeyFile "${ServerUser}@${ServerIp}:$remoteTmpKey" 2>$null
        if ($LASTEXITCODE -ne 0) { $scpOk = $false }
    } catch {
        $scpOk = $false
    }
    if (-not $scpOk) { throw "公钥传输失败（检查密码/IP）" }

    # 3b. 远程：确保 ~/.ssh 存在 → 去重后追加公钥 → 设权限 → 删临时文件
    #     公钥内容全程不经过 shell 解析（用 cat 读临时文件），安全无转义问题。
    Step "安装公钥到服务器（第 2/2 次密码：写入 authorized_keys）..."
    $installCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF -f '$remoteTmpKey' ~/.ssh/authorized_keys 2>/dev/null || cat '$remoteTmpKey' >> ~/.ssh/authorized_keys ; rm -f '$remoteTmpKey'"
    $installOk = $true
    try {
        & ssh -o StrictHostKeyChecking=accept-new "${ServerUser}@${ServerIp}" $installCmd 2>$null
        if ($LASTEXITCODE -ne 0) { $installOk = $false }
    } catch {
        $installOk = $false
    }
    if (-not $installOk) {
        # 清理可能残留的临时文件
        try { & ssh "${ServerUser}@${ServerIp}" "rm -f '$remoteTmpKey'" 2>$null } catch {}
        throw "公钥安装失败（检查密码/IP）"
    }
    OK "公钥已安装"

    # 4. 验证免密生效
    Step "验证免密登录..."
    $verify = $null
    try {
        $verify = & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${ServerUser}@${ServerIp}" 'echo KEYAUTH_OK' 2>$null
    } catch {
        # 验证失败 = 免密没生效，走下面的错误提示
    }
    if ($verify -and ($verify -match 'KEYAUTH_OK')) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host " 免密配置完成！以后部署直接运行：" -ForegroundColor Green
        Write-Host "   .\sync-deploy.ps1" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        exit 0
    } else {
        Err "免密验证失败。可能原因：服务器 sshd 禁用了 PubkeyAuthentication，或 authorized_keys 权限不对。"
        Write-Host "排查：ssh ${ServerUser}@${ServerIp} 'cat /etc/ssh/sshd_config | grep -i pubkey'" -ForegroundColor DarkGray
        exit 1
    }
}

# ---- 预检：确认 SSH 免密已配置（在第一次 ssh 之前，覆盖 FirstDeploy 端口检查）----
# BuildOnly 不连服务器，跳过；其余模式必须先配好免密，否则跑到一半会反复要密码。
if (-not $BuildOnly) {
    Step "检查 SSH 免密登录..."
    # BatchMode=yes：禁用交互式认证。密钥免密没配好就立即失败，不会卡在密码提示。
    # try/catch 接住 Stop 模式下原生程序 stderr 触发的异常，转为可控的报错提示。
    $probe = $null
    try {
        $probe = & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${ServerUser}@${ServerIp}" 'echo KEYAUTH_OK' 2>$null
    } catch {
        $probe = $null
    }
    if (-not $probe -or ($probe -notmatch 'KEYAUTH_OK')) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host " SSH 免密未配置！" -ForegroundColor Red
        Write-Host " 本脚本会多次调用 ssh/scp，未配置免密会被反复要求输入密码。" -ForegroundColor Yellow
        Write-Host " 请先运行一次（只需一次，会引导输入服务器密码）：" -ForegroundColor Yellow
        Write-Host "   .\sync-deploy.ps1 -SetupKey" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        throw "SSH 免密未配置，请先运行：.\sync-deploy.ps1 -SetupKey"
    }
    OK "免密登录正常"
}

# ---- 端口确认（首次部署时交互输入 + 检查占用）----
function Test-RemotePort($ip, $port) {
    # 在服务器上检查端口是否被占用
    $result = & ssh "${ServerUser}@${ip}" "ss -tlnp 2>/dev/null | grep ':$port ' | head -1 || echo 'FREE'"
    $line = $result.ToString().Trim()
    if ($line -eq "FREE" -or [string]::IsNullOrWhiteSpace($line)) {
        return $false  # 没被占用
    } else {
        return $true   # 被占用了
    }
}

if ($FirstDeploy) {
    # 首次部署：交互式配置所有端口
    Write-Host ""
    Write-Host "========== 端口配置 ==========" -ForegroundColor Cyan

    # --- 对外访问端口（nginx 或 backend-only 模式下直接是 backend）---
    $defaultPort = if ($cfg -and $cfg.Port) { $cfg.Port } else { "8098" }
    $Port = Read-Host "请输入对外访问端口（默认 $defaultPort，回车使用默认）"
    if ([string]::IsNullOrWhiteSpace($Port)) { $Port = $defaultPort }

    $portOK = $false
    while (-not $portOK) {
        Write-Host "  检查对外端口 $Port ..." -NoNewline
        if (Test-RemotePort $ServerIp $Port) {
            Write-Host " 已占用！" -ForegroundColor Red
            $Port = Read-Host "  端口被占用，请重新输入"
        } else {
            Write-Host " 可用" -ForegroundColor Green
            $portOK = $true
        }
    }

    if ($BackendOnly) {
        # 纯后端模式：对外端口 = backend 端口（直接映射）
        $BackendPort = $Port
        Write-Host "  对外端口（= backend 端口）: $Port" -ForegroundColor DarkGray
    } else {
        # 完整模式：对外端口是 nginx，backend 是内部端口
        $defaultBackendPort = if ($cfg -and $cfg.BackendPort) { $cfg.BackendPort } else { "8003" }
        Write-Host ""
        Write-Host "  backend 内部端口（nginx 反代到这个端口）" -ForegroundColor DarkGray
        $BackendPort = Read-Host "请输入 backend 端口（默认 $defaultBackendPort，回车使用默认）"
        if ([string]::IsNullOrWhiteSpace($BackendPort)) { $BackendPort = $defaultBackendPort }

        if ($BackendPort -eq $Port) {
            Write-Host "  backend 端口不能和对外端口一样！" -ForegroundColor Red
            $BackendPort = Read-Host "  请重新输入 backend 端口"
        }
        Write-Host "  对外端口: $Port | backend 端口: $BackendPort" -ForegroundColor DarkGray
    }
} else {
    # 更新部署：使用已有端口
    if (-not $Port) {
        if ($cfg -and $cfg.Port) { $Port = $cfg.Port } else { $Port = "8098" }
    }
    $BackendPort = if ($cfg -and $cfg.BackendPort) { $cfg.BackendPort } else { "8003" }
    if ($BackendOnly) { $BackendPort = $Port }
}

# 保存配置供下次使用
Save-Config @{ ServerIp = $ServerIp; Port = $Port; BackendPort = $BackendPort; BackendOnly = $BackendOnly }

# ---- 决定构建哪些 ----
$buildAll = -not ($Backend -or $Frontend -or $Nginx)
$doFrontend = $buildAll -or $Frontend
$doBackend  = $buildAll -or $Backend
$doNginx    = $buildAll -or $Nginx

# ---- 生成 BETTER_AUTH_SECRET ----
$authSecret = if ($env:BETTER_AUTH_SECRET) {
    $env:BETTER_AUTH_SECRET
} else {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ---- Docker 镜像构建 ----
function Build-Image($Name, $Dockerfile, $Tag, $Context, $ExtraArgs) {
    Step "构建 $Name ..."
    $args = @('build', '--platform', 'linux/amd64', '-f', $Dockerfile, '-t', $Tag)
    if ($ExtraArgs) { $args += $ExtraArgs }
    $args += $Context
    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "$Name 构建失败" }
    OK "$Name 构建完成"
}

# ---- 导出镜像为 tar.gz ----
function Export-Image($Tag, $OutName) {
    $tarPath = Join-Path $TempDir "$OutName.tar"
    $gzPath = Join-Path $TempDir "$OutName.tar.gz"
    Step "导出 $Tag ..."
    docker save $Tag -o $tarPath
    if ($LASTEXITCODE -ne 0) { throw "导出失败：$Tag" }
    $srcBytes = [System.IO.File]::ReadAllBytes($tarPath)
    $outStream = [System.IO.File]::Create($gzPath)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
        try { $gz.Write($srcBytes, 0, $srcBytes.Length) } finally { $gz.Close() }
    } finally { $outStream.Close() }
    Remove-Item $tarPath -Force
    $sizeMB = [math]::Round((Get-Item $gzPath).Length / 1MB, 1)
    OK "$OutName.tar.gz ($sizeMB MB)"
    return $gzPath
}

# ---- SCP 传输 ----
function Send-File($LocalPath, $RemotePath) {
    $fileName = Split-Path $LocalPath -Leaf
    Step "传输 $fileName 到 $ServerIp ..."
    & scp $LocalPath "${ServerUser}@${ServerIp}:$RemotePath"
    if ($LASTEXITCODE -ne 0) { throw "SCP 传输失败：$fileName" }
    OK "传输完成"
}

# ---- SSH 执行远程命令 ----
function Invoke-Remote($Command) {
    & ssh "${ServerUser}@${ServerIp}" $Command
    if ($LASTEXITCODE -ne 0) { Warn "远程命令返回非零（可能正常）" }
}

# ============================================================
# 主流程
# ============================================================

# 首次部署时强制全部构建（BackendOnly 模式只构建 backend）
if ($FirstDeploy -and -not $BackendOnly) {
    $doFrontend = $true
    $doBackend = $true
    $doNginx = $true
}
if ($BackendOnly) {
    $doFrontend = $false
    $doBackend = $true
    $doNginx = $false
}

$modeLabel = if ($BackendOnly) { "纯后端（无前端无nginx）" } elseif ($FirstDeploy) { "首次部署" } else { "更新" }
Write-Host "============================================================" -ForegroundColor White
Write-Host " DataAgent 一键同步部署（$modeLabel）" -ForegroundColor White
Write-Host " 服务器: $ServerIp (端口 $Port)" -ForegroundColor White
if (-not $BackendOnly) {
    Write-Host " 构建: $(if($doFrontend){'frontend '}$(if($doBackend){'backend '}$(if($doNginx){'nginx'})))" -ForegroundColor White
} else {
    Write-Host " 构建: backend only（对外端口=$Port = backend 端口）" -ForegroundColor White
}
Write-Host "============================================================" -ForegroundColor White

# 清理临时目录
if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir }
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

# ---- 1. 构建 + 导出 ----
$exportedFiles = @()

if ($doFrontend) {
    Build-Image "frontend" `
        (Join-Path $ScriptDir 'frontend.Dockerfile') `
        'deerflow-frontend:latest' `
        $DeerflowRoot `
        @('--build-arg', "NPM_REGISTRY=https://registry.npmmirror.com",
          '--build-arg', "COREPACK_NPM_REGISTRY=https://registry.npmmirror.com",
          '--build-arg', "BETTER_AUTH_SECRET=$authSecret")
    $exportedFiles += Export-Image 'deerflow-frontend:latest' 'deerflow-frontend'
}

if ($doBackend) {
    Build-Image "backend" `
        (Join-Path $SqlQueryRoot 'Dockerfile.backend') `
        'dataagent-backend:latest' `
        $SqlQueryRoot
    $exportedFiles += Export-Image 'dataagent-backend:latest' 'dataagent-backend'
}

if ($doNginx) {
    Build-Image "nginx" `
        (Join-Path $ScriptDir 'nginx\Dockerfile') `
        'deerflow-nginx:latest' `
        (Join-Path $ScriptDir 'nginx')
    $exportedFiles += Export-Image 'deerflow-nginx:latest' 'deerflow-nginx'
}

OK "构建+导出完成，共 $($exportedFiles.Count) 个镜像"

if ($BuildOnly) {
    Write-Host "`n镜像文件在：$TempDir" -ForegroundColor Yellow
    Write-Host "仅构建模式，不传输到服务器。" -ForegroundColor Yellow
    exit 0
}

# ---- 2. 传输到服务器 ----
$remoteImagesDir = "$ServerPath/images"
# compose/env 等运行时文件在 $RemoteRunDir（与镜像包目录分离），不再用 $remoteComposeDir
Invoke-Remote "mkdir -p $remoteImagesDir $RemoteRunDir"

# 首次部署：额外传输 compose + 配置 + 脚本
# compose/.env 传到运行目录 $RemoteRunDir；manage.sh/diagnose.sh 传到镜像包目录 $ServerPath
if ($FirstDeploy) {
    Step "传输部署文件（首次部署）..."
    Send-File (Join-Path $ScriptDir 'manage.sh') $ServerPath
    Send-File (Join-Path $ScriptDir 'diagnose.sh') $ServerPath
    Send-File (Join-Path $ScriptDir '.env.docker.example') $RemoteRunDir

    if ($BackendOnly) {
        # 纯后端模式：生成精简 compose（只有 backend，端口直接映射到宿主机）
        Step "生成纯后端 compose ..."
        $backendCompose = @"
version: "3.8"
services:
  backend:
    image: dataagent-backend:latest
    container_name: deerflow-backend
    restart: unless-stopped
    env_file:
      - .env.docker
    environment:
      FRONTEND_URL: "*"
    volumes:
      - ${WORKSPACE_DIR_PLACEHOLDER}:/app/workspace
    ports:
      - "${Port}:${BackendPort}"
    command: ["python3", "-m", "uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "${BackendPort}"]
    networks:
      - deerflow-net

networks:
  deerflow-net:
    driver: bridge
"@
        $composePath = Join-Path $TempDir 'docker-compose.backend-only.yml'
        [System.IO.File]::WriteAllText($composePath, $backendCompose, [System.Text.Encoding]::UTF8)
        Send-File $composePath $RemoteRunDir
        OK "纯后端 compose 已传输到 $RemoteRunDir（backend 直接映射 :${Port}）"
    } else {
        # 完整模式：传标准 compose + nginx.conf 到运行目录
        Send-File (Join-Path $ScriptDir 'docker-compose.offline.yml') $RemoteRunDir
        Send-File (Join-Path $ScriptDir 'nginx\nginx.conf') $RemoteRunDir
    }

    # 创建 .env.docker（如果运行目录还没有）
    Invoke-Remote "if [ ! -f $RemoteRunDir/.env.docker ]; then cp $RemoteRunDir/.env.docker.example $RemoteRunDir/.env.docker; echo 'created .env.docker'; else echo '.env.docker exists'; fi"

    if ($BackendOnly) {
        # 纯后端：只需要 WORKSPACE_DIR 和端口（配置在运行目录）
        Invoke-Remote @"
cd $RemoteRunDir
grep -q '^WORKSPACE_DIR=' .env.docker 2>/dev/null || echo 'WORKSPACE_DIR=$RemoteRunDir/data/workspace' >> .env.docker
mkdir -p data/workspace
chmod +x $ServerPath/manage.sh $ServerPath/diagnose.sh 2>/dev/null || true
echo 'configured for backend-only mode'
"@
    } else {
        # 完整模式：EXPOSE_PORT + WORKSPACE_DIR + compose/nginx 端口联动（都在运行目录）
        Invoke-Remote @"
cd $RemoteRunDir
# 设置 EXPOSE_PORT（覆盖已有值）
sed -i '/^EXPOSE_PORT=/d' .env.docker 2>/dev/null
echo 'EXPOSE_PORT=$Port' >> .env.docker
# 确保 WORKSPACE_DIR
grep -q '^WORKSPACE_DIR=' .env.docker 2>/dev/null || echo 'WORKSPACE_DIR=$RemoteRunDir/data/workspace' >> .env.docker
mkdir -p data/workspace
chmod +x $ServerPath/manage.sh $ServerPath/diagnose.sh 2>/dev/null || true

# 把 backend 端口写入 compose（command --port 和 expose）——compose 在运行目录
sed -i 's/--port [0-9]*/--port $BackendPort/' docker-compose.offline.yml
sed -i 's/- "[0-9]*"/- "$BackendPort"/' docker-compose.offline.yml

# 把 backend 端口写入 nginx.conf（upstream backend:PORT）——nginx.conf 在运行目录
sed -i 's/server backend:[0-9]*;/server backend:$BackendPort;/' nginx.conf

echo 'ports configured: EXPOSE_PORT=$Port BACKEND_PORT=$BackendPort'
"@
    }
    OK "部署文件已传输"

    # 提醒用户填配置（env 在运行目录）
    $envExists = & ssh "${ServerUser}@${ServerIp}" "grep -c 'change-me' $RemoteRunDir/.env.docker 2>/dev/null || echo 0"
    if ($envExists.ToString().Trim() -ne "0") {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host " .env.docker 还有占位符（change-me），请先编辑：" -ForegroundColor Yellow
        Write-Host "   ssh ${ServerUser}@${ServerIp} 'vim $RemoteRunDir/.env.docker'" -ForegroundColor Yellow
        Write-Host " 必改项：SYS_DATABASE_PASSWORD / OPENAI_API_KEY / AES_KEY / AES_IV" -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host ""
        $continue = Read-Host "配置好了吗？按回车继续部署，Ctrl+C 取消"
    }
}

foreach ($file in $exportedFiles) {
    Send-File $file $remoteImagesDir
}

# ---- 3. 远程加载 + 重启 ----
Step "远程加载镜像并重启..."

$reloadCmds = @()
$restartSvcs = @()

foreach ($file in $exportedFiles) {
    $fileName = Split-Path $file -Leaf
    $reloadCmds += "echo '  loading $fileName...' && gunzip -c $remoteImagesDir/$fileName | docker load"
}

if ($doFrontend) { $restartSvcs += "frontend" }
if ($doBackend)  { $restartSvcs += "backend" }
if ($doNginx)    { $restartSvcs += "nginx" }
# nginx 依赖 frontend+backend，一起重启（BackendOnly 模式不重启 nginx）
if (($doFrontend -or $doBackend) -and -not $BackendOnly) { $restartSvcs += "nginx" }
$restartSvcs = $restartSvcs | Select-Object -Unique

# 选择 compose 文件（基于运行目录 RemoteRunDir，而非镜像包目录）
# 远程实际运行的容器由 $RemoteRunDir/docker-compose.offline.yml 管理，
# 必须在 $RemoteRunDir 下执行 compose，否则 --force-recreate 会作用于错误位置。
if ($BackendOnly) {
    $composeFile = "$RemoteRunDir/docker-compose.backend-only.yml"
} else {
    $composeFile = "$RemoteRunDir/docker-compose.offline.yml"
}

$composeCmd = "docker compose -f $composeFile --env-file $RemoteRunDir/.env.docker up -d --force-recreate $($restartSvcs -join ' ')"

$remoteScript = @"
set -e
$($reloadCmds -join "`n")
echo 'restarting services (in $RemoteRunDir)...'
$composeCmd
sleep 5
echo 'done'
"@

Invoke-Remote $remoteScript
OK "服务器已更新并重启"

# ---- 4. 验证 ----
Step "验证服务状态..."

Start-Sleep -Seconds 3

# 远程检查
$checkOutput = & ssh "${ServerUser}@${ServerIp}" "curl -s -o /dev/null -w '%{http_code}' http://localhost:$Port/api/health 2>/dev/null || echo 'FAIL'"
$healthStatus = $checkOutput.ToString().Trim()

if ($healthStatus -eq "200") {
    OK "后端健康检查通过（200）"
} else {
    Warn "后端健康检查返回：$healthStatus"
}

# 校验容器实际跑的镜像 ID 与刚加载的镜像 ID 是否一致
# 防止"健康检查 200 但容器还在用旧镜像"的假成功（曾因 compose 路径错误导致）
if ($doBackend) {
    $runningImageId = & ssh "${ServerUser}@${ServerIp}" "docker inspect deerflow-backend --format '{{.Image}}' 2>/dev/null"
    $loadedImageId = & ssh "${ServerUser}@${ServerIp}" "docker inspect dataagent-backend:latest --format '{{.Id}}' 2>/dev/null"
    $runningImageId = $runningImageId.ToString().Trim()
    $loadedImageId = $loadedImageId.ToString().Trim()
    if ($runningImageId -and $loadedImageId -and $runningImageId -eq $loadedImageId) {
        OK "镜像已正确应用（容器运行的是最新 dataagent-backend:latest）"
    } else {
        Warn "镜像可能未生效！容器运行: $runningImageId"
        Warn "                最新镜像: $loadedImageId"
        Warn "排查: cd $RemoteRunDir && docker compose -f docker-compose.offline.yml --env-file .env.docker up -d --force-recreate backend"
    }
}

$containerStatus = & ssh "${ServerUser}@${ServerIp}" "docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep deerflow"
Write-Host "`n容器状态：" -ForegroundColor Cyan
Write-Host $containerStatus

# ---- 5. 汇总 ----
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 同步部署完成！" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "访问地址：http://$ServerIp`:$Port/" -ForegroundColor Yellow
Write-Host ""

if ($healthStatus -ne "200") {
    Write-Host "排查命令：" -ForegroundColor Yellow
    Write-Host "  ssh ${ServerUser}@${ServerIp} 'sh $ServerPath/diagnose.sh'" -ForegroundColor DarkGray
    Write-Host "  ssh ${ServerUser}@${ServerIp} 'docker logs deerflow-backend --tail 20'" -ForegroundColor DarkGray
}

# 清理临时目录
Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
