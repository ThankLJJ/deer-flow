#!/usr/bin/env bash
# ============================================================
# 开发机（有网）：构建所有镜像 + 导出离线包
#
# 在开发机上运行，产出 deerflow-offline-bundle/ 目录，
# 内含：
#   - images/         4 个 docker 镜像 tar
#   - sqlquery-src/   LangGraph Server 需要的 sqlQuery 源码（2MB）
#   - compose/        docker-compose.offline.yml + nginx.conf（备用）
#   - .env.docker.example  环境变量模板
#   - deploy-offline.sh    服务器一键部署脚本
#   - README-offline.md    部署文档
#
# 用法：
#   cd /Users/l/Projects/deerflow2.0-enhanced/deploy/linux
#   ./build-and-export.sh
#
# 产物：./deerflow-offline-bundle/ （可直接 scp 到离线服务器）
# ============================================================

set -euo pipefail

# ---- 路径配置（按需修改）----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEERFLOW_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SQLQUERY_ROOT="${SQLQUERY_ROOT:-/Users/l/Projects/Sdata/sqlQuery}"

BUNDLE_DIR="$SCRIPT_DIR/deerflow-offline-bundle"
IMAGES_DIR="$BUNDLE_DIR/images"
SRC_DIR="$BUNDLE_DIR/sqlquery-src"
COMPOSE_DIR="$BUNDLE_DIR/compose"

# 镜像标签
FRONTEND_IMAGE="deerflow-frontend:latest"
NGINX_IMAGE="deerflow-nginx:latest"
BACKEND_IMAGE="dataagent-backend:latest"
LANGGRAPH_IMAGE="langchain/langgraph-api:latest"

# Better Auth secret（构建时烘焙进前端镜像）
BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-$(openssl rand -hex 32)}"
# 国内 npm 源（受限网络加速）
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

echo "============================================================"
echo " DeerFlow 离线包构建（开发机：$(uname -s)/$(uname -m)）"
echo "============================================================"
echo "DEERFLOW_ROOT  = $DEERFLOW_ROOT"
echo "SQLQUERY_ROOT  = $SQLQUERY_ROOT"
echo "BUNDLE_DIR     = $BUNDLE_DIR"
echo "BETTER_AUTH    = (hidden, $(( ${#BETTER_AUTH_SECRET} )) chars)"
echo "NPM_REGISTRY   = $NPM_REGISTRY"
echo ""

# ---- 前置检查 ----
if ! docker info >/dev/null 2>&1; then
    echo "✗ Docker daemon 未运行，请先启动 Docker Desktop"
    exit 1
fi

if [ ! -d "$SQLQUERY_ROOT/backend" ]; then
    echo "✗ 找不到 sqlQuery backend：$SQLQUERY_ROOT/backend"
    echo "  请设置 SQLQUERY_ROOT 环境变量指向 sqlQuery 仓库根目录"
    exit 1
fi

if [ ! -f "$SQLQUERY_ROOT/Dockerfile.backend" ]; then
    echo "✗ 找不到 $SQLQUERY_ROOT/Dockerfile.backend"
    exit 1
fi

# 记录构建时用的 secret，写进离线包里的 .env.docker.example
echo "$BETTER_AUTH_SECRET" > "$SCRIPT_DIR/.better-auth-secret.tmp"

# ---- 准备输出目录 ----
echo "→ 清理旧产物..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$IMAGES_DIR" "$SRC_DIR" "$COMPOSE_DIR"

# ============================================================
# Step 1: 构建 frontend 镜像
# ============================================================
echo ""
echo "→ [1/5] 构建 frontend 镜像..."
docker build \
    --platform linux/amd64 \
    -f "$SCRIPT_DIR/frontend.Dockerfile" \
    -t "$FRONTEND_IMAGE" \
    --build-arg NPM_REGISTRY="$NPM_REGISTRY" \
    --build-arg BETTER_AUTH_SECRET="$BETTER_AUTH_SECRET" \
    "$DEERFLOW_ROOT"

# ============================================================
# Step 2: 构建 nginx 镜像
# ============================================================
echo ""
echo "→ [2/5] 构建 nginx 镜像..."
docker build \
    --platform linux/amd64 \
    -f "$SCRIPT_DIR/nginx/Dockerfile" \
    -t "$NGINX_IMAGE" \
    "$SCRIPT_DIR/nginx"

# ============================================================
# Step 3: 构建 sqlQuery backend 镜像
# ============================================================
echo ""
echo "→ [3/5] 构建 backend 镜像（可能 5-10 分钟）..."
docker build \
    --platform linux/amd64 \
    -f "$SQLQUERY_ROOT/Dockerfile.backend" \
    -t "$BACKEND_IMAGE" \
    "$SQLQUERY_ROOT"

