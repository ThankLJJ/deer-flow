# ============================================================
# 打包脚本（开发机执行）：构建镜像 → 组装离线包 → 产出单个 tar
#
# 与 build-and-export.ps1 的区别：
#   - 架构通过参数指定（amd64 / arm64），不再写死 linux/amd64
#   - 最终交付物是一个 tar 包（含镜像、compose、部署脚本、源码）
#   - 产出 SHA256 校验和（scp 传输后可校验完整性）
#
# 用法（PowerShell，在本目录下运行）：
#   .\build-package.ps1                        # 默认 linux/amd64，全量打包
#   .\build-package.ps1 -Arch arm64            # 打 arm64 包（跨架构走 QEMU，较慢）
#   .\build-package.ps1 -Arch amd64 -Backend   # 只打 backend 镜像的包
#   .\build-package.ps1 -Arch x86_64           # 别名，等价 amd64
#   .\build-package.ps1 -NoBuild               # 跳过构建，直接打包本地已有 :latest 镜像
#
# 参数：
#   -Arch         目标架构：amd64 | arm64（兼容 x86_64 / aarch64 别名），默认 amd64
#   -Backend      只构建/打包 backend 镜像
#   -Frontend     只构建/打包 frontend 镜像
#   -Nginx        只构建/打包 nginx 镜像
#                 （三个都不选 = 全量）
#   -NoBuild      不执行 docker build，直接导出本地已有镜像（会校验镜像架构是否匹配 -Arch）
#   -SqlQueryRoot sqlQuery 仓库根目录（默认读 $env:SQLQUERY_ROOT，再退回
#                 C:\Users\L\Documents\smartquerydata）
#   -OutDir       产物输出目录（默认脚本目录下 package-out\<arch>\）
#
# 产物结构（tar 内）：
#   deerflow-offline-bundle/
#   ├── images/<name>-<arch>.tar.gz    镜像（文件名保持 frontend/nginx/backend 子串，
#   │                                   deploy-offline.sh 按子串识别，勿改命名规则）
#   ├── compose/docker-compose.offline.yml + nginx.conf
#   ├── sqlquery-src/                  backend 源码（langgraph 容器挂载用）
#   ├── manage.sh / diagnose.sh / deploy-offline.sh
#   ├── .env.docker.example
#   └── BUILD-INFO.txt                 架构/时间/镜像 ID（溯源用）
#
# 服务器部署（与现有流程一致）：
#   scp deerflow-offline-bundle_<arch>_<ts>.tar root@server:/home/dataAgent/
#   ssh root@server 'cd /home/dataAgent && tar xf <包名> && cd deerflow-offline-bundle && ./deploy-offline.sh'
# ============================================================

param(
    [ValidateSet('amd64', 'arm64', 'x86_64', 'aarch64')]
    [string]$Arch = 'amd64',
    [switch]$Backend,
    [switch]$Frontend,
    [switch]$Nginx,
    [switch]$NoBuild,
    [string]$SqlQueryRoot = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

# ---- 架构归一化（x86_64→amd64, aarch64→arm64）----
$archMap = @{ 'x86_64' = 'amd64'; 'aarch64' = 'arm64' }
$Arch = if ($archMap.ContainsKey($Arch)) { $archMap[$Arch] } else { $Arch }
$Platform = "linux/$Arch"

# ---- 路径 ----
$ScriptDir    = $PSScriptRoot
$DeerflowRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $SqlQueryRoot) {
    $SqlQueryRoot = if ($env:SQLQUERY_ROOT) { $env:SQLQUERY_ROOT } else { 'C:\Users\L\Documents\smartquerydata' }
}
if (-not $OutDir) { $OutDir = Join-Path $ScriptDir (Join-Path 'package-out' $Arch) }

$BundleName = 'deerflow-offline-bundle'
$StagingDir = Join-Path $OutDir $BundleName

# ---- 镜像 tag（与 docker-compose.offline.yml 引用保持一致，勿加架构后缀）----
$FrontendImage = 'deerflow-frontend:latest'
$NginxImage    = 'deerflow-nginx:latest'
$BackendImage  = 'dataagent-backend:latest'

