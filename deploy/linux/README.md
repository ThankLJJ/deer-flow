# Linux Docker 部署：DeerFlow 前端 + sqlQuery backend

把 DeerFlow 前端 + sqlQuery 后端（FastAPI + LangGraph Server）打包成 4 个容器一键部署到 Linux。

## 目录结构

```
deploy/linux/
├── README.md                 ← 本文档
├── docker-compose.yml        ← 4 服务编排
├── .env.docker.example       ← 环境变量模板
├── frontend.Dockerfile       ← 前端多阶段构建
└── nginx/
    ├── Dockerfile            ← nginx 镜像
    └── nginx.conf            ← 反代配置
```

## 服务拓扑

```
                ┌──────────────────┐
                │   Host :80       │
                │   (或 :8000)     │
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │  nginx 容器       │
                │  (反代 + SSE)     │
                └─┬──────┬──────┬──┘
                  │      │      │
        ┌─────────▼┐  ┌──▼───┐ ┌▼─────────┐
        │ frontend │  │ api  │ │ langgraph│
        │ Next.js  │  │ Fast │ │ Server   │
        │ :3000    │  │ :8001│ │ :2024    │
        └──────────┘  └──────┘ └──────────┘
                            │         │
                            └────┬────┘
                                 │
                    ┌────────────▼────────────┐
                    │  外部依赖（不在本 compose）│
                    │  • MySQL (SYS_DATABASE_*)│
                    │  • Milvus                │
                    │  • Embedding 服务        │
                    │  • DeepSeek API          │
                    └─────────────────────────┘
```

| 容器 | 端口（内部） | 镜像 | 用途 |
|---|---|---|---|
| `nginx` | 80 → 对外 | `deerflow-nginx:latest` | 统一入口，反代 + SSE |
| `frontend` | 3000 | `deerflow-frontend:latest` | Next.js standalone SSR |
| `backend` | 8001 | `dataagent-backend:latest` | FastAPI + `deerflow_compat.py` |
| `langgraph` | 2024 | `langchain/langgraph-api:latest` | LangGraph Server（lead_agent） |

外部只暴露 `nginx` 的 80 端口（可用 `EXPOSE_PORT` 改），其余三个容器只在内部网络通信。

---

## 前置条件

### 1. Linux 服务器

- **OS**：CentOS 7+ / Ubuntu 20.04+ / Debian 11+ / Rocky Linux 等主流发行版
- **CPU**：x86_64 或 ARM64（镜像都支持）
- **内存**：≥ 4GB（推荐 8GB，LangGraph Server + 三个 Python 进程）
- **磁盘**：≥ 20GB（镜像 + workspace 上传文件）

### 2. 已安装软件

```bash
# Docker Engine ≥ 20.10
docker --version

# Docker Compose v2（plugin 形式）
docker compose version
```

如未安装：

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER  # 重新登录生效

# CentOS/RHEL
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

### 3. 外部依赖就绪

- **MySQL**（5.7+ 或 8.0）：用于 sqlQuery 数据源元信息、对话持久化、LangGraph checkpointer
- **Milvus**（可选）：知识库向量检索，不用知识库可跳过
- **Embedding 服务**（可选）：同上
- **DeepSeek / OpenAI API Key**

---

## 部署步骤

### Step 1 — 上传代码

把整个 `deerflow2.0-enhanced/` 仓库和 `Sdata/sqlQuery/` 仓库都上传到服务器（`docker-compose.yml` 通过相对路径引用 sqlQuery 源码给 LangGraph Server 容器挂载）：

```bash
# 假设服务器目录布局：
/opt/deerflow/
├── deerflow2.0-enhanced/    # ← 本仓库
└── Sdata/sqlQuery/          # ← sqlQuery 后端
```

如果 sqlQuery 在其他位置，编辑 `.env.docker` 中的 `SQLQUERY_PATH` 改为绝对路径。

### Step 2 — 配置环境变量

```bash
cd /opt/deerflow/deerflow2.0-enhanced/deploy/linux

cp .env.docker.example .env.docker
vim .env.docker
```

**必改项**：
- `SYS_DATABASE_PASSWORD` / `YW_DATABASE_PASSWORD` — 数据库密码
- `AES_KEY` / `AES_IV` — 数据源解密密钥
- `OPENAI_API_KEY` — DeepSeek API key
- `BETTER_AUTH_SECRET` — 改为随机字符串：`openssl rand -hex 32`

