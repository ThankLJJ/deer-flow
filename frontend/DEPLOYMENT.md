# DeerFlow 前端部署指南

对接目标：`/Users/l/Projects/Sdata/sqlQuery/backend`

---

## 1. 架构概览

```
┌─────────────────────┐
│  DeerFlow Frontend  │  Next.js 16 (:3000)
│  (Next.js)          │
└──────────┬──────────┘
           │
   ┌───────┴────────┐
   │                │
   ▼                ▼
辅助 REST API     LangGraph SDK
getBackendBaseURL  getLangGraphBaseURL
   │                │
   ▼                ▼
┌──────────────┐  ┌────────────────────┐
│ FastAPI      │  │ LangGraph Server   │
│ backend:8001 │  │ :2024              │
│              │  │                    │
│ /api/models  │  │ /threads/*         │
│ /api/agents  │  │ /runs/*            │
│ /api/skills  │  │   (lead_agent      │
│ /api/memory  │  │    via langgraph   │
│ /api/threads │  │    .json)          │
│   /uploads   │  │                    │
│ /api/workspace│ │                    │
└──────────────┘  └────────────────────┘
```

| 服务 | 端口 | 角色 |
|---|---|---|
| DeerFlow Frontend | 3000 | Next.js dev / standalone |
| sqlQuery FastAPI | 8001 | REST 辅助 API（`backend/main.py`） |
| sqlQuery LangGraph | 2024 | LangGraph Server（`langgraph dev`） |

---

## 2. 前置条件

### 运行环境
- **Node.js** ≥ 22
- **pnpm** ≥ 10.26.2
- **MySQL**（sqlQuery backend 的 LangGraph checkpointer 用，配置 `SYS_DATABASE_*`）

### sqlQuery backend 必须先启动

```bash
cd /Users/l/Projects/Sdata/sqlQuery
./dev.sh
```

`dev.sh` 同时拉起 FastAPI(:8001) 和 LangGraph Server(:2024)。
确认两者就绪：

```bash
curl http://localhost:8001/api/health      # → {"status":"ok","mode":"dataagent"}
curl http://localhost:2024/info            # → LangGraph server info
curl http://localhost:8001/api/models      # → {"models":[...]}
```

---

## 3. 配置文件 `.env.local`

路径：`frontend/.env.local`

```env
# 直连 sqlQuery backend（不走 nginx，开发期最简）
NEXT_PUBLIC_BACKEND_BASE_URL="http://localhost:8001"
NEXT_PUBLIC_LANGGRAPH_BASE_URL="http://localhost:2024"

# 跳过 env.js 校验（让未声明的 DEER_FLOW_AUTH_DISABLED 不报错）
SKIP_ENV_VALIDATION=true

# 鉴权绕过（关键，缺这一行会被 /api/v1/auth/me 拦截跳 /login）
DEER_FLOW_AUTH_DISABLED=1
```

**注意事项**：
- ⚠️ `DEER_FLOW_AUTH_DISABLED=1` 必须**顶格无缩进**，前导空格会被 dotenv 解析为上一行的多行延续，导致绕过开关失效。
- 修改 `.env.local` 后必须**重启** `pnpm dev`（Next.js 不会热加载 env 文件）。
- 生产环境**不要**设 `DEER_FLOW_AUTH_DISABLED=1`（`isAuthDisabledMode()` 在 `NODE_ENV=production` 下自动失效）。

---

## 4. 开发模式

```bash
cd /Users/l/Projects/deerflow2.0-enhanced/frontend
pnpm install
pnpm dev
```

打开 http://localhost:3000 → 直接进 `/workspace`，不跳 `/login`。

### 启动后验证清单

| # | 检查项 | 通过标准 |
|---|---|---|
| 1 | 直接进入 `/workspace` | URL 不被重写到 `/login` |
| 2 | React DevTools 看 `useAuth().user` | 是 `{id:'default', email:'default@test.local', system_role:'admin'}` |
| 3 | 浏览器 Network 面板 | **无** `/api/v1/auth/me` 请求 |
| 4 | 创建新 thread 发消息 | 看到 LangGraph 流式回复 |
| 5 | 提 SQL 类问题 | 看到 `search_schema_meta`/`make_sql_query` 工具步骤 |
| 6 | 上传 CSV | `POST /api/threads/{id}/uploads` 返回 200 |
| 7 | 生成图表 | artifact 面板加载 `/api/threads/{id}/artifacts/...` |
| 8 | 刷新页面 | 历史从 LangGraph checkpoint 恢复 |
| 9 | 切换浏览器 tab 来回 | 不触发任何 `/api/v1/auth/*` 请求 |

