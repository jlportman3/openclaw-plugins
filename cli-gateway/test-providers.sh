#!/usr/bin/env bash
# ============================================================
# cli-gateway provider integration tests
#
# Tests each detected backend for:
#   1. Basic chat (non-streaming)
#   2. Streaming (SSE format)
#   3. Session memory (multi-turn conversation)
#   4. Tool use (command execution)
#   5. System prompt adherence
#   6. Response format (OpenAI compliance)
#
# Usage:
#   ./test-providers.sh                    # default localhost:4090
#   ./test-providers.sh http://host:port   # custom gateway
#   BACKENDS=claude-code ./test-providers.sh  # test specific backend
# ============================================================

set -uo pipefail

GATEWAY="${1:-http://localhost:4090}"
TIMEOUT=180  # seconds per request (CLI tools can be slow)
MAX_CHAT_RETRIES=2  # retry on transient errors (rate limits)

PASS=0
FAIL=0
SKIP=0
ERRORS=""

# --- Colors ---
G='\033[0;32m'  # green
R='\033[0;31m'  # red
Y='\033[1;33m'  # yellow
C='\033[0;36m'  # cyan
B='\033[1m'     # bold
N='\033[0m'     # reset

pass()    { ((PASS++)); echo -e "    ${G}✓${N} $1"; }
fail()    { ((FAIL++)); echo -e "    ${R}✗${N} $1"; [ -n "${2:-}" ] && echo -e "      ${R}↳ $2${N}"; ERRORS+="  ✗ $1\n"; }
skip()    { ((SKIP++)); echo -e "    ${Y}⊘${N} $1 ${Y}(skipped)${N}"; }
section() { echo -e "\n${B}${C}━━━ $1 ━━━${N}"; }
info()    { echo -e "    ${Y}…${N} $1"; }

# --- JSON helpers (using python3, guaranteed on Ubuntu) ---

# Build a chat request body
build_body() {
  local model="$1" stream="$2"
  shift 2
  # Remaining args are role:content pairs
  python3 -c "
import json, sys
messages = []
for arg in sys.argv[1:]:
    role, content = arg.split(':', 1)
    messages.append({'role': role, 'content': content})
body = {'model': '$model', 'messages': messages, 'stream': $stream}
print(json.dumps(body))
" "$@"
}

# Extract .choices[0].message.content from a non-streaming response
extract_content() {
  python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    if 'error' in r:
        print('ERROR: ' + r['error'].get('message', str(r['error'])))
        sys.exit(1)
    print(r['choices'][0]['message']['content'])
except Exception as e:
    print('ERROR: ' + str(e))
    sys.exit(1)
"
}

# Extract content from SSE stream
extract_sse_content() {
  python3 -c "
import sys, json
content = ''
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('data: '):
        continue
    data = line[6:]
    if data == '[DONE]':
        break
    try:
        obj = json.loads(data)
        if 'error' in obj:
            print('ERROR: ' + obj['error'].get('message', str(obj['error'])))
            sys.exit(1)
        delta = obj.get('choices', [{}])[0].get('delta', {})
        content += delta.get('content', '')
    except json.JSONDecodeError:
        pass
print(content)
"
}

# Validate non-streaming response has correct OpenAI format
validate_response_format() {
  python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    errors = []
    if 'id' not in r: errors.append('missing id')
    elif not r['id'].startswith('chatcmpl-'): errors.append('id should start with chatcmpl-')
    if r.get('object') != 'chat.completion': errors.append('object should be chat.completion')
    if 'created' not in r: errors.append('missing created')
    if 'model' not in r: errors.append('missing model')
    if 'choices' not in r or len(r['choices']) == 0: errors.append('missing/empty choices')
    else:
        c = r['choices'][0]
        if 'message' not in c: errors.append('missing choices[0].message')
        elif c['message'].get('role') != 'assistant': errors.append('message role should be assistant')
        if c.get('finish_reason') != 'stop': errors.append('finish_reason should be stop')
    if 'usage' not in r: errors.append('missing usage')
    else:
        u = r['usage']
        for k in ('prompt_tokens', 'completion_tokens', 'total_tokens'):
            if k not in u: errors.append(f'missing usage.{k}')
    if errors:
        print('ERRORS: ' + '; '.join(errors))
        sys.exit(1)
    print('OK')
except Exception as e:
    print('ERROR: ' + str(e))
    sys.exit(1)
"
}

# Check if string contains a substring (case-insensitive)
contains() {
  echo "$1" | grep -qi "$2"
}

# Generate a random session ID
new_session() {
  python3 -c "import uuid; print(uuid.uuid4())"
}