**可选项**：
- `EXPOSE_PORT` — 改 80 → 8000 避开宿主机 nginx 占用
- `NPM_REGISTRY=https://registry.npmmirror.com` — 国内构建加速

### Step 3 — 预先构建 sqlQuery backend 镜像（如未构建）

```bash
cd /opt/deerflow/Sdata/sqlQuery
docker build -f Dockerfile.backend -t dataagent-backend:latest .
```

如果 sqlQuery 项目还没有 `Dockerfile.backend` 或想跳过此步，可临时用源码挂载方式跑（性能差，仅测试用）—— 在 `docker-compose.yml` 里把 `backend` 服务的 `image` 注释、`build` 段取消注释。

### Step 4 — 启动

```bash
cd /opt/deerflow/deerflow2.0-enhanced/deploy/linux
docker compose --env-file .env.docker up -d --build
```

首次启动会：
1. 构建 `frontend` 镜像（~3 分钟，主要时间在 `pnpm install` + `pnpm build`）
2. 构建 `nginx` 镜像（~10 秒）
3. 拉取 `langchain/langgraph-api:latest`（~1 分钟）
4. 启动 4 个容器

查看启动状态：

```bash
docker compose ps
docker compose logs -f --tail=50
```

### Step 5 — 验证

```bash
# 健康检查
curl http://localhost/healthz
# → {"status":"ok"}

# FastAPI 健康
curl http://localhost/api/health
# → {"status":"ok","mode":"dataagent"}

# 模型列表（前端设置面板用）
curl http://localhost/api/models
# → {"models":[{"name":"...","display_name":"...","provider":"openai"}]}

# LangGraph info
curl http://localhost/threads 2>/dev/null || true
#（空 thread 列表或 422，根据版本不同）
```

打开浏览器访问 `http://<server-ip>/`，应直接进入 `/workspace`，不跳 `/login`。

---

## 日常运维

### 查看日志

```bash
# 所有服务
docker compose logs -f

# 单个服务
docker compose logs -f frontend
docker compose logs -f backend
docker compose logs -f langgraph
docker compose logs -f nginx
```

### 重启服务

```bash
# 重启单个
docker compose restart frontend

# 重启全部
docker compose restart
```

### 更新代码后重新部署

```bash
cd /opt/deerflow/deerflow2.0-enhanced/deploy/linux

# 拉新代码（在仓库根）
# cd ../.. && git pull

# 重新构建 + 重启
docker compose --env-file .env.docker up -d --build
```

仅前端代码变更时，可只构建 frontend：

```bash
docker compose --env-file .env.docker up -d --build frontend
```

### 停止 / 清理

```bash
# 停止保留容器
docker compose stop

# 停止并删除容器（保留镜像和数据）
docker compose down

# 完全清理（含镜像）
docker compose down --rmi local
```

### 数据备份

workspace 目录持久化在 `./data/workspace/`（或 `.env.docker` 中 `WORKSPACE_DIR`），定期备份：

```bash
tar -czf workspace-$(date +%Y%m%d).tar.gz data/workspace/
```

数据库备份按 MySQL 标准流程（`mysqldump`）。

---

## 常见问题

### 1. 启动后访问 / 跳转 /login

镜像构建时 `DEER_FLOW_AUTH_DISABLED=1` 没烘焙进 standalone 产物。检查 `frontend.Dockerfile` 第 50 行附近的 `ENV DEER_FLOW_AUTH_DISABLED=1` 是否存在，重新 `--build`。

### 2. backend 容器报 MySQL 连接失败

```bash
docker compose exec backend python -c "import pymysql; pymysql.connect(host='${SYS_DATABASE_HOST}', port=${SYS_DATABASE_PORT}, user='${SYS_DATABASE_USER}', password='${SYS_DATABASE_PASSWORD}')"
```

容器内能否访问 MySQL？若 MySQL 在宿主机，确保：
- MySQL 监听 `0.0.0.0` 而非 `127.0.0.1`
- 或在 `docker-compose.yml` 的 backend 服务加 `extra_hosts: ["host.docker.internal:host-gateway"]`，然后 `SYS_DATABASE_HOST=host.docker.internal`

### 3. langgraph 容器启动后立即退出

```bash
docker compose logs langgraph
```

常见原因：
- `langgraph.json` 找不到（`SQLQUERY_PATH` 不对）
- `graph.py` 编译错误（Python 依赖缺失）
- MySQL checkpointer 初始化失败（看 `SYS_DATABASE_*` 是否对，schema 是否有写权限）

