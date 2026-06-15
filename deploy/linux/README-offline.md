# 离线部署指南：DeerFlow 前端 + sqlQuery 后端

适用场景：**目标服务器无外网**，需要在有网的开发机上构建好一切，打包传过去直接运行。

服务器环境：CentOS/RHEL x86_64，已安装 Docker + Compose。

---

## 方案总览

```
开发机（有网 x86_64）                    离线服务器（CentOS x86_64）
────────────────────                    ────────────────────────
build-and-export.sh                      deploy-offline.sh
  ↓ 构建 4 个镜像                          ↓ docker load 4 个 tar
  ↓ docker save → tar.gz                   ↓ docker compose up -d
  ↓ 打包 sqlQuery 源码（2MB）
  ↓ 打包 compose + 配置
  ↓
deerflow-offline-bundle/  ──── scp ────→  /opt/deerflow/
                                            └─ 一键 up
```

**核心改造**：离线版 `docker-compose.offline.yml` 全部用 `image:`（不是 `build:`），服务器上**不需要源码、node、pnpm**，镜像从 tar 加载即可。

**唯一需要挂载的源码**是 `sqlquery-src/`（2MB 纯 Python），因为 LangGraph Server 启动时要读 `langgraph.json` + `backend/agent/graph.py:graph`。

---

## 4 个镜像清单

| 镜像 | 大小（估计） | 用途 |
|---|---|---|
| `deerflow-frontend:latest` | ~300MB | Next.js standalone（已烘焙配置） |
| `deerflow-nginx:latest` | ~50MB | nginx:1.27-alpine + 反代配置 |
| `dataagent-backend:latest` | ~1.5GB | FastAPI + pandas/lightgbm/prophet |
| `langchain/langgraph-api:latest` | ~1GB | LangGraph Server 官方镜像 |

打包后（gzip 压缩）整体约 **1.5–2GB**。

---

## Part 1：开发机操作（有网）

### 1.1 前置检查

```bash
# 启动 Docker Desktop（macOS）
open -a Docker

# 确认 Docker 运行
docker info

# 确认架构（必须是 x86_64）
uname -m   # → x86_64
```

### 1.2（可选）预填环境变量

脚本会自动生成 `BETTER_AUTH_SECRET`（随机串），其余配置默认留占位符。
如果想直接把开发机现成的 sqlQuery 配置烘焙进离线包，提前设置：

```bash
# 可选：直接从开发机的 sqlQuery/.env 读配置
# 不设也行，服务器上再填
export BETTER_AUTH_SECRET="$(openssl rand -hex 32)"
```

### 1.3 执行构建导出

```bash
cd /Users/l/Projects/deerflow2.0-enhanced/deploy/linux

# 如果 sqlQuery 不在默认路径，指定一下
# export SQLQUERY_ROOT=/your/path/to/sqlQuery

./build-and-export.sh
```

脚本会依次：
1. 构建 `deerflow-frontend`（~3-5 分钟，pnpm install + build）
2. 构建 `deerflow-nginx`（~10 秒）
3. 构建 `dataagent-backend`（~5-10 分钟，装 Python 依赖）
4. 拉取 `langchain/langgraph-api`
5. `docker save` 导出 4 个 tar 并 gzip 压缩
6. 打包 sqlQuery 源码到 `sqlquery-src/`
7. 拷贝 compose + 部署脚本 + 文档

产出：`deploy/linux/deerflow-offline-bundle/`

```
deerflow-offline-bundle/
├── images/
│   ├── deerflow-frontend.tar.gz
│   ├── deerflow-nginx.tar.gz
│   ├── dataagent-backend.tar.gz
│   └── langgraph-api.tar.gz
├── sqlquery-src/              ← LangGraph Server 挂载用（2MB）
│   ├── langgraph.json
│   ├── requirements.txt
│   ├── backend/
│   ├── workspace/
│   └── .env                   ← 占位，服务器上填实际值
├── compose/
│   ├── docker-compose.offline.yml
│   └── nginx.conf
├── .env.docker.example        ← compose 环境变量模板
├── deploy-offline.sh          ← 服务器一键部署脚本
└── README-offline.md          ← 本文档副本
```

### 1.4 传到服务器

```bash
# 方式 A：打成一个 tar（推荐，传一个文件）
cd /Users/l/Projects/deerflow2.0-enhanced/deploy/linux
tar -czf deerflow-offline-bundle.tar.gz deerflow-offline-bundle

scp deerflow-offline-bundle.tar.gz user@<server>:/opt/deerflow/
ssh user@<server> 'cd /opt/deerflow && tar -xzf deerflow-offline-bundle.tar.gz'

# 方式 B：直接 scp 目录（文件多，慢）
scp -r deerflow-offline-bundle user@<server>:/opt/deerflow/
```

---

## Part 2：离线服务器操作

### 2.1 进入离线包目录