# ============================================================
# Non-streaming chat request with retry
# Args: model, [session=ID], role:content pairs...
# Returns: response content on stdout
# ============================================================
chat() {
  local model="$1"
  shift
  local session=""
  if [[ "${1:-}" == session=* ]]; then
    session="${1#session=}"
    shift
  fi

  local body
  body=$(build_body "$model" "False" "$@")

  local headers=(-H "Content-Type: application/json")
  [ -n "$session" ] && headers+=(-H "X-Session-Id: $session")

  local attempt=0
  while [ $attempt -le $MAX_CHAT_RETRIES ]; do
    local response
    response=$(curl -s --max-time "$TIMEOUT" "${headers[@]}" -d "$body" "$GATEWAY/v1/chat/completions" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
      echo "ERROR: curl failed (exit $rc): $response"
      return 1
    fi

    # Check for error in response
    local content
    content=$(echo "$response" | extract_content 2>&1)
    local extract_rc=$?

    if [ $extract_rc -eq 0 ] && [[ "$content" != ERROR:* ]]; then
      echo "$content"
      return 0
    fi

    # Retryable? (CLI exit errors, rate limits)
    if [ $attempt -lt $MAX_CHAT_RETRIES ]; then
      ((attempt++))
      local delay=$((attempt * 5))
      echo -e "    ${Y}…${N} Transient error, retry $attempt/$MAX_CHAT_RETRIES in ${delay}s..." >&2
      sleep "$delay"
    else
      echo "$content"
      return 1
    fi
  done
}

# Raw non-streaming request (returns full JSON, no retry)
chat_raw() {
  local model="$1"
  shift
  local session=""
  if [[ "${1:-}" == session=* ]]; then
    session="${1#session=}"
    shift
  fi

  local body
  body=$(build_body "$model" "False" "$@")

  local headers=(-H "Content-Type: application/json")
  [ -n "$session" ] && headers+=(-H "X-Session-Id: $session")

  curl -s --max-time "$TIMEOUT" "${headers[@]}" -d "$body" "$GATEWAY/v1/chat/completions" 2>/dev/null
}

# Streaming chat request — returns assembled content (with retry)
chat_stream() {
  local model="$1"
  shift

  local body
  body=$(build_body "$model" "True" "$@")

  local attempt=0
  while [ $attempt -le $MAX_CHAT_RETRIES ]; do
    local response
    response=$(curl -s --max-time "$TIMEOUT" -H "Content-Type: application/json" -d "$body" "$GATEWAY/v1/chat/completions" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
      echo "ERROR: curl failed (exit $rc): $response"
      return 1
    fi

    local content
    content=$(echo "$response" | extract_sse_content 2>&1)
    local extract_rc=$?

    if [ $extract_rc -eq 0 ] && [[ "$content" != ERROR:* ]] && [ -n "$content" ]; then
      echo "$content"
      return 0
    fi

    if [ $attempt -lt $MAX_CHAT_RETRIES ]; then
      ((attempt++))
      local delay=$((attempt * 5))
      echo -e "    ${Y}…${N} Transient error, retry $attempt/$MAX_CHAT_RETRIES in ${delay}s..." >&2
      sleep "$delay"
    else
      echo "$content"
      return 1
    fi
  done
}

# ============================================================
# Global tests
# ============================================================

section "Gateway Infrastructure"

# Health endpoint
echo -e "  ${B}Health endpoint${N}"
HEALTH=$(curl -sf --max-time 10 "$GATEWAY/health" 2>/dev/null) && {
  echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null \
    && pass "GET /health returns status=ok" \
    || fail "GET /health bad response" "$HEALTH"
} || fail "GET /health not responding" "Is the gateway running at $GATEWAY?"

# Models endpoint
echo -e "  ${B}Models endpoint${N}"
MODELS=$(curl -sf --max-time 10 "$GATEWAY/v1/models" 2>/dev/null) && {
  MODEL_COUNT=$(echo "$MODELS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)
  [ "$MODEL_COUNT" -gt 0 ] 2>/dev/null \
    && pass "GET /v1/models returns $MODEL_COUNT models" \
    || fail "GET /v1/models returned 0 models"
} || fail "GET /v1/models not responding"

# Detect available backends
AVAILABLE_BACKENDS=$(echo "$MODELS" | python3 -c "
import json, sys
models = json.load(sys.stdin).get('data', [])
backends = sorted(set(m['id'].split('/')[0] for m in models))
print(' '.join(backends))
" 2>/dev/null)

# Allow override via BACKENDS env var
if [ -n "${BACKENDS:-}" ]; then
  AVAILABLE_BACKENDS="$BACKENDS"
fi

echo -e "  ${B}Detected backends:${N} $AVAILABLE_BACKENDS"

# Error handling
echo -e "  ${B}Error handling${N}"
ERR_RESP=$(curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
  -d '{"model":"nonexistent/model","messages":[{"role":"user","content":"hi"}]}' \
  "$GATEWAY/v1/chat/completions" 2>&1) || true
if echo "$ERR_RESP" | grep -q '"error"' 2>/dev/null; then
  pass "Invalid model returns error response"
else
  fail "Invalid model did not return error" "$ERR_RESP"
fi

ERR_RESP2=$(curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
  -d '{"model":"claude-code/opus"}' \
  "$GATEWAY/v1/chat/completions" 2>&1) || true
if echo "$ERR_RESP2" | grep -q '"error"' 2>/dev/null; then
  pass "Missing messages returns error response"
else
  fail "Missing messages did not return error" "$ERR_RESP2"
fi


# ============================================================
# Per-backend tests
# ============================================================

get_default_model() {
  local backend="$1"
  echo "$MODELS" | python3 -c "
import json, sys
models = json.load(sys.stdin).get('data', [])
for m in models:
    if m['id'].startswith('$backend/'):
        print(m['id'])
        break
" 2>/dev/null
}

run_backend_tests() {
  local backend="$1"
  local model
  model=$(get_default_model "$backend")

  if [ -z "$model" ]; then
    echo -e "  ${Y}No model found for $backend, skipping${N}"
    return
  fi

  local backend_upper
  backend_upper=$(echo "$backend" | tr '[:lower:]' '[:upper:]' | tr '-' ' ')

  section "Backend: $backend_upper ($model)"

  # ----------------------------------------------------------
  # Test 1: Basic chat (non-streaming)
  # ----------------------------------------------------------
  echo -e "  ${B}1. Basic chat (non-streaming)${N}"
  info "Sending: \"What is 2+2? Reply with just the number.\""

  local resp
  resp=$(chat "$model" "user:What is 2+2? Reply with just the number.")
  local rc=$?

  if [ $rc -ne 0 ] || [[ "$resp" == ERROR:* ]]; then
    fail "Basic chat failed" "$resp"
  elif contains "$resp" "4"; then
    pass "Got correct response containing '4'"
  else
    if [ -n "$resp" ]; then
      pass "Got non-empty response (${#resp} chars)"
    else
      fail "Empty response"
    fi
  fi

  # ----------------------------------------------------------
  # Test 2: Streaming
  # ----------------------------------------------------------
  echo -e "  ${B}2. Streaming (SSE)${N}"
  info "Sending: \"Say hello in exactly 3 words.\""

  local stream_resp
  stream_resp=$(chat_stream "$model" "user:Say hello in exactly 3 words.")
  rc=$?

  if [ $rc -ne 0 ] || [[ "$stream_resp" == ERROR:* ]]; then
    fail "Streaming chat failed" "$stream_resp"
  elif [ -n "$stream_resp" ]; then
    pass "Got streamed response (${#stream_resp} chars)"
  else
    fail "Empty streaming response"
  fi

  # ----------------------------------------------------------
  # Test 3: Session memory (multi-turn)
  # ----------------------------------------------------------
  echo -e "  ${B}3. Session memory (multi-turn)${N}"
  local sid
  sid=$(new_session)
  info "Session: $sid"

  # Turn 1: establish facts
  info "Turn 1: \"Remember this: my name is Ziggy and my favorite color is purple.\""
  local turn1_raw
  turn1_raw=$(chat_raw "$model" "session=$sid" \
    "user:Remember this: my name is Ziggy and my favorite color is purple. Confirm you understood.")
  local turn1
  turn1=$(echo "$turn1_raw" | extract_content)

  if [[ "$turn1" == ERROR:* ]]; then
    fail "Session turn 1 failed" "$turn1"
  else
    pass "Turn 1: got acknowledgment (${#turn1} chars)"

    # Brief pause to let session persist
    sleep 2

    # Turn 2: recall facts
    info "Turn 2: \"What is my name and favorite color?\""
    local turn2
    turn2=$(chat "$model" "session=$sid" \
      "user:What is my name and what is my favorite color? Be concise.")
    rc=$?

    if [ $rc -ne 0 ] || [[ "$turn2" == ERROR:* ]]; then
      fail "Session turn 2 failed" "$turn2"
    else
      local memory_ok=0
      if contains "$turn2" "Ziggy"; then
        ((memory_ok++))
      fi
      if contains "$turn2" "purple"; then
        ((memory_ok++))
      fi

      if [ "$memory_ok" -eq 2 ]; then
        pass "Recalled both facts (name=Ziggy, color=purple)"
      elif [ "$memory_ok" -eq 1 ]; then
        fail "Recalled only 1 of 2 facts" "Response: $(echo "$turn2" | head -c 200)"
      else
        fail "Did not recall any facts" "Response: $(echo "$turn2" | head -c 200)"
      fi
    fi
  fi

  # ----------------------------------------------------------
  # Test 4: Tool use (command execution)
  # ----------------------------------------------------------
  echo -e "  ${B}4. Tool use (command execution)${N}"
  info "Sending: \"Run the command 'cat /etc/hostname' and tell me what it outputs.\""

  local tool_resp
  tool_resp=$(chat "$model" \
    "user:Run the command 'cat /etc/hostname' and tell me exactly what it outputs. Just the output, nothing else.")
  rc=$?

  local actual_hostname
  actual_hostname=$(cat /etc/hostname 2>/dev/null || hostname)

  if [ $rc -ne 0 ] || [[ "$tool_resp" == ERROR:* ]]; then
    fail "Tool use request failed" "$tool_resp"
  elif contains "$tool_resp" "$actual_hostname"; then
    pass "Correctly read hostname ($actual_hostname) via tool execution"
  else
    if [ -n "$tool_resp" ]; then
      fail "Response doesn't contain hostname '$actual_hostname'" "Response: $(echo "$tool_resp" | head -c 200)"
    else
      fail "Empty response to tool use request"
    fi
  fi

  # ----------------------------------------------------------
  # Test 5: System prompt
  # Use a fresh session ID to ensure system prompt is sent
  # (stale sessions use --resume which skips system prompt)
  # ----------------------------------------------------------
  echo -e "  ${B}5. System prompt adherence${N}"
  info "System: \"Always respond in ALL CAPS.\" User: \"What color is the sky?\""

  local sys_sid
  sys_sid=$(new_session)
  local sys_resp
  sys_resp=$(chat "$model" "session=$sys_sid" \
    "developer:You must respond in ALL UPPERCASE LETTERS only. Every single letter must be capitalized." \
    "user:What color is the sky?")
  rc=$?

  if [ $rc -ne 0 ] || [[ "$sys_resp" == ERROR:* ]]; then
    fail "System prompt request failed" "$sys_resp"
  else
    local total_letters upper_letters pct
    total_letters=$(echo "$sys_resp" | tr -cd '[:alpha:]' | wc -c)
    upper_letters=$(echo "$sys_resp" | tr -cd '[:upper:]' | wc -c)

    if [ "$total_letters" -gt 0 ]; then
      pct=$(( upper_letters * 100 / total_letters ))
      if [ "$pct" -ge 80 ]; then
        pass "Response is ${pct}% uppercase (system prompt followed)"
      else
        fail "Response is only ${pct}% uppercase (expected ≥80%)" "Response: $(echo "$sys_resp" | head -c 200)"
      fi
    else
      fail "No alphabetic characters in response" "$sys_resp"
    fi
  fi

  # ----------------------------------------------------------
  # Test 6: Response format (OpenAI compliance)
  # ----------------------------------------------------------
  echo -e "  ${B}6. Response format (OpenAI compliance)${N}"
  info "Validating JSON structure matches OpenAI chat completion format"

  local fmt_raw
  fmt_raw=$(chat_raw "$model" "user:Say OK.")

  if [ -z "$fmt_raw" ]; then
    fail "No response received"
  else
    local fmt_result
    fmt_result=$(echo "$fmt_raw" | validate_response_format 2>&1)

    if [[ "$fmt_result" == "OK" ]]; then
      pass "Response matches OpenAI chat.completion format"
    elif [[ "$fmt_result" == ERROR* ]] || [[ "$fmt_result" == ERRORS* ]]; then
      fail "Format validation failed" "$fmt_result"
    else
      fail "Format validation unexpected result" "$fmt_result"
    fi
  fi

  echo ""
}


# ============================================================
# Run tests for each backend
# ============================================================

for backend in $AVAILABLE_BACKENDS; do
  run_backend_tests "$backend"
done


# ============================================================
# Summary
# ============================================================

section "Results"

TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${G}Passed:${N}  $PASS"
echo -e "  ${R}Failed:${N}  $FAIL"
[ "$SKIP" -gt 0 ] && echo -e "  ${Y}Skipped:${N} $SKIP"
echo -e "  ${B}Total:${N}   $TOTAL"

if [ "$FAIL" -gt 0 ]; then
  echo -e "\n  ${R}${B}Failures:${N}"
  echo -e "$ERRORS"
  exit 1
else
  echo -e "\n  ${G}${B}All tests passed!${N}"
  exit 0
fi
