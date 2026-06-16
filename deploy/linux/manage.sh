#!/usr/bin/env bash
# ============================================================
# DataAgent 一键部署管理脚本
#
# 用法：
#   sh manage.sh deploy    # 首次部署（加载镜像 + 配置 + 启动）
#   sh manage.sh up        # 启动服务（镜像已加载）
#   sh manage.sh down      # 停止所有服务
#   sh manage.sh restart   # 重启所有服务
#   sh manage.sh status    # 查看服务状态
#   sh manage.sh logs      # 查看日志（跟随）
#   sh manage.sh update    # 更新后端代码（docker cp + commit + 重启）
#   sh manage.sh update-frontend  # 更新前端镜像（load tar.gz + 重启）
#
# 前提：当前目录是 deerflow-offline-bundle/
# 镜像：3 个（frontend + nginx + backend，不含 langgraph）
# ============================================================
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="$BUNDLE_DIR/images"
COMPOSE_DIR="$BUNDLE_DIR/compose"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.offline.yml"
ENV_FILE="$BUNDLE_DIR/.env.docker"
SRC_DIR="$BUNDLE_DIR/sqlquery-src"

# ---- 颜色 ----
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}→${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# ---- compose 封装 ----
compose() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# ---- 前置检查 ----
preflight() {
    if ! docker info >/dev/null 2>&1; then
        err "Docker daemon 未运行"; exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        err "docker compose 插件未安装"; exit 1
    fi
    if [ ! -f "$COMPOSE_FILE" ]; then
        err "找不到 compose 文件：$COMPOSE_FILE"; exit 1
    fi
}

# ---- 检查/创建 .env.docker ----
ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$BUNDLE_DIR/.env.docker.example" ]; then
            cp "$BUNDLE_DIR/.env.docker.example" "$ENV_FILE"
            warn "已创建 $ENV_FILE，请编辑后重新运行"
            warn "必改项：SYS_DATABASE_PASSWORD / OPENAI_API_KEY / AES_KEY / AES_IV"
            warn "编辑命令：vim $ENV_FILE"
            exit 0
        else
            err "找不到 .env.docker.example"; exit 1
        fi
    fi

    # 确保 sqlquery-src/.env 存在（LangGraph 兼容层读取）
    if [ ! -f "$SRC_DIR/.env" ]; then
        cp "$BUNDLE_DIR/.env.docker.example" "$SRC_DIR/.env"
        warn "已创建 $SRC_DIR/.env，请填入实际值"
    fi

    # 确保路径配置
    grep -q '^SQLQUERY_PATH=' "$ENV_FILE" 2>/dev/null || \
        echo "SQLQUERY_PATH=$SRC_DIR" >> "$ENV_FILE"
    grep -q '^WORKSPACE_DIR=' "$ENV_FILE" 2>/dev/null || \
        echo "WORKSPACE_DIR=$BUNDLE_DIR/data/workspace" >> "$ENV_FILE"

    mkdir -p "$BUNDLE_DIR/data/workspace"
}

# ---- 加载镜像 ----
load_images() {
    info "加载离线镜像..."
    for gz in "$IMAGES_DIR"/*.tar.gz; do
        [ -e "$gz" ] || continue
        name=$(basename "$gz")
        case "$name" in
            *frontend*)  img_tag="deerflow-frontend:latest" ;;
            *nginx*)     img_tag="deerflow-nginx:latest" ;;
            *backend*)   img_tag="dataagent-backend:latest" ;;
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
    docker images | grep -E 'deerflow|dataagent' || true
}

# ============================================================
# 命令实现
# ============================================================

cmd_deploy() {
    preflight
    load_images
    echo ""
    ensure_env
    echo ""
    info "启动服务..."
    compose up -d
    sleep 5
    cmd_status
    echo ""
    info "部署完成。访问 http://<服务器IP>:$(grep -E '^EXPOSE_PORT=' "$ENV_FILE" | cut -d= -f2 || echo 80)/"
}

cmd_up() {
    preflight
    ensure_env
    info "启动服务..."
    compose up -d
    sleep 3
    cmd_status
}

cmd_down() {
    preflight
    info "停止所有服务..."
    compose down
}

cmd_restart() {
    preflight
    info "重启所有服务..."
    compose restart
    sleep 3
    cmd_status
}

cmd_status() {
    echo ""
    info "容器状态："
    compose ps
    echo ""
    # 端口
    local port
    port=$(grep -E '^EXPOSE_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo 80)
    info "对外端口: $port"
    info "访问地址: http://<服务器IP>:$port/"
}

cmd_logs() {
    preflight
    compose logs -f --tail=50
}

cmd_update() {
    # 更新后端代码（docker cp + commit + 重启）
    preflight
    info "更新后端代码（从 sqlquery-src 同步到容器）..."

    if [ ! -d "$SRC_DIR/backend" ]; then
        err "找不到源码目录：$SRC_DIR/backend"; exit 1
    fi

    # 用临时容器同步整个 backend 目录
    local img=$(grep -E '^SQLQUERY_BACKEND_IMAGE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "dataagent-backend:latest")
    docker create --name temp-update "$img" >/dev/null 2>&1 || true
    docker cp "$SRC_DIR/backend/." temp-update:/app/backend/
    docker commit temp-update "$img"
    docker rm temp-update >/dev/null 2>&1

    info "后端镜像已更新，重启 backend..."
    compose up -d --force-recreate backend
    sleep 5
    cmd_status
    echo ""
    info "更新完成。"
}

cmd_update_frontend() {
    # 更新前端镜像（从 tar.gz 加载）
    preflight
    local gz="$IMAGES_DIR/deerflow-frontend.tar.gz"
    if [ ! -f "$gz" ]; then
        err "找不到前端镜像：$gz"; exit 1
    fi
    info "加载前端镜像..."
    gunzip -c "$gz" | docker load
    info "重启 frontend + nginx..."
    compose up -d --force-recreate frontend nginx
    sleep 3
    cmd_status
    echo ""
    info "前端更新完成。浏览器请 Ctrl+Shift+R 强制刷新。"
}

# ============================================================
# 主流程
# ============================================================
preflight

case "${1:-status}" in
    deploy)
        cmd_deploy
        ;;
    up|start)
        cmd_up
        ;;
    down|stop)
        cmd_down
        ;;
    restart)
        cmd_restart
        ;;
    status|ps)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    update)
        cmd_update
        ;;
    update-frontend)
        cmd_update_frontend
        ;;
    *)
        echo "用法: $0 {deploy|up|down|restart|status|logs|update|update-frontend}"
        echo ""
        echo "  deploy           首次部署：加载镜像 + 配置 + 启动"
        echo "  up               启动服务（镜像已加载）"
        echo "  down             停止并删除容器"
        echo "  restart          重启所有容器"
        echo "  status           查看状态"
        echo "  logs             跟随日志"
        echo "  update           更新后端代码（从 sqlquery-src 同步）"
        echo "  update-frontend  更新前端镜像（从 tar.gz 加载）"
        exit 1
        ;;
esac