# ---- 构建参数 ----
$NpmRegistry = if ($env:NPM_REGISTRY) { $env:NPM_REGISTRY } else { 'https://registry.npmmirror.com' }
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$BetterAuthSecret = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

# ---- 输出辅助 ----
function Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  OK $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  !  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "  X  $msg" -ForegroundColor Red }

Write-Host "============================================================" -ForegroundColor White
Write-Host " DeerFlow 离线包打包（目标架构：$Platform）" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
Write-Host "DEERFLOW_ROOT  = $DeerflowRoot"
Write-Host "SQLQUERY_ROOT  = $SqlQueryRoot"
Write-Host "OUT_DIR        = $OutDir"
Write-Host "NO_BUILD       = $NoBuild"
Write-Host ""

# ---- 组件选择（默认全量）----
$buildAll = -not ($Backend -or $Frontend -or $Nginx)
$doFrontend = $buildAll -or $Frontend
$doBackend  = $buildAll -or $Backend
$doNginx    = $buildAll -or $Nginx

# ============================================================
# 预检
# ============================================================
Step "预检 ..."
try { docker info *> $null } catch {
    Err "Docker daemon 未运行，请先启动 Docker Desktop"
    throw "docker daemon 不可用"
}

# 本机架构（跨架构构建走 QEMU，提示较慢）
$serverArchRaw = (docker version --format '{{.Server.Arch}}' 2>$null)
$serverArch = if ($archMap.ContainsKey("$serverArchRaw")) { $archMap["$serverArchRaw"] } else { "$serverArchRaw" }
if ($serverArch -and $serverArch -ne $Arch) {
    Warn "目标架构 $Arch 与本机 Docker 架构 $serverArch 不同，跨架构构建通过 QEMU 模拟，速度会慢数倍"
}

if ($doBackend -and -not $NoBuild) {
    if (-not (Test-Path (Join-Path $SqlQueryRoot 'Dockerfile.backend'))) {
        Err "找不到 $SqlQueryRoot\Dockerfile.backend"
        Err "请用 -SqlQueryRoot 指向 sqlQuery 仓库根目录，或设置 `$env:SQLQUERY_ROOT"
        throw "sqlQuery 根目录无效"
    }
}

# tar.exe（Win10+ 自带 bsdtar）
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw "找不到 tar 命令（Windows 10+ 自带 C:\Windows\System32\tar.exe），请确认系统环境"
}
OK "预检通过（本机 Docker 架构：$serverArch）"

# ============================================================
# 准备暂存目录
# ============================================================
Step "准备暂存目录 $StagingDir ..."
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
$ImagesDir   = Join-Path $StagingDir 'images'
$ComposeDir  = Join-Path $StagingDir 'compose'
$SrcDir      = Join-Path $StagingDir 'sqlquery-src'
New-Item -ItemType Directory -Force -Path $ImagesDir, $ComposeDir | Out-Null
OK "暂存目录已就绪"

# ============================================================
# 构建镜像（-NoBuild 时跳过，仅校验）
# ============================================================
function Assert-ImageArch($Image) {
    $imgArch = (docker image inspect --format '{{.Architecture}}' $Image 2>$null)
    if (-not $imgArch) { throw "本地不存在镜像 $Image（先去掉 -NoBuild 构建一次）" }
    $imgArchNorm = if ($archMap.ContainsKey("$imgArch")) { $archMap["$imgArch"] } else { "$imgArch" }
    if ($imgArchNorm -ne $Arch) {
        throw "镜像 $Image 架构为 $imgArchNorm，与目标 $Arch 不匹配（去掉 -NoBuild 重新构建，或修正 -Arch）"
    }
}

