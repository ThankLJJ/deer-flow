# ============================================================
# 开发机（Windows / PowerShell）：构建所有镜像 + 导出离线包
#
# 产出 deerflow-offline-bundle\ 目录，内含：
#   - images\              3 个 docker 镜像 tar（gzip 压缩）
#                           · deerflow-frontend  (Next.js 前端)
#                           · deerflow-nginx     (nginx 反代)
#                           · dataagent-backend  (FastAPI + LangGraph 兼容层)
#   - sqlquery-src\        backend 源码（docker cp 更新用）
#   - compose\             docker-compose.offline.yml + nginx.conf
#   - .env.docker.example  环境变量模板
#   - manage.sh            部署管理脚本
#   - diagnose.sh          诊断脚本
#   - README-offline.md    部署文档
#
# 注意：不再构建 langgraph-api 镜像（已废弃，改用 backend 内嵌兼容层）
#
# 用法（在本目录下用 PowerShell 运行）：
#   cd C:\Users\L\Documents\deer-flows\deploy\linux
#   .\build-and-export.ps1
#
# 可用环境变量覆盖默认值：
#   $env:SQLQUERY_ROOT   = "C:\...\smartquerydata"
#   $env:NPM_REGISTRY    = "https://registry.npmmirror.com"
#   $env:BETTER_AUTH_SECRET = "..."
# ============================================================

# ---- 失败即停 ----
$ErrorActionPreference = 'Stop'

# ============================================================
# 路径配置（按需修改）
# ============================================================
$ScriptDir    = $PSScriptRoot
$DeerflowRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$SqlQueryRoot = if ($env:SQLQUERY_ROOT) { $env:SQLQUERY_ROOT } else { 'C:\Users\L\Documents\smartquerydata' }

$BundleDir  = Join-Path $ScriptDir   'deerflow-offline-bundle'
$ImagesDir  = Join-Path $BundleDir   'images'
$ComposeDir = Join-Path $BundleDir   'compose'

# 镜像标签（langgraph-api 镜像已废弃，改用 backend 内嵌兼容层）
$FrontendImage = 'deerflow-frontend:latest'
$NginxImage    = 'deerflow-nginx:latest'
$BackendImage  = 'dataagent-backend:latest'

# Better Auth secret（构建时烘焙进前端镜像）
$BetterAuthSecret = if ($env:BETTER_AUTH_SECRET) {
    $env:BETTER_AUTH_SECRET
} else {
    # 生成 64 位十六进制随机串
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

# 国内 npm 源（受限网络加速）
$NpmRegistry = if ($env:NPM_REGISTRY) { $env:NPM_REGISTRY } else { 'https://registry.npmmirror.com' }

function Write-Step($msg) { Write-Host "`n→ $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  ✔ $msg" -ForegroundColor Green }

Write-Host "============================================================" -ForegroundColor White
Write-Host " DeerFlow 离线包构建（开发机：$([System.Environment]::OSVersion.VersionString)）" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor White
Write-Host "DEERFLOW_ROOT  = $DeerflowRoot"
Write-Host "SQLQUERY_ROOT  = $SqlQueryRoot"
Write-Host "BUNDLE_DIR     = $BundleDir"
Write-Host "BETTER_AUTH    = (hidden, $($BetterAuthSecret.Length) chars)"
Write-Host "NPM_REGISTRY   = $NpmRegistry"
Write-Host ""

# ============================================================
# 前置检查
# ============================================================
try {
    docker info *> $null
} catch {
    Write-Host "✗ Docker daemon 未运行，请先启动 Docker Desktop" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path (Join-Path $SqlQueryRoot 'backend'))) {
    Write-Host "✗ 找不到 sqlQuery backend：$(Join-Path $SqlQueryRoot 'backend')" -ForegroundColor Red
    Write-Host "  请设置 `$env:SQLQUERY_ROOT 环境变量指向 sqlQuery 仓库根目录"
    exit 1
}
if (-not (Test-Path (Join-Path $SqlQueryRoot 'Dockerfile.backend'))) {
    Write-Host "✗ 找不到 $(Join-Path $SqlQueryRoot 'Dockerfile.backend')" -ForegroundColor Red
    exit 1
}

# ============================================================
# 准备输出目录
# ============================================================
Write-Step "清理旧产物..."
if (Test-Path $BundleDir) { Remove-Item -Recurse -Force $BundleDir }
New-Item -ItemType Directory -Force -Path $ImagesDir, $ComposeDir | Out-Null