### 4. 前端构建失败：pnpm install 超时

设 `NPM_REGISTRY=https://registry.npmmirror.com`：

```bash
NPM_REGISTRY=https://registry.npmmirror.com docker compose --env-file .env.docker build frontend
```

### 5. 上传大文件失败（413）

`nginx.conf` 默认 `client_max_body_size 100m`，如需更大请改 `deploy/linux/nginx/nginx.conf` 后重建 nginx 镜像：

```bash
docker compose build nginx && docker compose up -d nginx
```

### 6. 流式回复断断续续或断开

`nginx.conf` 已关闭 `proxy_buffering` 并设 `proxy_read_timeout 86400s`。如果还有问题，检查宿主机是否有其他 LB（如云厂商 SLB）默认 60s 超时，需在其上配置长连接。

### 7. 时区问题

容器默认 UTC。如需北京时间，每个服务加：

```yaml
environment:
  TZ: Asia/Shanghai
volumes:
  - /etc/localtime:/etc/localtime:ro
```

---

## 性能与安全建议

### 性能

- **frontend 容器**：1GB 内存够用。Next.js standalone 启动约 200MB。
- **backend 容器**：建议 ≥ 2GB（pandas/lightgbm/prophet 都吃内存）。
- **langgraph 容器**：≥ 1GB。
- **nginx**：< 100MB。
- 如果服务器资源紧张，可在 `docker-compose.yml` 加 `deploy.resources.limits`。

### 安全

1. **`BETTER_AUTH_SECRET`** 必须改为随机字符串，否则会被 Better Auth 拒绝启动。
2. **不要在生产用 `DEER_FLOW_AUTH_DISABLED=1`** 当数据库里有敏感数据时 —— 当前任何人访问 URL 都能用，等价于 anonymous 模式。生产请实现 `/api/v1/auth/*` 端点（见 `DEPLOYMENT.md` 第 6 节）。
3. **`AES_KEY`/`AES_IV`** 与 sqlQuery 数据源密码加密绑定，泄露后数据源密码可被解密。
4. **MySQL 密码** 用强密码，并限制 IP 访问。
5. nginx 当前监听 80，建议前置 Cloudflare 或加 Let's Encrypt 证书（在 `nginx.conf` 加 443 server 块 + certbot 续期）。

---

## 文件清单（部署时需要传到服务器）

| 路径 | 必需 | 说明 |
|---|---|---|
| `deploy/linux/` 整个目录 | ✓ | Docker 编排 |
| `frontend/` 整个目录 | ✓ | 前端源码（构建用） |
| `frontend/.dockerignore` | ✓ | 减小构建上下文 |
| `/opt/deerflow/Sdata/sqlQuery/` | ✓ | 后端源码（LangGraph Server 挂载用） |
| `Sdata/sqlQuery/Dockerfile.backend` | ✓ | backend 镜像构建（如未预构建） |
| `Sdata/sqlQuery/langgraph.json` | ✓ | LangGraph 配置 |
| `Sdata/sqlQuery/backend/` 整个目录 | ✓ | Python 源码 |
| `Sdata/sqlQuery/requirements.txt` | ✓ | Python 依赖 |

最小化传输可用 `tar`：

```bash
# 在开发机
tar -czf deploy.tar.gz \
  deerflow2.0-enhanced/frontend \
  deerflow2.0-enhanced/deploy/linux \
  Sdata/sqlQuery/langgraph.json \
  Sdata/sqlQuery/Dockerfile.backend \
  Sdata/sqlQuery/requirements.txt \
  Sdata/sqlQuery/backend

scp deploy.tar.gz user@server:/opt/deerflow/
ssh user@server 'cd /opt/deerflow && tar -xzf deploy.tar.gz'
```

---

## 与 deerflow 原生 Docker 的区别

deerflow 仓库根的 `Makefile` 和 `docker/docker-compose-dev.yaml` 是给 deerflow **自己的 backend + frontend + nginx** 用的，监听 `:2026`。

本目录的 `docker-compose.yml` 是**对接 sqlQuery backend** 的独立部署，**不依赖** deerflow 的 backend、不读 deerflow 的 `config.yaml`，所有 sqlQuery 后端配置走 `.env.docker`（即 sqlQuery 项目自己的环境变量格式）。

两者互不冲突，可分别使用。