function Build-Image($Name, $Dockerfile, $Tag, $Context, $BuildArgs) {
    Step "构建 $Name（$Platform）..."
    $argv = @('build', '--platform', $Platform, '-f', $Dockerfile, '-t', $Tag)
    if ($BuildArgs) {
        foreach ($k in $BuildArgs.Keys) { $argv += @('--build-arg', "$k=$($BuildArgs[$k])") }
    }
    $argv += $Context
    & docker @argv
    if ($LASTEXITCODE -ne 0) { throw "$Name 构建失败" }
    OK "$Name 构建完成"
}

if ($NoBuild) {
    Step "跳过构建，校验本地镜像架构 ..."
    if ($doFrontend) { Assert-ImageArch $FrontendImage; OK "$FrontendImage 架构匹配" }
    if ($doNginx)    { Assert-ImageArch $NginxImage;    OK "$NginxImage 架构匹配" }
    if ($doBackend)  { Assert-ImageArch $BackendImage;  OK "$BackendImage 架构匹配" }
} else {
    if ($doFrontend) {
        Build-Image 'frontend' (Join-Path $ScriptDir 'frontend.Dockerfile') $FrontendImage $DeerflowRoot @{
            NPM_REGISTRY         = $NpmRegistry
            COREPACK_NPM_REGISTRY = $NpmRegistry
            BETTER_AUTH_SECRET   = $BetterAuthSecret
        }
    }
    if ($doNginx) {
        Build-Image 'nginx' (Join-Path $ScriptDir 'nginx\Dockerfile') $NginxImage (Join-Path $ScriptDir 'nginx') $null
    }
    if ($doBackend) {
        Step "构建 backend（$Platform，可能 5-10 分钟）..."
        Build-Image 'backend' (Join-Path $SqlQueryRoot 'Dockerfile.backend') $BackendImage $SqlQueryRoot $null
    }
}

# ============================================================
# 导出镜像为 tar.gz（流式压缩，避免整文件读入内存）
# 文件名含架构；子串 frontend/nginx/backend 保持 deploy-offline.sh 可识别
# ============================================================
function Save-And-Gzip($Image, $OutName) {
    Step "导出 $Image -> $OutName.tar.gz ..."
    $tarPath = Join-Path $ImagesDir "$OutName.tar"
    $gzPath  = "$tarPath.gz"
    docker save $Image -o $tarPath
    if ($LASTEXITCODE -ne 0) { throw "导出失败：$Image" }
    $inStream = [System.IO.File]::OpenRead($tarPath)
    $outStream = [System.IO.File]::Create($gzPath)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionLevel]::Optimal)
        try { $inStream.CopyTo($gz) } finally { $gz.Close() }
    } finally { $inStream.Close(); $outStream.Close() }
    Remove-Item $tarPath -Force
    $sizeMB = [math]::Round((Get-Item $gzPath).Length / 1MB, 1)
    OK "$OutName.tar.gz ($sizeMB MB)"
}

if ($doFrontend) { Save-And-Gzip $FrontendImage "deerflow-frontend-$Arch" }
if ($doNginx)    { Save-And-Gzip $NginxImage    "deerflow-nginx-$Arch" }
if ($doBackend)  { Save-And-Gzip $BackendImage  "dataagent-backend-$Arch" }

# ============================================================
# 组装部署文件
# ============================================================
Step "拷贝 compose / 部署脚本 / 文档 ..."
Copy-Item -Force (Join-Path $ScriptDir 'docker-compose.offline.yml') $ComposeDir
Copy-Item -Force (Join-Path $ScriptDir 'nginx\nginx.conf') $ComposeDir
foreach ($f in @('manage.sh', 'diagnose.sh', 'deploy-offline.sh', '.env.docker.example', 'README-offline.md')) {
    $p = Join-Path $ScriptDir $f
    if (Test-Path $p) { Copy-Item -Force $p $StagingDir } else { Warn "缺 $f，包内不包含" }
}
OK "部署文件已拷贝"