```bash
ssh user@<server>
cd /opt/deerflow/deerflow-offline-bundle
ls
```

### 2.2 填配置（关键，必做）

**要填两个 `.env` 文件**（内容基本一致）：

#### A. `sqlquery-src/.env` —— LangGraph Server 读

```bash
cp .env.docker.example sqlquery-src/.env
vim sqlquery-src/.env
```

#### B. `.env.docker` —— compose 和 backend 容器读

```bash
cp .env.docker.example .env.docker
vim .env.docker
```

**必填项**（两个文件都要填）：

```env
# 数据库
SYS_DATABASE_HOST=<MySQL IP>
SYS_DATABASE_PORT=3307
SYS_DATABASE_USER=root
SYS_DATABASE_PASSWORD=<密码>
SYS_DATABASE_NAME=sdata_sjt_c30
DATAPP_ID=1409345383870331
SOURCE_TYPE=102

YW_DATABASE_HOST=<MySQL IP>
YW_DATABASE_PORT=3307
YW_DATABASE_USER=root
YW_DATABASE_PASSWORD=<密码>
YW_DATABASE_NAME=sdata_sjt_c30_yewu

# AES 密钥（解密数据源密码，从 sqlQuery 仓库抄）
AES_KEY=<从开发机 sqlQuery/.env 抄>
AES_IV=<从开发机 sqlQuery/.env 抄>

# DeepSeek
OPENAI_API_BASE=https://api.deepseek.com
OPENAI_API_KEY=sk-<你的key>
LLM_MODEL=openai:deepseek-v4-flash
LLM_THINKING=disabled

# 知识库 / 向量库 / Embedding（不用知识库可保留占位）
KNO_TABLE_GLOSSARY=glossary
KNO_TABLE_METRICS=metrics
MILVUS_URI=http://<milvus-ip>:19530
MILVUS_DB_NAME=kb_base_124
MILVUS_COLLECTIONS=sjt_glossary_embedding,sjt_metrics_embedding
MILVUS_TEXT_FIELD=text
EMBEDDING_API_URL=http://<emb-ip>:3027/api/v1.0/vectorizationTexts/service

# 权限 API
PERMISSION_API_URL=https://<perm-ip>:58443
PERMISSION_CACHE_TTL=300
PERMISSION_API_VERIFY_SSL=false

SHOW_CHART=false
```

**`.env.docker` 还要加 compose 元配置**（顶部）：

```env
# 对外端口（宿主机 80 被占就改 8000）
EXPOSE_PORT=80

# sqlQuery 源码挂载路径（离线包内的相对路径）
SQLQUERY_PATH=/opt/deerflow/deerflow-offline-bundle/sqlquery-src
WORKSPACE_DIR=/opt/deerflow/deerflow-offline-bundle/data/workspace

# Better Auth secret（前端镜像已烘焙，这里只给 backend 用）
BETTER_AUTH_SECRET=<openssl rand -hex 32 生成>

# 镜像标签（固定）
SQLQUERY_BACKEND_IMAGE=dataagent-backend:latest
```

> 💡 **快捷方式**：从开发机的 `/Users/l/Projects/Sdata/sqlQuery/.env` 直接拷贝过来，再补上上面的 compose 元配置即可。

### 2.3 一键部署

```bash
cd /opt/deerflow/deerflow-offline-bundle
./deploy-offline.sh
```

脚本会自动：
1. `docker load` 加载 4 个镜像 tar
2. 检查配置
3. `docker compose up -d` 启动 4 个容器
4. 显示状态

成功输出类似：
```
→ 加载离线镜像...
  · 加载 deerflow-frontend.tar.gz ...
  Loaded image: deerflow-frontend:latest
  ...
→ 启动 4 个容器...

→ 容器状态：
NAME                STATUS         PORTS
deerflow-nginx      Up 3 seconds   0.0.0.0:80->80/tcp
deerflow-frontend   Up 4 seconds   3000/tcp
deerflow-backend    Up 4 seconds   8001/tcp
deerflow-langgraph  Up 3 seconds   2024/tcp

✅ 部署完成。访问 http://<服务器IP>:80/
```

### 2.4 验证

```bash
# 健康检查
curl http://localhost/healthz
# → {"status":"ok"}

curl http://localhost/api/health
# → {"status":"ok","mode":"dataagent"}

curl http://localhost/api/models
# → {"models":[{"name":"deepseek-v4-flash",...}]}

# 浏览器打开
# http://<服务器IP>/  → 应直接进 /workspace，不跳 /login
```

---

## Part 3：日常运维

```bash
cd /opt/deerflow/deerflow-offline-bundle

./deploy-offline.sh status     # 查看状态
./deploy-offline.sh logs       # 跟随日志
./deploy-offline.sh restart    # 重启
./deploy-offline.sh down       # 停止删除容器
./deploy-offline.sh up         # 重新启动（不重新 load）

# 单服务日志
docker compose -f compose/docker-compose.offline.yml --env-file .env.docker logs -f frontend
docker compose -f compose/docker-compose.offline.yml --env-file .env.docker logs -f backend
docker compose -f compose/docker-compose-offline.yml --env-file .env.docker logs -f langgraph
```