---

## 5. 生产构建

### 5.1 Standalone 构建（推荐）

```bash
# 构建前确保 .env.local 中 NEXT_PUBLIC_* 已是生产 URL
NEXT_CONFIG_BUILD_OUTPUT=standalone pnpm build
```

产物在 `.next/standalone/`，连同 `.next/static/` 和 `public/` 拷贝到目标机器即可运行：

```bash
node .next/standalone/server.js
```

默认监听 `:3000`，可用 `PORT=4000 node ...` 修改。

### 5.2 Docker 部署

sqlQuery 仓库已带 `Dockerfile`，前端可参照其模式自建：

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY . .
RUN pnpm build

FROM node:22-alpine
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

构建变量需通过 `ARG`/`ENV` 注入（`NEXT_PUBLIC_*` 必须在 build 时已知）。

### 5.3 经 nginx 反向代理（同源部署，避免 CORS）

如果前端和 sqlQuery backend 同机部署，建议用 nginx 统一前缀：

```nginx
server {
    listen 80;
    server_name your-domain;

    # 前端静态/SSR
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # LangGraph Server（保留 /threads、/runs 原生路径）
    location ~ ^/(threads|runs) {
        proxy_pass http://127.0.0.1:2024;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;            # SSE 必须
        proxy_read_timeout 86400s;
        chunked_transfer_encoding on;
    }

    # FastAPI 辅助 API
    location /api/ {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_buffering off;
        proxy_read_timeout 86400s;
    }
}
```

此时 `.env.local`（或构建时 env）设：

```env
NEXT_PUBLIC_BACKEND_BASE_URL=                  # 空 → 走相对路径 /api/*
NEXT_PUBLIC_LANGGRAPH_BASE_URL=                # 空 → 走相对路径 /api/langgraph/*
```

但注意：**Nginx 路径是 `/threads`/`/runs`**（LangGraph 原生），而前端默认 SDK 走 `/api/langgraph/threads`。要让 nginx 路径对齐，二选一：
- 在 nginx 加 `rewrite ^/api/langgraph/(.*)$ /$1 break;`
- 或保持 `NEXT_PUBLIC_LANGGRAPH_BASE_URL=http://your-domain`（同源但根路径，跳过 `/api/langgraph` 前缀）

---

## 6. 鉴权模式

### 当前（auth-disabled）

通过 `DEER_FLOW_AUTH_DISABLED=1` 触发：
- SSR（`src/core/auth/server.ts:24-29`）直接返回固定 `AUTH_DISABLED_USER`
- 客户端（`src/core/auth/AuthProvider.tsx`）`refreshUser`/`logout` 短路，不再调 `/api/v1/auth/*`
- `fetchWithAuth`（`src/core/api/fetcher.ts`）401 时不跳登录页

**所有 sqlQuery backend 接口收到的 `user_id` 都是空字符串**（前端不主动传），落到全局桶，符合单机单用户场景。

### 未来切回真鉴权

1. 在 sqlQuery backend 实现 `/api/v1/auth/me`、`/logout`、`/setup-status`、`/initialize`、`/change-password`，返回符合 `userSchema`（`src/core/auth/types.ts:5`）的对象。
2. 删除 `.env.local` 中的 `DEER_FLOW_AUTH_DISABLED=1`。
3. 前端代码无需改动，自动走完整鉴权流程（cookie + CSRF + 重定向）。

---

## 7. 故障排查

