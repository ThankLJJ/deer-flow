# 专门用于对接 sqlQuery backend 的 Linux 部署镜像
# 多阶段构建：deps → builder (standalone) → runner (alpine)
#
# 构建上下文必须是仓库根目录（deerflow2.0-enhanced/），否则 COPY frontend/ 会失败：
#   docker build -f deploy/linux/frontend.Dockerfile -t deerflow-frontend:latest ../../
# 或在 docker-compose.yml 中设 context: ../.. + dockerfile: deploy/linux/frontend.Dockerfile

# ---- Stage 1: deps ----
FROM node:22-alpine AS deps
RUN corepack enable && corepack prepare pnpm@10.26.2 --activate
WORKDIR /app

# 支持受限网络自定义 npm registry
ARG NPM_REGISTRY=""
RUN if [ -n "${NPM_REGISTRY}" ]; then pnpm config set registry "${NPM_REGISTRY}"; fi

# 利用 Docker 层缓存：先拷 lockfile，再 install
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# ---- Stage 2: builder ----
FROM node:22-alpine AS builder
RUN corepack enable && corepack prepare pnpm@10.26.2 --activate
WORKDIR /app

ARG NPM_REGISTRY=""
RUN if [ -n "${NPM_REGISTRY}" ]; then pnpm config set registry "${NPM_REGISTRY}"; fi

COPY --from=deps /app/node_modules ./node_modules
COPY frontend/ .

# 构建时环境变量（NEXT_PUBLIC_* 必须 build 时已知，烘焙进产物）
# 留空 = 同源访问，nginx 统一反代 /api/* 和 /threads, /runs
ENV NEXT_PUBLIC_BACKEND_BASE_URL=""
ENV NEXT_PUBLIC_LANGGRAPH_BASE_URL=""
ENV SKIP_ENV_VALIDATION=1
ENV NEXT_CONFIG_BUILD_OUTPUT=standalone
# auth-disabled 模式（绕过 /api/v1/auth/*）
ENV DEER_FLOW_AUTH_DISABLED=1
# Better Auth 需要 secret 才能通过 prod 模式的 env 校验
ARG BETTER_AUTH_SECRET="docker-build-secret-change-me"
ENV BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}

RUN pnpm build

# ---- Stage 3: runner ----
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_CONFIG_BUILD_OUTPUT=standalone
ENV DEER_FLOW_AUTH_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# 非 root 用户
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# 拷贝 standalone 产物（已包含 server.js + 最小 node_modules）
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

USER nextjs
EXPOSE 3000

# 健康检查（Next.js 默认无 /healthz，用首页 200 判断）
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:3000/ || exit 1

CMD ["node", "server.js"]
