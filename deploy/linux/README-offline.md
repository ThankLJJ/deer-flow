# 离线部署指南：DataAgent 前端 + sqlQuery 后端

适用场景：**目标服务器无外网**，需要在有网的开发机上构建好一切，打包传过去直接运行。

服务器环境：CentOS/RHEL x86_64，已安装 Docker + Compose。

---

## 方案总览

```
开发机（有网 x86_64）                    离线服务器（内网 x86_64）
────────────────────                    ────────────────────────
build-and-export.ps1                    manage.sh deploy
  ↓ 构建 3 个镜像                          ↓ docker load 3 个 tar
  ↓ docker save → tar.gz                   ↓ docker compose up -d
  ↓ 打包 sqlQuery 源码（2MB）
  ↓ 打包 compose + 配置
  ↓
deerflow-offline-bundle/  ──── scp ────→  /opt/dataAgent/
                                            └─ 一键 deploy
```

**架构**：3 个容器，不依赖 langgraph-api 镜像。

- `frontend`（Next.js standalone）：前端页面
- `backend`（FastAPI）：业务 API + **LangGraph Platform 兼容层**（内嵌在 backend）
- `nginx`：统一反代入口

---

## 3 个镜像清单

| 镜像 | 大小（压缩后） | 用途 |
|---|---|---|
| `deerflow-frontend:latest` | ~105MB | Next.js standalone |
| `deerflow-nginx:latest` | ~20MB | nginx 反代 |
| `dataagent-backend:latest` | ~300MB | FastAPI + LangGraph 兼容层 + 中文字体 |

打包后整体约 **425MB**。

> 不再使用 `langchain/langgraph-api` 镜像。LangGraph 兼容接口已内嵌到 backend。

---

## Part 1：开发机操作（Windows + PowerShell）

### 1.1 执行构建导出

```powershell
cd C:\Users\L\Documents\deer-flows\deploy\linux
.\build-and-export.ps1
```

产出 `deerflow-offline-bundle/`，内含 3 个镜像 tar.gz + 源码 + compose + 脚本。

### 1.2 传到服务器

```powershell
tar -czf deerflow-offline-bundle.tar.gz deerflow-offline-bundle
scp deerflow-offline-bundle.tar.gz root@<server>:/opt/dataAgent/
ssh root@<server> 'cd /opt/dataAgent && tar -xzf deerflow-offline-bundle.tar.gz'
```

---

## Part 2：离线服务器操作

### 2.1 填配置

```bash
cd /opt/dataAgent/deerflow-offline-bundle
cp .env.docker.example .env.docker
vim .env.docker
```

必填：SYS_DATABASE_PASSWORD / AES_KEY / AES_IV / OPENAI_API_KEY / EXPOSE_PORT

### 2.2 一键部署

```bash
sh manage.sh deploy
```

### 2.3 验证

```bash
curl http://localhost:8098/api/health
# → {"status":"ok","mode":"dataagent"}
```

---

## Part 3：日常运维

```bash
sh manage.sh status           # 状态
sh manage.sh logs             # 日志
sh manage.sh restart          # 重启
sh manage.sh down             # 停止
sh manage.sh update           # 更新后端代码
sh manage.sh update-frontend  # 更新前端镜像
sh diagnose.sh                # 完整诊断
sh diagnose.sh langgraph      # LangGraph 路径诊断
sh diagnose.sh sse            # SSE 路径诊断
```

---

## 常见问题

1. **MySQL 连接失败**：检查 .env.docker 的 host 不能用 localhost
2. **502**：`docker logs deerflow-backend` + `sh diagnose.sh`
3. **标题 untitled**：确认 search 返回 values.title
4. **文件按钮不显示**：确认 get_thread 用 graph() 的 checkpointer
5. **沙箱禁止导入**：确认 python_sandbox.py 白名单含 random/time/csv
6. **中文方框**：`apt-get install fonts-noto-cjk`
7. **端口占用**：改 .env.docker 的 EXPOSE_PORT
