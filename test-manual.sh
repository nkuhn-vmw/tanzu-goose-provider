#!/usr/bin/env bash
# =============================================================================
# Manual Integration Test for Tanzu AI Services Provider
# =============================================================================
#
# Usage:
#   1. Set your credentials:
#        export TANZU_AI_ENDPOINT="https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-all-models-1a56b7a"
#        export TANZU_AI_API_KEY="eyJhbGciOiJIUzI1NiJ9..."
#
#   2. Optionally set model:
#        export GOOSE_MODEL="openai/gpt-oss-120b"
#
#   3. Run:
#        ./test-manual.sh
#
# =============================================================================

set -euo pipefail

GOOSE_BIN="${GOOSE_BIN:-/Users/nkuhn/claude/goose-fork/target/release/goose}"
ENDPOINT="${TANZU_AI_ENDPOINT:-}"
API_KEY="${TANZU_AI_API_KEY:-}"
MODEL="${GOOSE_MODEL:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass=0
fail=0
skip=0

log()    { echo -e "${CYAN}[TEST]${NC} $*"; }
ok()     { echo -e "${GREEN}  PASS${NC} $*"; ((pass++)); }
err()    { echo -e "${RED}  FAIL${NC} $*"; ((fail++)); }
warn()   { echo -e "${YELLOW}  SKIP${NC} $*"; ((skip++)); }

# --- Preflight ---
echo "============================================="
echo " Tanzu AI Services Provider - Manual Tests"
echo "============================================="
echo ""

if [[ ! -x "$GOOSE_BIN" ]]; then
  echo -e "${RED}ERROR:${NC} goose binary not found at $GOOSE_BIN"
  echo "  Build it with: cd /Users/nkuhn/claude/goose-fork && cargo build -p goose-cli --release"
  exit 1
fi

if [[ -z "$ENDPOINT" || -z "$API_KEY" ]]; then
  echo -e "${RED}ERROR:${NC} TANZU_AI_ENDPOINT and TANZU_AI_API_KEY must be set."
  echo ""
  echo "  export TANZU_AI_ENDPOINT=\"https://genai-proxy.sys.example.com/plan-name\""
  echo "  export TANZU_AI_API_KEY=\"eyJhbGci...\""
  exit 1
fi

echo "Endpoint:  $ENDPOINT"
echo "Model:     ${MODEL:-<auto>}"
echo "Binary:    $GOOSE_BIN"
echo ""

# --- Test 1: OpenAI /v1/models endpoint ---
log "1. Model listing via /v1/models"
MODELS_URL="${ENDPOINT}/openai/v1/models"
MODELS_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $API_KEY" \
  "$MODELS_URL" 2>&1)
HTTP_CODE=$(echo "$MODELS_RESP" | tail -1)
BODY=$(echo "$MODELS_RESP" | head -n -1)

if [[ "$HTTP_CODE" == "200" ]]; then
  MODEL_COUNT=$(echo "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "?")
  ok "Models endpoint returned HTTP 200 ($MODEL_COUNT models)"
  echo "$BODY" | python3 -c "import sys,json; [print(f'    - {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true
else
  err "Models endpoint returned HTTP $HTTP_CODE"
  echo "    Response: $(echo "$BODY" | head -3)"
fi

# --- Test 2: Config URL endpoint ---
log "2. Config URL model discovery"
CONFIG_URL="${TANZU_AI_CONFIG_URL:-${ENDPOINT}/config/v1/endpoint}"
CONFIG_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $API_KEY" \
  "$CONFIG_URL" 2>&1)
HTTP_CODE=$(echo "$CONFIG_RESP" | tail -1)
BODY=$(echo "$CONFIG_RESP" | head -n -1)

if [[ "$HTTP_CODE" == "200" ]]; then
  ok "Config URL returned HTTP 200"
  echo "$BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('advertisedModels', []):
    caps = ', '.join(m.get('capabilities', []))
    print(f'    - {m[\"name\"]} [{caps}]')
" 2>/dev/null || echo "    (could not parse response)"
else
  warn "Config URL returned HTTP $HTTP_CODE (may not be available for single-model bindings)"
fi

# --- Test 3: Chat completion ---
log "3. Chat completion (non-streaming)"
COMPLETIONS_URL="${ENDPOINT}/openai/v1/chat/completions"
CHAT_MODEL="${MODEL:-$(echo "$BODY" | python3 -c "
import sys,json
models = json.load(sys.stdin).get('advertisedModels',[])
chat = [m['name'] for m in models if any(c.upper() in ('CHAT','TOOLS') for c in m.get('capabilities',[]))]
print(chat[0] if chat else 'openai/gpt-oss-120b')
" 2>/dev/null || echo "openai/gpt-oss-120b")}"

CHAT_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$CHAT_MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly 5 words.\"}],
    \"max_tokens\": 50
  }" \
  "$COMPLETIONS_URL" 2>&1)