# ============================================================
# Step 4: 拉取 LangGraph 镜像
# ============================================================
echo ""
echo "→ [4/5] 拉取 langgraph 镜像..."
docker pull --platform linux/amd64 "$LANGGRAPH_IMAGE"

# ============================================================
# Step 5: 导出所有镜像为 tar
# ============================================================
echo ""
echo "→ [5/5] 导出镜像为 tar..."

echo "   - $FRONTEND_IMAGE"
docker save "$FRONTEND_IMAGE" -o "$IMAGES_DIR/deerflow-frontend.tar"

echo "   - $NGINX_IMAGE"
docker save "$NGINX_IMAGE" -o "$IMAGES_DIR/deerflow-nginx.tar"

echo "   - $BACKEND_IMAGE"
docker save "$BACKEND_IMAGE" -o "$IMAGES_DIR/dataagent-backend.tar"

echo "   - $LANGGRAPH_IMAGE"
docker save "$LANGGRAPH_IMAGE" -o "$IMAGES_DIR/langgraph-api.tar"

# 压缩（镜像 tar 通常能压缩到原来的 40-60%）
echo ""
echo "→ 压缩镜像 tar（gzip）..."
for tar_file in "$IMAGES_DIR"/*.tar; do
    echo "   - $(basename "$tar_file")"
    gzip -f "$tar_file"
done

# ============================================================
# Step 6: 打包 sqlQuery 源码（LangGraph Server 挂载用）
# ============================================================
echo ""
echo "→ 打包 sqlQuery 源码（LangGraph Server 需要）..."

# 只拷 LangGraph 容器运行必需的文件，不拷 .venv/.git/workspace/data 等
mkdir -p "$SRC_DIR/backend"
cp -r "$SQLQUERY_ROOT/backend" "$SRC_DIR/backend"
[ -f "$SQLQUERY_ROOT/langgraph.json" ] && cp "$SQLQUERY_ROOT/langgraph.json" "$SRC_DIR/"
[ -f "$SQLQUERY_ROOT/requirements.txt" ] && cp "$SQLQUERY_ROOT/requirements.txt" "$SRC_DIR/"
[ -d "$SQLQUERY_ROOT/workspace" ] && cp -r "$SQLQUERY_ROOT/workspace" "$SRC_DIR/workspace"

# 清掉 __pycache__ 和 .pyc
find "$SRC_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find "$SRC_DIR" -name "*.pyc" -delete 2>/dev/null || true

# 放一份空的 .env 模板，服务器上再填实际值（langgraph.json 里写死了读 ./ .env）
cp "$SCRIPT_DIR/.env.docker.example" "$SRC_DIR/.env"

echo "   sqlquery-src 大小：$(du -sh "$SRC_DIR" | cut -f1)"

# ============================================================
# Step 7: 拷贝 compose 文件 + 部署脚本 + 文档
# ============================================================
echo ""
echo "→ 拷贝部署文件..."
cp "$SCRIPT_DIR/docker-compose.offline.yml" "$COMPOSE_DIR/"
cp "$SCRIPT_DIR/nginx/nginx.conf" "$COMPOSE_DIR/"
cp "$SCRIPT_DIR/deploy-offline.sh" "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/deploy-offline.sh"
cp "$SCRIPT_DIR/.env.docker.example" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/README-offline.md" "$BUNDLE_DIR/"

# 清理临时文件
rm -f "$SCRIPT_DIR/.better-auth-secret.tmp"

# ============================================================
# 汇总
# ============================================================
echo ""
echo "============================================================"
echo " ✅ 离线包构建完成"
echo "============================================================"
echo ""
echo "产物位置：$BUNDLE_DIR"
echo ""
echo "目录结构："
cd "$BUNDLE_DIR" && find . -maxdepth 2 -print | sort | sed 's|[^/]*/|  |g;s|  \([^ ]\)|├─ \1|'
echo ""
echo "各部分大小："
du -sh "$IMAGES_DIR" "$SRC_DIR" "$COMPOSE_DIR" 2>/dev/null
echo "总大小：$(du -sh "$BUNDLE_DIR" | cut -f1)"
echo ""
echo "→ 下一步：把整个 deerflow-offline-bundle/ 传到离线服务器"
echo "    scp -r $BUNDLE_DIR user@server:/opt/deerflow/"
echo "    ssh user@server 'cd /opt/deerflow/deerflow-offline-bundle && ./deploy-offline.sh'"
echo ""
echo "→ 或打成一个 tar 传输："
echo "    tar -czf deerflow-offline-bundle.tar.gz -C \"$SCRIPT_DIR\" deerflow-offline-bundle"
echo "    scp deerflow-offline-bundle.tar.gz user@server:/opt/deerflow/"
echo "    ssh user@server 'cd /opt/deerflow && tar -xzf deerflow-offline-bundle.tar.gz'"
echo ""
