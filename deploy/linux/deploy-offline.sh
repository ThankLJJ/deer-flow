#!/usr/bin/env bash
# ============================================================
# 离线服务器：一键加载镜像 + 启动服务
#
# 前提：已把 deerflow-offline-bundle/ 传到服务器，当前目录就是它。
#
# 用法：
#   cd /opt/deerflow/deerflow-offline-bundle
#   ./deploy-offline.sh            # 完整部署（首次）
#   ./deploy-offline.sh load       # 只加载镜像
#   ./deploy-offline.sh up         # 只启动（镜像已加载）
#   ./deploy-offline.sh down       # 停止并删除容器
#   ./deploy-offline.sh logs       # 看日志
#   ./deploy-offline.sh status     # 看状态
#   ./deploy-offline.sh restart    # 重启
# ============================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="$BUNDLE_DIR/images"
COMPOSE_FILE="$BUNDLE_DIR/compose/docker-compose.offline.yml"
ENV_FILE="$BUNDLE_DIR/.env.docker"
SRC_DIR="$BUNDLE_DIR/sqlquery-src"
WORKSPACE_DIR="$BUNDLE_DIR/data/workspace"

# ---- 颜色 ----
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}→${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# ---- compose 命令封装 ----
compose() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# ---- 前置检查 ----
preflight() {
    if ! docker info >/dev/null 2>&1; then
        err "Docker daemon 未运行"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        err "docker compose 插件未安装"
        exit 1
    fi
    if [ ! -f "$COMPOSE_FILE" ]; then
        err "找不到 compose 文件：$COMPOSE_FILE"
        exit 1
    fi
}

# ---- Step 1: 加载镜像 ----
load_images() {
    info "加载离线镜像..."
    for gz in "$IMAGES_DIR"/*.tar.gz; do
        [ -e "$gz" ] || continue
        name=$(basename "$gz")
        # 检查是否已加载
        case "$name" in
            *frontend*)  img_tag="deerflow-frontend:latest" ;;
            *nginx*)     img_tag="deerflow-nginx:latest" ;;
            *backend*)   img_tag="dataagent-backend:latest" ;;
            *langgraph*) img_tag="langchain/langgraph-api:latest" ;;
            *)           img_tag="" ;;
        esac
        if [ -n "$img_tag" ] && docker image inspect "$img_tag" >/dev/null 2>&1; then
            echo "  ✓ $img_tag 已存在，跳过"
            continue
        fi
        echo "  · 加载 $name ..."
        gunzip -c "$gz" | docker load
    done
    echo ""
    info "已加载镜像："
    docker images | grep -E 'deerflow|dataagent|langgraph' || true
}

# ---- Step 2: 准备配置 ----
prepare_config() {
    info "准备配置..."

    # .env.docker 不存在则从模板创建
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$BUNDLE_DIR/.env.docker.example" ]; then
            cp "$BUNDLE_DIR/.env.docker.example" "$ENV_FILE"
            warn "已从模板创建 $ENV_FILE，请编辑后重新运行"
            warn "必改项：SYS_DATABASE_PASSWORD / OPENAI_API_KEY / AES_KEY / AES_IV"
            warn "编辑命令：vim $ENV_FILE"
            echo ""
            echo "    vim $ENV_FILE"
            echo ""
            exit 0
        else
            err "找不到 .env.docker.example"
            exit 1
        fi
    fi

    # 确保 sqlquery-src/.env 存在（LangGraph 容器要读）
    if [ ! -f "$SRC_DIR/.env" ]; then
        if [ -f "$BUNDLE_DIR/.env.docker.example" ]; then
            cp "$BUNDLE_DIR/.env.docker.example" "$SRC_DIR/.env"
            warn "已为 LangGraph 创建 $SRC_DIR/.env，请填入实际值"
            warn "编辑命令：vim $SRC_DIR/.env"
            exit 0
        fi
    fi

    # 确保 workspace 目录存在
    mkdir -p "$WORKSPACE_DIR"

    # 设置 .env.docker 里的路径（离线包是自包含的，路径都相对 bundle）
    # 如果用户没显式设，就用默认值
    grep -q '^SQLQUERY_PATH=' "$ENV_FILE" 2>/dev/null || \
        echo "SQLQUERY_PATH=$SRC_DIR" >> "$ENV_FILE"
    grep -q '^WORKSPACE_DIR=' "$ENV_FILE" 2>/dev/null || \
        echo "WORKSPACE_DIR=$WORKSPACE_DIR" >> "$ENV_FILE"

    info "配置检查："
    echo "  compose : $COMPOSE_FILE"
    echo "  env     : $ENV_FILE"
    echo "  src     : $SRC_DIR"
    echo "  workspace: $WORKSPACE_DIR"
}

# ---- Step 3: 启动 ----
start() {
    info "启动 4 个容器..."
    compose up -d
    sleep 3
    status
}

# ---- Step 4: 状态 ----
status() {
    echo ""
    info "容器状态："
    compose ps
    echo ""
    info "验证命令："
    echo "  curl http://localhost/healthz"
    echo "  curl http://localhost/api/health"
    echo "  curl http://localhost/api/models"
}

# ---- 日志 ----
show_logs() {
    compose logs -f --tail=50
}

# ---- 停止 ----
down() {
    info "停止并删除容器..."
    compose down
}

# ---- 重启 ----
restart() {
    info "重启..."
    compose restart
    sleep 2
    status
}

# ============================================================
# 主流程
# ============================================================
preflight

case "${1:-deploy}" in
    load)
        load_images
        ;;
    config)
        prepare_config
        ;;
    up|start)
        prepare_config
        start
        ;;
    down|stop)
        down
        ;;
    restart)
        restart
        ;;
    logs)
        show_logs
        ;;
    status|ps)
        status
        ;;
    deploy|"")
        # 完整首次部署
        load_images
        echo ""
        prepare_config
        echo ""
        start
        echo ""
        info "✅ 部署完成。访问 http://<服务器IP>:$(grep -E '^EXPOSE_PORT=' "$ENV_FILE" | cut -d= -f2 || echo 80)/"
        ;;
    *)
        echo "用法: $0 {deploy|load|config|up|down|restart|logs|status}"
        echo ""
        echo "  deploy  (默认) 完整部署：加载镜像 + 配置 + 启动"
        echo "  load    只加载镜像"
        echo "  config  只准备配置（首次会生成 .env.docker 模板）"
        echo "  up      启动服务（镜像已加载）"
        echo "  down    停止并删除容器"
        echo "  restart 重启容器"
        echo "  logs    跟随日志"
        echo "  status  查看状态"
        exit 1
        ;;
esac