### 更新版本

```bash
# 开发机：重新构建 + 传 tar
cd /Users/l/Projects/deerflow2.0-enhanced/deploy/linux
./build-and-export.sh
tar -czf deerflow-offline-bundle.tar.gz deerflow-offline-bundle
scp deerflow-offline-bundle.tar.gz user@<server>:/opt/deerflow/

# 服务器：解压 + 重 load + 重启
ssh user@<server> << 'EOF'
cd /opt/deerflow
tar -xzf deerflow-offline-bundle.tar.gz
cd deerflow-offline-bundle
./deploy-offline.sh load       # 重 load 会覆盖旧镜像
./deploy-offline.sh up
EOF
```

> ⚠️ 注意：重新解压会覆盖 `sqlquery-src/.env` 和 `.env.docker`。
> 更新前先备份：`cp .env.docker .env.docker.bak; cp sqlquery-src/.env sqlquery-src/.env.bak`

---

## 常见问题

### 1. `deploy-offline.sh` 提示要编辑 .env.docker

首次运行脚本检测到没配 `.env.docker`，会自动从模板创建并退出。按提示编辑后重新运行即可：

```bash
vim .env.docker
vim sqlquery-src/.env
./deploy-offline.sh
```

### 2. backend 容器报 MySQL 连接失败

容器内测试连通性：

```bash
docker exec deerflow-backend python -c "
import pymysql
pymysql.connect(host='<MySQL IP>', port=3307, user='root', password='<密码>')
print('OK')
"
```

常见原因：
- MySQL 监听 `127.0.0.1` 而非 `0.0.0.0` → 改 MySQL 配置
- 防火墙拦截 → `firewall-cmd --add-port=3307/tcp`
- MySQL 在宿主机 → `.env.docker` 里 host 用服务器内网 IP，不要用 localhost

### 3. langgraph 容器启动后立即退出

```bash
docker logs deerflow-langgraph
```

常见：
- `sqlquery-src/.env` 没填或填错（langgraph.json 写死了读 `./.env`）
- `backend/agent/graph.py` 编译错误 → 重新构建 backend 镜像
- MySQL checkpointer 初始化失败 → 检查 `SYS_DATABASE_*`

### 4. 访问 / 跳 /login

镜像构建时 `DEER_FLOW_AUTH_DISABLED=1` 没生效。`build-and-export.sh` 已在 Dockerfile 第 39 行烘焙了这个 ENV。如果还跳登录，重新构建前端镜像：

```bash
# 开发机
docker build --platform linux/amd64 \
    -f deploy/linux/frontend.Dockerfile \
    -t deerflow-frontend:latest \
    --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
    --build-arg BETTER_AUTH_SECRET="$(openssl rand -hex 32)" \
    .
docker save deerflow-frontend:latest | gzip > deerflow-frontend.tar.gz
# 传服务器后重新 load
```

### 5. docker load 报磁盘不足

4 个镜像约 3-4GB。`df -h` 检查 `/var/lib/docker` 所在分区空间。

### 6. 端口 80 被占用

`.env.docker` 改 `EXPOSE_PORT=8000`（或其他端口），重启：

```bash
./deploy-offline.sh down
./deploy-offline.sh up
```

### 7. 流式回复断开

nginx 已关 buffering。检查宿主机是否有云厂商 SLB 设了 60s 超时，需在其上配长连接。

---

## 安全建议

1. **`BETTER_AUTH_SECRET`**：生产环境务必用强随机串（`openssl rand -hex 32`）。
2. **`DEER_FLOW_AUTH_DISABLED=1`**：当前是匿名模式，任何能访问 URL 的人都能用。生产环境有敏感数据时，需要在 sqlQuery backend 实现 `/api/v1/auth/*` 端点后关掉此开关。
3. **`AES_KEY`/`AES_IV`**：与数据源密码加密绑定，泄露后数据源密码可被解密。
4. **MySQL 密码**：用强密码，限制 IP。
5. **TLS**：nginx 当前只监听 80。建议前置 LB 或用 certbot 加证书。

---

## 文件清单对比（在线 vs 离线）

| 项目 | 在线部署 | 离线部署 |
|---|---|---|
| compose 文件 | `docker-compose.yml`（含 build） | `docker-compose.offline.yml`（纯 image） |
| 服务器需要源码 | 是（frontend + sqlQuery） | 否（只有 sqlquery-src 2MB） |
| 服务器需要联网 | 是（拉镜像、npm/pip） | 否 |
| 镜像来源 | 服务器上 build | 开发机 build → tar → load |
| 部署命令 | `docker compose up -d --build` | `./deploy-offline.sh` |