# sqlquery-src（langgraph 容器挂载 backend 源码用；排除 __pycache__/.pyc）
if ($doBackend) {
    Step "拷贝 sqlquery-src（backend 源码）..."
    if (Test-Path (Join-Path $SqlQueryRoot 'backend')) {
        New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
        # robocopy 排除缓存目录；/E 含子目录 /NFL /NDL 静默
        robocopy (Join-Path $SqlQueryRoot 'backend') (Join-Path $SrcDir 'backend') /E /XD __pycache__ .pytest_cache /XF *.pyc /NFL /NDL /NJH /NJS *> $null
        if ($LASTEXITCODE -ge 8) { throw "robocopy backend 失败（exit $LASTEXITCODE）" }  # 0-7 均为成功
        foreach ($f in @('requirements.txt', 'entrypoint.sh', 'langgraph.json')) {
            $p = Join-Path $SqlQueryRoot $f
            if (Test-Path $p) { Copy-Item -Force $p $SrcDir }
        }
        OK "sqlquery-src 已拷贝"
    } else {
        Warn "未找到 $SqlQueryRoot\backend，包内不含源码（langgraph 容器需要时另行同步）"
    }
}

# ============================================================
# BUILD-INFO.txt（溯源）
# ============================================================
Step "写 BUILD-INFO.txt ..."
$comp = @(); if ($doFrontend) { $comp += 'frontend' }; if ($doBackend) { $comp += 'backend' }; if ($doNginx) { $comp += 'nginx' }
$info = @(
    "build_time   = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "host         = $env:COMPUTERNAME"
    "platform     = $Platform"
    "docker_arch  = $serverArch (emulated: $($serverArch -ne $Arch))"
    "components   = $($comp -join ',')"
    "images       ="
)
if ($doFrontend) {
    $id = (docker image inspect --format '{{.Id}} {{.Created}}' $FrontendImage)
    $info += "  $FrontendImage  $id"
}
if ($doNginx) {
    $id = (docker image inspect --format '{{.Id}} {{.Created}}' $NginxImage)
    $info += "  $NginxImage  $id"
}
if ($doBackend) {
    $id = (docker image inspect --format '{{.Id}} {{.Created}}' $BackendImage)
    $info += "  $BackendImage  $id"
}
$info | Set-Content (Join-Path $StagingDir 'BUILD-INFO.txt') -Encoding UTF8
OK "BUILD-INFO.txt 已写入"

# ============================================================
# 打成单个 tar（镜像已 gz，外层不再压二次）
# ============================================================
$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$tarName    = "deerflow-offline-bundle_${Arch}_${timestamp}.tar"
$TarPath    = Join-Path $OutDir $tarName
Step "打包最终 tar：$tarName ..."
& tar -cf $TarPath -C $OutDir $BundleName
if ($LASTEXITCODE -ne 0) { throw "tar 打包失败" }
$tarSizeMB = [math]::Round((Get-Item $TarPath).Length / 1MB, 1)
OK "$tarName ($tarSizeMB MB)"

# SHA256（scp 后校验：sha256sum <包名>）
Step "生成 SHA256 ..."
$hash = (Get-FileHash $TarPath -Algorithm SHA256).Hash.ToLower()
"$hash  $tarName" | Set-Content (Join-Path $OutDir "$tarName.sha256") -Encoding ascii
OK "SHA256 = $hash"

# ============================================================
# 汇总
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 打包完成" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "最终包     ：$TarPath"
Write-Host "大小       ：$tarSizeMB MB"
Write-Host "SHA256     ：$hash"
Write-Host "暂存目录   ：$StagingDir（不需要可手动删除）"
Write-Host ""
Write-Host "包内容："
& tar -tf $TarPath | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }
$total = (& tar -tf $TarPath | Measure-Object).Count
if ($total -gt 15) { Write-Host "  ...（共 $total 个条目）" }
Write-Host ""
Write-Host "服务器部署：" -ForegroundColor Cyan
Write-Host "  scp $TarPath root@<server>:/home/dataAgent/"
Write-Host "  ssh root@<server> 'cd /home/dataAgent && sha256sum $tarName && tar xf $tarName'"
Write-Host "  ssh root@<server> 'cd /home/dataAgent/$BundleName && ./deploy-offline.sh'"
Write-Host ""