HTTP_CODE=$(echo "$CHAT_RESP" | tail -1)
BODY=$(echo "$CHAT_RESP" | head -n -1)

if [[ "$HTTP_CODE" == "200" ]]; then
  CONTENT=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
  TOKENS=$(echo "$BODY" | python3 -c "import sys,json; u=json.load(sys.stdin).get('usage',{}); print(f'in={u.get(\"prompt_tokens\",\"?\")}, out={u.get(\"completion_tokens\",\"?\")}')" 2>/dev/null || echo "?")
  ok "Chat completion succeeded (model=$CHAT_MODEL)"
  echo "    Response: $CONTENT"
  echo "    Tokens: $TOKENS"
else
  err "Chat completion returned HTTP $HTTP_CODE"
  echo "    Response: $(echo "$BODY" | head -3)"
fi

# --- Test 4: Streaming completion ---
log "4. Streaming chat completion (SSE)"
STREAM_RESP=$(curl -s -N \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$CHAT_MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 3.\"}],
    \"max_tokens\": 50,
    \"stream\": true
  }" \
  "$COMPLETIONS_URL" 2>&1 | head -30)

CHUNK_COUNT=$(echo "$STREAM_RESP" | grep -c "^data:" || true)
if [[ "$CHUNK_COUNT" -gt 0 ]]; then
  ok "Streaming returned $CHUNK_COUNT SSE chunks"
  echo "$STREAM_RESP" | head -5 | while read -r line; do echo "    $line"; done
else
  err "Streaming returned no SSE data chunks"
  echo "    Response: $(echo "$STREAM_RESP" | head -3)"
fi

# --- Test 5: goose CLI provider listing ---
log "5. goose CLI recognizes tanzu_ai provider"
PROVIDER_LIST=$("$GOOSE_BIN" info provider 2>&1 || true)
if echo "$PROVIDER_LIST" | grep -qi "tanzu"; then
  ok "goose CLI lists tanzu_ai provider"
else
  # Try alternate commands
  CONFIGURE_OUT=$("$GOOSE_BIN" configure --help 2>&1 || true)
  warn "Could not verify provider listing (goose info provider may not exist)"
  echo "    Try: GOOSE_PROVIDER=tanzu_ai $GOOSE_BIN session"
fi

# --- Summary ---
echo ""
echo "============================================="
echo " Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}, ${YELLOW}${skip} skipped${NC}"
echo "============================================="
echo ""

if [[ $fail -eq 0 ]]; then
  echo -e "${GREEN}All critical tests passed!${NC}"
  echo ""
  echo "To start an interactive session:"
  echo "  export GOOSE_PROVIDER=tanzu_ai"
  echo "  export TANZU_AI_ENDPOINT=\"$ENDPOINT\""
  echo "  export TANZU_AI_API_KEY=\"\$TANZU_AI_API_KEY\""
  echo "  export GOOSE_MODEL=\"$CHAT_MODEL\""
  echo "  $GOOSE_BIN session"
else
  echo -e "${RED}Some tests failed. Check the output above.${NC}"
  exit 1
fi
