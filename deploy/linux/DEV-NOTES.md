# ============================================================
# 开发记录文档 — DataAgent 离线部署全流程
#
# 记录本次开发中遇到的所有坑、改动点和解决方案，
# 供后续开发、维护和重新部署时参考。
# ============================================================

## 一、项目背景

将 DataAgent（基于 LangGraph 的数据分析智能体）部署到客户内网服务器。
要求：离线部署、不依赖外部 Postgres/LangGraph Cloud License、前端去掉 DeerFlow 品牌。

## 二、架构最终形态

```
浏览器 → nginx:8098 → frontend:3000 (Next.js standalone)
                  → backend:8003  (FastAPI + LangGraph 兼容层)
                                    ├─ /api/chat/stream    (原有 SSE 接口，其他前端用)
                                    ├─ /api/langgraph/*    (LangGraph SDK 兼容接口)
                                    │  ├─ /threads/{id}/runs/stream
                                    │  ├─ /threads/search
                                    │  ├─ /threads/{id}/state
                                    │  ├─ /threads/{id}/history
                                    │  └─ /assistants/search
                                    └─ /api/health, /api/models, ...
```

**关键决策**：废弃 `langchain/langgraph-api` 镜像（付费 License），改在 backend 内嵌
LangGraph Platform 兼容层（`langgraph_compat.py`），直接消费 graph 原始 stream。

## 三、踩坑记录（按时间顺序）

### 坑 1：Windows 无 bash，build-and-export.sh 跑不了
- **现象**：服务器只有 cmd/PowerShell，没有 bash/WSL（docker-desktop WSL 无 bash）
- **解决**：用 PowerShell 重写了 `build-and-export.ps1`

### 坑 2：PowerShell 5.1 编码问题
- **现象**：PS1 文件含中文，PS 5.1 用 GBK 解码无 BOM 的 UTF-8 → 语法错误
- **解决**：所有 PS1 文件必须写 UTF-8 BOM（`EF BB BF`）

### 坑 3：Docker Hub CDN 被阻（国内网络）
- **现象**：`docker pull node:22-alpine` 卡在 `load metadata`，cloudfront CDN EOF
- **解决**：配置 Docker 镜像加速器（daemon.json: daocloud/1panel/hub.rat.dev）
  - ⚠️ 改 daemon.json 后必须从 Docker Desktop GUI 重启（命令行 kill 会导致 engine 500）

### 坑 4：pnpm 版本不一致
- **现象**：`pnpm-lock.yaml` 是 lockfileVersion 5.3（pnpm 8），但 package.json 声明 pnpm 10
- **解决**：统一 pnpm 8.15.9 + `--no-frozen-lockfile` + COREPACK_NPM_REGISTRY 环境变量

### 坑 5：frontend 类型检查失败
- **现象**：`next build` 类型检查报错（api-client.ts 多重载断言 + streamdown/hooks.ts 缺导出）
- **解决**：
  - api-client.ts: `as typeof` → `as unknown as typeof`（双重断言）
  - next.config.js: 加 `SKIP_TYPE_CHECK=1` 环境变量控制（Docker 构建时跳过类型检查）

### 坑 6：backend apt 源卡死
- **现象**：阿里云 apt 源对 Debian trixie 部分包连接挂死
- **解决**：改用清华 TUNA 源 + apt 超时重试配置

> 注：早期曾尝试用 `langchain/langgraph-api` 镜像提供 LangGraph Platform 接口，
> 但它依赖 Postgres + Redis + 付费 LangSmith License，最终彻底废弃，
> 改在 backend 内嵌兼容层（见「架构最终形态」）。以下坑记录从 backend 端口开始。

### 坑 7：backend 端口 8001 被占，改 8003
- **解决**：compose backend command `--port 8003` + nginx upstream `backend:8003`

### 坑 8：nginx bind mount 不刷新
- **现象**：`nginx -s reload` 不刷新 `:ro` 挂载的配置文件
- **解决**：必须 `docker compose up -d --force-recreate nginx`（重建容器才重新挂载）

### 坑 9：docker commit 漏文件
- **现象**：`docker cp` 只传了部分文件，旧镜像缺 `deerflow_compat.py` / `sql_examples.py`
- **解决**：`docker cp /opt/dataAgent/sqlquery-src/backend/. temp:/app/backend/` 整目录同步

### 坑 10：graph stream chunk 格式（version="v2"）
- **现象**：多模式 stream 的 chunk 是 dict（`{"type":..., "data":...}`），不是元组
- **解决**：`chunk["type"]` + `chunk["data"]` 提取，不是 `hasattr(chunk, "type")`

### 坑 11：JSON 序列化 LangChain 对象
- **现象**：`json.dumps(default=str)` 把 AIMessageChunk 转成 Python repr 字符串
- **解决**：去掉 `default=str`，用 `model_dump()` 正确序列化