# ============================================================
# Step 1: 构建 frontend 镜像
# ============================================================
Write-Step "[1/4] 构建 frontend 镜像..."
docker build `
    --platform linux/amd64 `
    -f (Join-Path $ScriptDir 'frontend.Dockerfile') `
    -t $FrontendImage `
    --build-arg "NPM_REGISTRY=$NpmRegistry" `
    --build-arg "COREPACK_NPM_REGISTRY=$NpmRegistry" `
    --build-arg "BETTER_AUTH_SECRET=$BetterAuthSecret" `
    $DeerflowRoot
if ($LASTEXITCODE -ne 0) { throw "frontend 镜像构建失败" }
Write-OK "frontend 镜像构建完成"

# ============================================================
# Step 2: 构建 nginx 镜像
# ============================================================
Write-Step "[2/4] 构建 nginx 镜像..."
docker build `
    --platform linux/amd64 `
    -f (Join-Path $ScriptDir 'nginx\Dockerfile') `
    -t $NginxImage `
    (Join-Path $ScriptDir 'nginx')
if ($LASTEXITCODE -ne 0) { throw "nginx 镜像构建失败" }
Write-OK "nginx 镜像构建完成"

# ============================================================
# Step 3: 构建 sqlQuery backend 镜像（含 LangGraph 兼容层）
# ============================================================
Write-Step "[3/4] 构建 backend 镜像（可能 5-10 分钟）..."
docker build `
    --platform linux/amd64 `
    -f (Join-Path $SqlQueryRoot 'Dockerfile.backend') `
    -t $BackendImage `
    $SqlQueryRoot
if ($LASTEXITCODE -ne 0) { throw "backend 镜像构建失败" }
Write-OK "backend 镜像构建完成"

# ============================================================
# Step 4: 导出所有镜像为 tar 并 gzip 压缩
# ============================================================
Write-Step "[4/4] 导出镜像为 tar（gzip 压缩）..."

function Save-And-Gzip {
    param([string]$Image, [string]$OutName)
    $tarPath = Join-Path $ImagesDir "$OutName.tar"
    $gzPath  = "$tarPath.gz"
    Write-Host "   - $Image"
    docker save $Image -o $tarPath
    if ($LASTEXITCODE -ne 0) { throw "导出失败：$Image" }
    # .NET GZipStream 压缩（等价 gzip -f）
    $srcBytes = [System.IO.File]::ReadAllBytes($tarPath)
    $outStream = [System.IO.File]::Create($gzPath)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
        try { $gz.Write($srcBytes, 0, $srcBytes.Length) } finally { $gz.Close() }
    } finally { $outStream.Close() }
    Remove-Item $tarPath -Force
}

Save-And-Gzip -Image $FrontendImage  -OutName 'deerflow-frontend'
Save-And-Gzip -Image $NginxImage     -OutName 'deerflow-nginx'
Save-And-Gzip -Image $BackendImage   -OutName 'dataagent-backend'

# ============================================================
# Step 5: 拷贝 compose 文件 + 部署脚本 + 文档
# ============================================================
Write-Step "拷贝部署文件..."
Copy-Item -Force (Join-Path $ScriptDir 'docker-compose.offline.yml') $ComposeDir
Copy-Item -Force (Join-Path $ScriptDir 'nginx\nginx.conf') $ComposeDir
Copy-Item -Force (Join-Path $ScriptDir 'manage.sh') $BundleDir
Copy-Item -Force (Join-Path $ScriptDir 'diagnose.sh') $BundleDir
Copy-Item -Force (Join-Path $ScriptDir '.env.docker.example') $BundleDir
Copy-Item -Force (Join-Path $ScriptDir 'README-offline.md') $BundleDir
Copy-Item -Force (Join-Path $ScriptDir 'DEV-NOTES.md') $BundleDir

# ============================================================
# 汇总
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " ✅ 离线包构建完成" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "产物位置：$BundleDir"
Write-Host ""
Write-Host "目录结构："
Get-ChildItem -Path $BundleDir -Recurse -Depth 1 | ForEach-Object {
    $rel = $_.FullName.Substring($BundleDir.Length).TrimStart('\')
    Write-Host "  $rel"
}
Write-Host ""
Write-Host "各部分大小："
foreach ($d in @($ImagesDir, $ComposeDir)) {
    $size = (Get-ChildItem -Recurse $d -File | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host ("  {0,-20} {1,8:N2} MB" -f (Split-Path $d -Leaf), $size)
}
$total = (Get-ChildItem -Recurse $BundleDir -File | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ("  总大小              {0,8:N2} MB" -f $total)
Write-Host ""
Write-Host "→ 下一步：把整个 deerflow-offline-bundle\ 传到离线服务器"
Write-Host "    scp -r $BundleDir user@server:/opt/deerflow/"
Write-Host "    ssh user@server 'cd /opt/deerflow/deerflow-offline-bundle && ./deploy-offline.sh'"
Write-Host ""
