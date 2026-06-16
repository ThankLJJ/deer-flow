#!/usr/bin/env bash
set -uo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$BUNDLE_DIR/.env.docker"
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){ echo -e "  ${G}OK${N} $*"; }
fail(){ echo -e "  ${R}X${N} $*"; }
head(){ echo -e "\n${C}>>> $*${N}"; }
declare -a P
prob(){ P+=("[$1][$2] $3 -> $4"); }
ge(){ grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || echo "${2:-}"; }
ph(){ case "$1" in "" | "change-me" | "sk-change-me") return 0;; *) return 1;; esac; }
tcp(){ timeout "${3:-3}" bash -c "echo>/dev/tcp/$1/$2" 2>/dev/null; }
MODE="${1:-full}"
PORT=$(ge EXPOSE_PORT 80)
echo -e "${B}=== DataAgent 诊断 ($MODE) ===${N}"

if [ "$MODE" = "full" ]; then
  head "1/8 Docker"
  docker info >/dev/null 2>&1 && ok "docker OK" || { fail "docker down"; prob FAIL Docker down "systemctl start docker"; }
  docker compose version >/dev/null 2>&1 && ok "compose OK" || fail "compose missing"

  head "2/8 配置"
  [ -f "$ENV_FILE" ] && ok ".env OK" || { fail "no .env.docker"; prob FAIL cfg missing "manage.sh deploy"; }
  SYS=$(ge SYS_DATABASE_PASSWORD); ph "$SYS" && { fail "DB密码未填"; prob FAIL cfg pass "vim .env.docker"; } || ok "DB密码OK"
  KEY=$(ge OPENAI_API_KEY); ph "$KEY" && { fail "API key 未填"; prob FAIL llm key "vim .env.docker"; } || ok "API key OK"

  head "3/8 容器"
  for n in deerflow-frontend deerflow-backend deerflow-nginx; do
    s=$(docker ps -a --format '{{.Status}}' --filter "name=^${n}$" 2>/dev/null | head -1)
    [ -z "$s" ] && { fail "$n 未创建"; prob FAIL "$n" missing "manage.sh deploy"; continue; }
    echo "$s" | grep -qi '^Up' && ok "$n Up" || { fail "$n: $s"; prob FAIL "$n" "$s" "docker logs $n"; }
  done
  for n in deerflow-backend deerflow-frontend; do
    oom=$(docker inspect "$n" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "")
    [ "$oom" = "true" ] && { fail "$n OOMKilled"; prob FAIL "$n" "内存不足" "增大内存"; }
  done

  head "4/8 外部依赖"
  H=$(ge SYS_DATABASE_HOST); P2=$(ge SYS_DATABASE_PORT 3306)
  [ -n "$H" ] && { tcp "$H" "$P2" 3 && ok "DB $H:$P2 可达" || { fail "DB 不可达"; prob FAIL db unreachable "检查地址"; }; }
  OB=$(ge OPENAI_API_BASE)
  if [ -n "$OB" ]; then
    LH=$(echo "$OB" | sed -E 's|^https?://||;s|/.*$||;s|:.*$||')
    tcp "$LH" 443 3 && ok "LLM API 可达" || { fail "LLM 不可达"; prob WARN llm unreachable "确认外网"; }
  fi
fi

if [ "$MODE" = "full" ] || [ "$MODE" = "sse" ]; then
  head "5/8 SSE 路径 (/api/chat/*)"
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/health" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "/api/health 200" || { fail "health $c"; prob FAIL sse backend "docker logs"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H "Content-Type: application/json" \
      -d '{"question":"t","thread_id":"d"}' "http://localhost:$PORT/api/chat/stream" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "/api/chat/stream 200" || { fail "stream $c"; prob FAIL sse stream "检查 backend"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/chat/history/d" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "/api/chat/history 200" || fail "history $c"
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/conversations?user_id=d" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "/api/conversations 200" || fail "conv $c"
fi

if [ "$MODE" = "full" ] || [ "$MODE" = "langgraph" ]; then
  head "6/8 LangGraph SDK 路径 (/api/langgraph/*)"
  r=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" -d '{}' \
      "http://localhost:$PORT/api/langgraph/assistants/search" 2>/dev/null || echo F)
  echo "$r" | grep -q "lead_agent" && ok "assistants OK" || { fail "assistants 异常"; prob FAIL lg assistants "检查 langgraph_compat.py"; }
  r=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" -d '{}' \
      "http://localhost:$PORT/api/langgraph/threads" 2>/dev/null || echo F)
  echo "$r" | grep -q "thread_id" && ok "threads POST OK" || { fail "threads 异常"; prob FAIL lg threads "检查"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/langgraph/threads/diag" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "threads/{id} GET 200" || { fail "threads/{id} $c"; prob FAIL lg get "检查 _get_graph_state"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/langgraph/threads/diag/state" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "state 200" || { fail "state $c"; prob FAIL lg state "检查"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H "Content-Type: application/json" \
      -d '{"assistant_id":"lead_agent","input":{"messages":[{"type":"human","content":[{"type":"text","text":"hi"}]}]},"context":{"user_id":""}}' \
      "http://localhost:$PORT/api/langgraph/threads/diag/runs/stream" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "runs/stream 200" || { fail "runs/stream $c"; prob FAIL lg runs "检查 graph()"; }
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/api/channels/providers" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "channels 200" || fail "channels $c"
  r=$(curl -s --max-time 5 "http://localhost:$PORT/api/models" 2>/dev/null || echo F)
  echo "$r" | grep -q "model" && ok "models OK" || fail "models 异常"
fi

if [ "$MODE" = "full" ]; then
  head "7/8 nginx"
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$PORT/healthz" 2>/dev/null || echo 000)
  [ "$c" = "200" ] && ok "healthz OK" || fail "nginx $c"
  nc=$(docker exec deerflow-nginx cat /etc/nginx/nginx.conf 2>/dev/null || echo "")
  echo "$nc" | grep -q "backend:8003" && ok "upstream=backend:8003" || { echo "$nc" | grep -q "8001" && { fail "upstream 还是 8001"; prob FAIL nginx port "改 8003"; }; }
  echo "$nc" | grep -q "/api/langgraph/" && ok "/api/langgraph/ 路由OK" || fail "缺 /api/langgraph/ 路由"

  head "8/8 日志扫描"
  for n in deerflow-backend deerflow-frontend deerflow-nginx; do
    e=$(docker logs "$n" --tail 100 2>&1 | grep -iE 'Traceback|ImportError|ModuleNotFound|Access denied|Connection refused|RuntimeError|cannot schedule' | tail -3 || true)
    [ -n "$e" ] && { echo "  [$n]:"; echo "$e" | sed 's/^/      /'; prob WARN "$n" "日志有错误" "检查详细日志"; } || ok "$n 日志正常"
  done
fi

echo ""
echo -e "${B}=== 诊断汇总 ===${N}"
if [ ${#P[@]} -eq 0 ]; then
  echo -e "${G}全部通过${N}"
  exit 0
fi
echo -e "${R}${#P[@]} 个问题${N}"
for p in "${P[@]}"; do echo "  - $p"; done
echo ""
echo "修复后重启：sh manage.sh restart"
exit 1
