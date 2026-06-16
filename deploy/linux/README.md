# Linux Docker 部署：DataAgent 前端 + sqlQuery backend

DataAgent 前端 + sqlQuery 后端（FastAPI + LangGraph 兼容层）打包成 **3 个容器**部署到 Linux。

> **离线部署**请看 [README-offline.md](./README-offline.md)，本文档适用于**在线构建**场景。

## 架构

```
                ┌──────────────────┐
                │   Host :8098     │
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │  nginx 容器       │
                │  (反代 + SSE)     │
                └─┬──────┬─────────┘
                  │      │
        ┌─────────▼┐  ┌──▼──────────────┐
        │ frontend │  │ backend          │
        │ Next.js  │  │ FastAPI +        │
        │ :3000    │  │ LangGraph 兼容层  │
        └──────────┘  │ :8003            │
                      └──────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  外部依赖            │
                    │  • MySQL            │
                    │  • Milvus（可选）    │
                    │  • DeepSeek API     │
                    └─────────────────────┘
```

| 容器 | 端口（内部） | 镜像 | 用途 |
|---|---|---|---|
| `nginx` | 80 → 对外 | `deerflow-nginx:latest` | 统一入口，反代 + SSE |
| `frontend` | 3000 | `deerflow-frontend:latest` | Next.js standalone |
| `backend` | 8003 | `dataagent-backend:latest` | FastAPI + LangGraph 兼容层 |

> **不再使用 langgraph-api 镜像**。LangGraph Platform 兼容接口由 backend 的 `langgraph_compat.py` 提供。

---

## 前置条件

### 服务器
- **OS**：CentOS 7+ / Ubuntu 20.04+ / Debian 11+
- **CPU**：x86_64
- **内存**：≥ 4GB（推荐 8GB）
- **磁盘**：≥ 20GB

### 软件
```bash
docker --version          # ≥ 20.10
docker compose version    # v2
```

### 外部依赖
- **MySQL**（5.7+ 或 8.0）：数据源元信息、对话持久化、checkpointer
- **DeepSeek API Key**

---

## 部署步骤

### Step 1 — 配置环境变量

```bash
cd /path/to/deploy/linux
cp .env.docker.example .env.docker
vim .env.docker
```

**必改项**：
- `SYS_DATABASE_PASSWORD` — 数据库密码
- `AES_KEY` / `AES_IV` — 数据源解密密钥
- `OPENAI_API_KEY` — DeepSeek API key
- `EXPOSE_PORT` — 对外端口（默认 80，如被占用改 8098 等）

### Step 2 — 构建 + 启动

```bash
# 构建所有镜像（需要联网拉基础镜像）
docker compose --env-file .env.docker -f docker-compose.offline.yml up -d --build
```

或用构建脚本（Windows 开发机）：
```powershell
.\build-and-export.ps1
```

### Step 3 — 验证

```bash
curl http://localhost:8098/api/health
# → {"status":"ok","mode":"dataagent"}

curl -X POST http://localhost:8098/api/langgraph/assistants/search -H "Content-Type: application/json" -d '{}'
# → [{"assistant_id":"lead_agent",...}]
```

浏览器访问 `http://<server-ip>:8098/`

---

## 日常运维

```bash
# 用 manage.sh 一键管理
sh manage.sh status    # 状态
sh manage.sh logs      # 日志
sh manage.sh restart   # 重启
sh manage.sh down      # 停止
sh manage.sh update    # 更新后端代码

# 诊断
sh diagnose.sh              # 完整诊断
sh diagnose.sh langgraph    # LangGraph 路径
sh diagnose.sh sse          # SSE 路径
```

---

## 常见问题

### backend 报 MySQL 连接失败
- MySQL 监听 `127.0.0.1` → 改为 `0.0.0.0`
- `.env.docker` 的 host 用了 localhost → 改成内网 IP

### 502 Bad Gateway
```bash
docker logs deerflow-backend --tail 20
sh diagnose.sh
```

### 对话标题 untitled
确认 `langgraph_compat.py` 的 `search_threads` 返回 `"values": {"title": ...}`。

### matplotlib 中文方框
```bash
docker exec deerflow-backend bash -c "apt-get install -y fonts-noto-cjk && fc-cache -f"
docker commit deerflow-backend dataagent-backend:latest
sh manage.sh restart
```

---

## 更多文档

- [README-offline.md](./README-offline.md) — 离线部署完整指南
- [DEV-NOTES.md](./DEV-NOTES.md) — 开发记录（踩坑 + 改动清单）
- [manage.sh](./manage.sh) — 部署管理脚本
- [diagnose.sh](./diagnose.sh) — 诊断脚本
