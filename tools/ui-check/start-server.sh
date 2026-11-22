#!/bin/sh
# A local web interface for the browser checks: `ai.pl --ui` with one session that has a
# conversation of two exchanges (no model is needed: the revert takes them out), and a project
# root with an account for the project checks. Prints the address, the token and the state dir.
#   AICLI_CHECK_PORT   the port (default 8770)
#   AICLI_CHECK_STATE  the state dir (default: a new temporary directory, kept)
#   AICLI_CHECK_TOKEN  the page's token (default abc123)
set -e
here=$(cd "$(dirname "$0")/../.." && pwd)
port=${AICLI_CHECK_PORT:-8770}
token=${AICLI_CHECK_TOKEN:-abc123}
state=${AICLI_CHECK_STATE:-$(mktemp -d /tmp/aicli-ui-check.XXXXXX)}
mkdir -p "$state/ai/sessions/s1" "$state/root/acme"
printf '%s\n' '{"role":"system","content":"sys"}' '{"role":"user","content":"hello"}' \
  '{"role":"assistant","content":"hi there"}' '{"role":"user","content":"second"}' \
  '{"role":"assistant","content":"second answer"}' > "$state/ai/sessions/s1/chat"
echo sys > "$state/ai/sessions/s1/prompt"
cd "$state/root"
AI_SESSION=s1 AI_DIR="$state/ai" AI_UI_TOKEN="$token" AI_LOCAL_SERVER=http://127.0.0.1:9 \
  AI_WORKSPACE="$state/root" nohup perl "$here/ai.pl" --ui "$port" > "$state/server.log" 2>&1 &
echo $! > "$state/server.pid"
sleep 2
echo "page:  http://127.0.0.1:$port/?token=$token"
echo "state: $state"
echo "log:   $state/server.log"
echo "stop:  kill -INT \$(cat $state/server.pid)"