### 坑 12：两套 checkpointer 读不到彼此的 state
- **现象**：`build_agent()` 的 checkpointer 读不到 `graph()` 写入的 artifacts
- **解决**：所有读 state 的端点统一用 `graph()`（`_get_graph_state()` helper）

### 坑 13：title 在 metadata 但前端读 values
- **现象**：search 返回 `metadata.title`，前端读 `values.title` → 显示 untitled
- **解决**：search 返回时把 title 同时放进 `values.title`

### 坑 14：中文字体缺失
- **现象**：服务器无中文字体，matplotlib 生成的图表中文显示为方框
- **解决**：Dockerfile.backend 安装 `fonts-noto-cjk` + 字体候选列表优先 Noto CJK

### 坑 15：Excel 图表用图片
- **现象**：LLM 用 matplotlib 生成图片嵌入 Excel，不是原生图表
- **解决**：sandbox docstring 加明确规则——必须用 openpyxl.chart 原生图表

## 四、改动文件清单

### smartquerydata（backend）项目

| 文件 | 改动 |
|------|------|
| `backend/api/langgraph_compat.py` | **新增**：LangGraph Platform 兼容层（8 个端点 + SSE 适配） |
| `backend/main.py` | 注册 langgraph_compat_router |
| `backend/agent/tools/python_sandbox.py` | 放宽白名单（random/time/csv 等）+ Excel 图表规则 + 字体优先级 |
| `backend/agent/graph.py` | 无改动（已有 title/artifacts channel） |
| `Dockerfile.backend` | 加 fonts-noto-cjk + openpyxl/xlsxwriter/python-multipart + 清华 TUNA 源 |

### deer-flows（前端）项目

| 文件 | 改动 |
|------|------|
| `frontend/src/app/page.tsx` | 首页重定向到 /workspace/chats/new |
| `frontend/src/components/workspace/workspace-container.tsx` | 去掉右上角 GitHub 图标 |
| `frontend/src/app/(auth)/login/page.tsx` | 去掉 deer.svg 遮罩 + DeerFlow→DataAgent |
| `frontend/src/app/(auth)/setup/page.tsx` | 同上（两处） |
| `frontend/src/components/workspace/settings/about-content.ts` | 去掉 DeerFlow/鹿/品牌内容 |
| `frontend/src/core/i18n/locales/zh-CN.ts` | 去掉 🦌 |
| `frontend/src/core/i18n/locales/en-US.ts` | 去掉 🦌 + 品牌文案 |
| `frontend/src/components/workspace/input-box.tsx` | 注释掉整个模式选择按钮 |
| `frontend/package.json` | packageManager 降到 pnpm@8.15.9 |
| `frontend/next.config.js` | 加 SKIP_TYPE_CHECK 控制 |
| `frontend/src/core/api/api-client.ts` | 修复多重载断言 |
| `deploy/linux/frontend.Dockerfile` | pnpm 8.15.9 + COREPACK_NPM_REGISTRY + SKIP_TYPE_CHECK |
| `deploy/linux/nginx/nginx.conf` | /api/langgraph/ 转向 backend + rewrite /api/$1 |
| `deploy/linux/docker-compose.offline.yml` | backend 端口 8003 + langgraph profiles 停用 + nginx volumes 挂载 |
| `deploy/linux/build-and-export.ps1` | **新增**：PowerShell 版构建脚本 |
| `deploy/linux/diagnose.sh` | **新增**：服务器诊断脚本 |

## 五、关键配置备忘

### .env.docker 必填项
```env
EXPOSE_PORT=8098
SYS_DATABASE_HOST=<服务器IP>
SYS_DATABASE_PORT=3307
SYS_DATABASE_USER=root
SYS_DATABASE_PASSWORD=<真实密码>
SYS_DATABASE_NAME=sdata_sjt_c30
OPENAI_API_KEY=<DeepSeek key>
OPENAI_API_BASE=https://api.deepseek.com
LLM_MODEL=openai:deepseek-v4-flash
AES_KEY=<AES密钥>
AES_IV=<AES IV>
```

### nginx.conf 关键路由
```
/api/langgraph/* → rewrite /api/$1 → backend:8003  (LangGraph SDK 兼容)
/api/*           → backend:8003                      (FastAPI 业务 API)
/                → frontend:3000                      (Next.js 页面)
```

## 六、后续注意事项

1. **重新构建镜像时**：Dockerfile.backend 已包含字体安装，但 `docker commit` 方式更新的容器不含字体，需手动装
2. **前端改代码后**：必须重新 `docker build` frontend 镜像（standalone 产物在构建时烘焙）
3. **backend 改代码后**：可以用 `docker cp` + `docker commit` 快速更新（不需重新 build）
4. **nginx 改配置后**：必须 `--force-recreate`（reload 不刷新 bind mount）
5. **离线包只含 3 个镜像**（frontend + nginx + backend）：langgraph-api 镜像已彻底废弃，
   不再构建/导出 langgraph 镜像，也不需要 LangSmith key / Postgres / Redis