| 症状 | 排查 |
|---|---|
| 启动后跳 `/login` | `.env.local` 中 `DEER_FLOW_AUTH_DISABLED=1` 是否顶格无缩进？是否重启了 `pnpm dev`？ |
| Network 有 `/api/v1/auth/me` 404 | `AuthProvider.tsx` 的 `refreshUser` 短路没生效，确认 `isAuthDisabledMode()` 返回 true |
| 创建 thread 后无响应 | 浏览器 Network 看 `POST http://localhost:2024/threads/{id}/runs/stream` 是否成功；如失败，查 sqlQuery `langgraph dev` 日志 |
| LangGraph 启动失败 `MySQL checkpointer` | 检查 sqlQuery `.env` 的 `SYS_DATABASE_*` 配置 |
| `fetch failed` ECONNREFUSED | sqlQuery `./dev.sh` 是否在跑？端口 8001/2024 是否被占用？`lsof -i :8001 :2024` |
| 工具调用步骤缺失 | sqlQuery graph 是否暴露 `on_tool_end` 事件（`backend/agent/graph.py`） |
| 文件上传 403/404 | sqlQuery backend 的 `WORKSPACE_DIR/uploads/{thread_id}` 目录权限 |
| CSRF 403 | sqlQuery FastAPI 默认不强制 CSRF，前端读不到 cookie 也不发 header，理论上不会触发；若触发请检查是否被某中间件拦截 |
| 切换 tab 后被踢出登录 | 漏改 `AuthProvider.tsx` 的 visibility change 路径，应通过 `refreshUser` 短路生效 |

### 日志位置

| 服务 | 日志 |
|---|---|
| Next.js dev | `pnpm dev` 终端 stdout |
| sqlQuery FastAPI | `./dev.sh` 终端 stdout，或 `backend.log` |
| sqlQuery LangGraph | `./dev.sh` 终端 stdout（`langgraph dev` 输出） |
| 浏览器 | DevTools Console + Network |

---

## 8. 关键文件速查

| 文件 | 作用 |
|---|---|
| `frontend/.env.local` | 双 URL + 鉴权绕过开关 |
| `frontend/src/core/config/index.ts` | `getBackendBaseURL()` / `getLangGraphBaseURL()` |
| `frontend/src/core/api/api-client.ts` | LangGraph SDK 客户端单例 |
| `frontend/src/core/api/fetcher.ts` | 统一 `fetch`，CSRF + 401 跳登录 |
| `frontend/src/core/auth/auth-disabled-user.ts` | `isAuthDisabledMode()` 实现 |
| `frontend/src/core/auth/server.ts` | SSR 鉴权（已优先短路 auth-disabled） |
| `frontend/src/core/auth/AuthProvider.tsx` | 客户端鉴权 context |
| `frontend/next.config.js` | rewrites（仅在 `NEXT_PUBLIC_*_URL` 未设时生效） |
| `sqlQuery/backend/main.py` | FastAPI 入口 |
| `sqlQuery/backend/api/deerflow_compat.py` | DeerFlow 前端兼容 stub |
| `sqlQuery/backend/agent/graph.py` | LangGraph 图（`lead_agent`） |
| `sqlQuery/langgraph.json` | LangGraph Server 配置 |
| `sqlQuery/dev.sh` | 双服务一键启动 |

---

## 9. 端点覆盖矩阵

前端会调的所有 `/api/*` 端点 vs sqlQuery backend 覆盖情况：

| 端点 | sqlQuery | 备注 |
|---|---|---|
| `GET /api/models` | ✓ | `deerflow_compat.py` |
| `GET /api/agents`、`/api/agents/check` | ✓ stub | 返回空 |
| `GET/PUT /api/skills`、`POST /api/skills/install` | ✓ stub | 忽略 |
| `GET/PUT /api/mcp/config` | ✓ stub | 返回空 |
| `GET /api/memory` | ✓ stub | 返回空 |
| `GET/PUT /api/user-profile` | ✓ stub | |
| `POST /api/threads/{id}/uploads` | ✓ | 实际生效 |
| `GET /api/threads/{id}/uploads/list` | ✓ | |
| `DELETE /api/threads/{id}/uploads/{filename}` | ✓ | |
| `GET /api/threads/{id}/artifacts/*` | ✓ | 映射 workspace |
| `POST /api/threads/{id}/suggestions` | ✓ stub | 返回空 |
| `GET /api/channels` | ✓ stub | |
| `/api/v1/auth/*` | ✗ | 由前端 `DEER_FLOW_AUTH_DISABLED=1` 绕过 |
| `GET /api/threads/{id}/token-usage` | ✗ | 前端容错（返回 null） |
| `GET /api/threads/{id}/runs/{rid}/messages` | ✗ | 前端容错（try/catch） |
| `DELETE /api/threads/{id}` | ✗ | 前端容错（mutation 错误 toast） |
| `/api/memory/facts/*`、`/export`、`/import` | ✗ | 前端容错（feature 失效） |
| `/api/threads/{id}/runs/{rid}/feedback` | ✗ | 前端容错（反馈按钮失效） |
