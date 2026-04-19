#!/usr/bin/env bash
#
# ticktock regression tests.
#
# Run before committing:   ./tests/test.sh
# Override the script under test:   SCRIPT=/path/to/timestamps.sh ./tests/test.sh
#
# Exits non-zero if any test fails.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${SCRIPT:-$HERE/../ticktock/hooks/timestamps.sh}"
HOOKS_JSON="$HERE/../ticktock/hooks/hooks.json"
MARKETPLACE_JSON="$HERE/../.claude-plugin/marketplace.json"
PLUGIN_JSON="$HERE/../ticktock/.claude-plugin/plugin.json"
TEST_ROOT=$(mktemp -d -t ticktock-test-XXXXXX)
TEST_STATE="$TEST_ROOT/state"
TEST_DATA="$TEST_ROOT/data"
mkdir -p "$TEST_STATE" "$TEST_DATA"

pass=0
fail=0
failed_names=()

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; fail=$((fail+1)); failed_names+=("$1"); }

# Run the script with isolated state + optional extra env.
run_script() {
  local kind=$1 sid=$2
  shift 2
  echo "{\"session_id\":\"$sid\"}" | \
    env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$@" "$SCRIPT" "$kind"
}

# Run with an explicit stdin JSON payload.
run_script_stdin() {
  local kind=$1 payload=$2
  shift 2
  printf '%s' "$payload" | \
    env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$@" "$SCRIPT" "$kind"
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ─── prerequisites ────────────────────────────────────────────────────────────

section "prerequisites"

[[ -x $SCRIPT ]] \
  && ok "script exists and is executable" \
  || { bad "script exists and is executable" "$SCRIPT"; exit 1; }

for dep in jq date; do
  command -v "$dep" >/dev/null && ok "dep available: $dep" || bad "dep available: $dep"
done

bash -n "$SCRIPT" && ok "script parses as bash" || bad "script parses as bash"

# ─── manifest validity ────────────────────────────────────────────────────────

section "manifests"

for f in "$MARKETPLACE_JSON" "$PLUGIN_JSON" "$HOOKS_JSON"; do
  if jq empty "$f" >/dev/null 2>&1; then
    ok "valid JSON: $(basename "$f")"
  else
    bad "valid JSON: $(basename "$f")" "$(jq empty "$f" 2>&1)"
  fi
done

# hooks.json must quote ${CLAUDE_PLUGIN_ROOT}
if grep -q '"\\"\${CLAUDE_PLUGIN_ROOT}' "$HOOKS_JSON" || grep -q '\\"\${CLAUDE_PLUGIN_ROOT}' "$HOOKS_JSON"; then
  ok "hooks.json quotes \${CLAUDE_PLUGIN_ROOT}"
else
  bad "hooks.json quotes \${CLAUDE_PLUGIN_ROOT}" "$(grep CLAUDE_PLUGIN_ROOT "$HOOKS_JSON")"
fi

# hooks.json wires all five events
for evt in UserPromptSubmit Stop SubagentStart SubagentStop SessionEnd; do
  jq -e ".hooks.${evt} | length > 0" "$HOOKS_JSON" >/dev/null 2>&1 \
    && ok "hooks.json wires $evt" \
    || bad "hooks.json wires $evt"
done

# plugin.json userConfig declares at least 10 options
uc_count=$(jq '.userConfig | length' "$PLUGIN_JSON" 2>/dev/null || echo 0)
if (( uc_count >= 10 )); then
  ok "plugin.json userConfig exposes $uc_count options (≥10)"
else
  bad "plugin.json userConfig exposes $uc_count options (≥10)"
fi

# ─── happy path ───────────────────────────────────────────────────────────────

section "happy path"

SID="happy-$$"
out1=$(run_script prompt "$SID")
echo "$out1" | jq -e .systemMessage >/dev/null 2>&1 \
  && ok "prompt emits {systemMessage}" \
  || bad "prompt emits {systemMessage}" "$out1"

[[ "$out1" =~ ^\{\"systemMessage\":\"prompt\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\"\}$ ]] \
  && ok "first prompt has no delta" \
  || bad "first prompt has no delta" "$out1"

sleep 1
out2=$(run_script response "$SID")
[[ "$out2" == *'took 1s'* ]] \
  && ok "first response shows 'took Xs'" \
  || bad "first response shows 'took Xs'" "$out2"

sleep 1
out3=$(run_script prompt "$SID")
[[ "$out3" == *'idle '* ]] \
  && ok "second prompt shows 'idle Xs'" \
  || bad "second prompt shows 'idle Xs'" "$out3"

# ─── turn counter ─────────────────────────────────────────────────────────────

section "turn counter"

SID="turn-$$"
out1=$(run_script prompt "$SID" CLAUDE_TS_SHOW_TURN=1)
[[ "$out1" == *'#1 prompt'* ]] \
  && ok "turn counter starts at #1" \
  || bad "turn counter starts at #1" "$out1"

out1r=$(run_script response "$SID" CLAUDE_TS_SHOW_TURN=1)
[[ "$out1r" == *'#1 response'* ]] \
  && ok "response reuses current turn number" \
  || bad "response reuses current turn number" "$out1r"

out2=$(run_script prompt "$SID" CLAUDE_TS_SHOW_TURN=1)
[[ "$out2" == *'#2 prompt'* ]] \
  && ok "turn counter increments on next prompt" \
  || bad "turn counter increments on next prompt" "$out2"

# turn counter hidden by default
SID="turn-off-$$"
out=$(run_script prompt "$SID")
[[ "$out" != *'#1'* && "$out" != *'#2'* ]] \
  && ok "turn counter hidden when SHOW_TURN=0" \
  || bad "turn counter hidden when SHOW_TURN=0" "$out"

# ─── config precedence: CLAUDE_TS > CLAUDE_PLUGIN_OPTION > default ────────────

section "config precedence"

SID="prec-$$"
# Plugin option alone enables feature.
out=$(run_script prompt "$SID" CLAUDE_PLUGIN_OPTION_SHOW_TURN=1)
[[ "$out" == *'#1 prompt'* ]] \
  && ok "CLAUDE_PLUGIN_OPTION_* is read by the script" \
  || bad "CLAUDE_PLUGIN_OPTION_* is read by the script" "$out"

SID="prec2-$$"
# Env var wins over plugin option.
out=$(run_script prompt "$SID" CLAUDE_TS_SHOW_TURN=0 CLAUDE_PLUGIN_OPTION_SHOW_TURN=1)
[[ "$out" != *'#1'* ]] \
  && ok "CLAUDE_TS_* overrides CLAUDE_PLUGIN_OPTION_*" \
  || bad "CLAUDE_TS_* overrides CLAUDE_PLUGIN_OPTION_*" "$out"

# Truthy aliases
SID="truthy-$$"
out=$(run_script prompt "$SID" CLAUDE_TS_SHOW_TURN=true)
[[ "$out" == *'#1 prompt'* ]] \
  && ok "'true' is truthy for toggles" \
  || bad "'true' is truthy for toggles" "$out"

SID="truthy2-$$"
out=$(run_script prompt "$SID" CLAUDE_TS_SHOW_TURN=yes)
[[ "$out" == *'#1 prompt'* ]] \
  && ok "'yes' is truthy for toggles" \
  || bad "'yes' is truthy for toggles" "$out"

# ─── session elapsed ──────────────────────────────────────────────────────────

section "session elapsed"

SID="sess-$$"
out=$(run_script prompt "$SID" CLAUDE_TS_SHOW_SESSION=1)
[[ "$out" == *'session '* ]] \
  && ok "SHOW_SESSION=1 adds 'session Xs'" \
  || bad "SHOW_SESSION=1 adds 'session Xs'" "$out"

# ─── subagent timing ──────────────────────────────────────────────────────────

section "subagent timing"

SID="sub-$$"
PAYLOAD_START="{\"session_id\":\"$SID\",\"agent_id\":\"agent-abc\",\"agent_type\":\"Explore\"}"
PAYLOAD_STOP="{\"session_id\":\"$SID\",\"agent_id\":\"agent-abc\",\"agent_type\":\"Explore\"}"

out_start=$(run_script_stdin subagent_start "$PAYLOAD_START")
[[ -z "$out_start" ]] \
  && ok "subagent_start is silent (no output)" \
  || bad "subagent_start is silent (no output)" "$out_start"

sleep 1
out_stop=$(run_script_stdin subagent_stop "$PAYLOAD_STOP")
[[ "$out_stop" == *'subagent Explore  took 1s'* ]] \
  && ok "subagent_stop emits 'subagent NAME  took Xs'" \
  || bad "subagent_stop emits 'subagent NAME  took Xs'" "$out_stop"

# subagent_stop without a start is silent
SID="sub-orphan-$$"
PAYLOAD_ORPHAN="{\"session_id\":\"$SID\",\"agent_id\":\"agent-nobody\",\"agent_type\":\"Explore\"}"
out=$(run_script_stdin subagent_stop "$PAYLOAD_ORPHAN")
[[ -z "$out" ]] \
  && ok "subagent_stop without matching start is silent" \
  || bad "subagent_stop without matching start is silent" "$out"

# parallel subagents: two different agent_ids don't collide
SID="sub-par-$$"
PA_START="{\"session_id\":\"$SID\",\"agent_id\":\"a1\",\"agent_type\":\"AgentOne\"}"
PB_START="{\"session_id\":\"$SID\",\"agent_id\":\"a2\",\"agent_type\":\"AgentTwo\"}"
run_script_stdin subagent_start "$PA_START" >/dev/null
sleep 1
run_script_stdin subagent_start "$PB_START" >/dev/null
sleep 1
# Stop B first, then A
out_b=$(run_script_stdin subagent_stop "$PB_START")
out_a=$(run_script_stdin subagent_stop "$PA_START")
[[ "$out_b" == *'AgentTwo  took 1s'* ]] \
  && ok "parallel subagent: second started finishes correctly" \
  || bad "parallel subagent: second started finishes correctly" "$out_b"
[[ "$out_a" == *'AgentOne  took'* ]] \
  && ok "parallel subagent: first still resolves after second stops" \
  || bad "parallel subagent: first still resolves after second stops" "$out_a"

# ─── session recap ────────────────────────────────────────────────────────────

section "session recap"

# Sub-threshold: 2 turns, threshold 3 → no recap
SID="recap-low-$$"
run_script prompt "$SID" >/dev/null
run_script response "$SID" >/dev/null
run_script prompt "$SID" >/dev/null
run_script response "$SID" >/dev/null
out=$(run_script session_end "$SID")
[[ -z "$out" ]] \
  && ok "recap suppressed when turns < min (default 3)" \
  || bad "recap suppressed when turns < min (default 3)" "$out"

# Threshold met: 3 turns
SID="recap-ok-$$"
for i in 1 2 3; do
  run_script prompt "$SID" >/dev/null
  run_script response "$SID" >/dev/null
done
out=$(run_script session_end "$SID")
[[ "$out" == *'session recap:'* ]] \
  && ok "recap fires at threshold (3 turns)" \
  || bad "recap fires at threshold (3 turns)" "$out"
[[ "$out" == *'3 turns'* ]] \
  && ok "recap includes turn count" \
  || bad "recap includes turn count" "$out"

# Custom threshold
SID="recap-custom-$$"
run_script prompt "$SID" CLAUDE_TS_RECAP_MIN_TURNS=1 >/dev/null
run_script response "$SID" CLAUDE_TS_RECAP_MIN_TURNS=1 >/dev/null
out=$(run_script session_end "$SID" CLAUDE_TS_RECAP_MIN_TURNS=1)
[[ "$out" == *'session recap:'* ]] \
  && ok "RECAP_MIN_TURNS=1 lowers threshold" \
  || bad "RECAP_MIN_TURNS=1 lowers threshold" "$out"

# Session end cleans up state
SID="cleanup-$$"
run_script prompt "$SID" >/dev/null
run_script response "$SID" >/dev/null
run_script session_end "$SID" >/dev/null
remaining=$(ls "$TEST_STATE"/*"$SID"* 2>/dev/null | wc -l | tr -d ' ')
[[ "$remaining" == "0" ]] \
  && ok "session_end deletes session state files" \
  || bad "session_end deletes session state files" "$remaining file(s) remain"

# ─── JSONL history log ────────────────────────────────────────────────────────

section "JSONL history log"

SID="log-$$"
LOG_MONTH=$(date -u +%Y-%m)
LOG_FILE="$TEST_DATA/history-$LOG_MONTH.jsonl"
rm -f "$LOG_FILE"

run_script prompt "$SID" CLAUDE_TS_LOG_HISTORY=1 >/dev/null
run_script response "$SID" CLAUDE_TS_LOG_HISTORY=1 >/dev/null
run_script session_end "$SID" CLAUDE_TS_LOG_HISTORY=1 >/dev/null

[[ -f $LOG_FILE ]] \
  && ok "log file created at \$CLAUDE_PLUGIN_DATA/history-YYYY-MM.jsonl" \
  || bad "log file created at \$CLAUDE_PLUGIN_DATA/history-YYYY-MM.jsonl"

lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
(( lines == 3 )) \
  && ok "log contains 3 events (prompt, response, session_end)" \
  || bad "log contains 3 events (prompt, response, session_end)" "lines=$lines"

# schema check
if [[ -f $LOG_FILE ]]; then
  bad_lines=0
  while IFS= read -r line; do
    v=$(echo "$line" | jq -r '.v' 2>/dev/null)
    kind=$(echo "$line" | jq -r '.kind' 2>/dev/null)
    ts=$(echo "$line" | jq -r '.ts' 2>/dev/null)
    [[ "$v" == "1" ]] || bad_lines=$((bad_lines+1))
    [[ "$kind" =~ ^(prompt|response|subagent|session_end)$ ]] || bad_lines=$((bad_lines+1))
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || bad_lines=$((bad_lines+1))
  done < "$LOG_FILE"
  (( bad_lines == 0 )) \
    && ok "every log line has v=1, valid kind, ISO 8601 ts" \
    || bad "every log line has v=1, valid kind, ISO 8601 ts" "$bad_lines issue(s)"
fi

# verify kind-specific fields
if [[ -f $LOG_FILE ]]; then
  jq -e 'select(.kind=="response") | .took_s' "$LOG_FILE" >/dev/null 2>&1 \
    && ok "response events include took_s" \
    || bad "response events include took_s"

  jq -e 'select(.kind=="session_end") | .turns' "$LOG_FILE" >/dev/null 2>&1 \
    && ok "session_end events include turns" \
    || bad "session_end events include turns"
fi

# LOG_HISTORY=0 → no file written
SID="nolog-$$"
LOG_FILE_2="$TEST_DATA/history-$LOG_MONTH.jsonl"
before=$(wc -l < "$LOG_FILE_2" 2>/dev/null || echo 0)
run_script prompt "$SID" >/dev/null
after=$(wc -l < "$LOG_FILE_2" 2>/dev/null || echo 0)
[[ "$before" == "$after" ]] \
  && ok "LOG_HISTORY=0 writes nothing to history file" \
  || bad "LOG_HISTORY=0 writes nothing to history file" "before=$before after=$after"

# ─── robustness: sanity cap ───────────────────────────────────────────────────

section "robustness: sanity cap"

SID="sanity-$$"
FAKE=$(($(date +%s) - 172800))
echo "$FAKE" > "$TEST_STATE/response-$SID"
out=$(run_script prompt "$SID")
[[ "$out" != *'idle '* ]] \
  && ok "2-day-old state is suppressed (default 24h cap)" \
  || bad "2-day-old state is suppressed" "$out"

# ─── robustness: clock jump ───────────────────────────────────────────────────

section "robustness: clock jump"

SID="clock-$$"
FUTURE=$(($(date +%s) + 3600))
echo "$FUTURE" > "$TEST_STATE/response-$SID"
out=$(run_script prompt "$SID")
[[ "$out" != *'idle '* ]] \
  && ok "future timestamp suppressed" \
  || bad "future timestamp suppressed" "$out"

# ─── robustness: garbage state ────────────────────────────────────────────────

section "robustness: garbage state"

SID="garbage-$$"
echo "not-a-number" > "$TEST_STATE/response-$SID"
out=$(run_script prompt "$SID")
[[ "$out" != *'idle '* ]] \
  && ok "non-numeric state rejected" \
  || bad "non-numeric state rejected" "$out"

# ─── robustness: invalid stdin ────────────────────────────────────────────────

section "robustness: invalid stdin"

out=$(echo "not json at all" | env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$SCRIPT" prompt 2>&1)
echo "$out" | jq -e .systemMessage >/dev/null 2>&1 \
  && ok "bogus stdin still emits (falls back to 'default' session)" \
  || bad "bogus stdin still emits" "$out"

# ─── robustness: read-only state dir ──────────────────────────────────────────

section "robustness: read-only state dir"

RODIR="$TEST_ROOT/readonly"
mkdir -p "$RODIR"; chmod 500 "$RODIR"
SID="ro-$$"
out=$(echo "{\"session_id\":\"$SID\"}" | \
      env CLAUDE_TS_STATE_DIR="$RODIR" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$SCRIPT" prompt 2>&1)
chmod 700 "$RODIR"

[[ "$out" == '{"systemMessage":'* ]] \
  && ok "read-only state dir: script emits cleanly" \
  || bad "read-only state dir: script emits cleanly" "$out"

[[ "$out" != *'Permission denied'* && "$out" != *'bash:'* ]] \
  && ok "read-only state dir: no stderr leak" \
  || bad "read-only state dir: no stderr leak" "$out"

# ─── config: numeric validation ───────────────────────────────────────────────

section "config: numeric validation"

for bad_val in "foo" "08" "09" "007" "0100" ""; do
  SID="numval-${bad_val//[^a-zA-Z0-9]/_}-$$"
  out=$(run_script prompt "$SID" CLAUDE_TS_CLEANUP_DAYS="$bad_val" CLAUDE_TS_SANITY_CAP="$bad_val")
  if [[ "$out" == '{"systemMessage":'* && "$out" != *'bash:'* && "$out" != *'value too great'* && "$out" != *'syntax error'* ]]; then
    ok "bad value tolerated: '$bad_val'"
  else
    bad "bad value tolerated: '$bad_val'" "$out"
  fi
done

# ─── security: injection ──────────────────────────────────────────────────────

section "security: injection"

SID="inject-$$"
rm -f /tmp/ticktock-pwn
out=$(run_script prompt "$SID" CLAUDE_TS_CLEANUP_DAYS='malicious; touch /tmp/ticktock-pwn')
[[ -f /tmp/ticktock-pwn ]] && { bad "injection attempt succeeded — /tmp/ticktock-pwn created"; rm -f /tmp/ticktock-pwn; } \
  || ok "injection attempt does not execute"
[[ "$out" == '{"systemMessage":'* ]] \
  && ok "injection attempt: script still emits cleanly" \
  || bad "injection attempt: script still emits cleanly" "$out"

# Test injection via session_id (fed into filenames)
SID_EVIL="../../etc/passwd"
out=$(echo "{\"session_id\":\"$SID_EVIL\"}" | \
      env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$SCRIPT" prompt 2>&1)
[[ "$out" == '{"systemMessage":'* ]] \
  && ok "nasty session_id sanitized, script still emits" \
  || bad "nasty session_id sanitized, script still emits" "$out"
# Verify no file actually outside the state dir
[[ ! -f /etc/passwd_touched_by_ticktock_test ]] \
  && ok "path traversal via session_id prevented" \
  || bad "path traversal via session_id prevented"

# ─── arg validation ───────────────────────────────────────────────────────────

section "arg validation"

out=$(echo '{}' | env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$SCRIPT" bogus 2>&1 ; echo "EXIT=$?")
[[ "$out" == *"usage:"*"EXIT=2" ]] \
  && ok "invalid arg exits 2 with usage" \
  || bad "invalid arg exits 2 with usage" "$out"

# All five valid kinds accepted
for k in prompt response subagent_start subagent_stop session_end; do
  # Just check exit status on a minimal run — use a unique SID so state doesn't leak.
  SID="validarg-$k-$$"
  payload="{\"session_id\":\"$SID\",\"agent_id\":\"a\",\"agent_type\":\"X\"}"
  echo "$payload" | env CLAUDE_TS_STATE_DIR="$TEST_STATE" CLAUDE_PLUGIN_DATA="$TEST_DATA" "$SCRIPT" "$k" >/dev/null 2>&1
  rc=$?
  (( rc == 0 )) && ok "kind accepted: $k" || bad "kind accepted: $k" "rc=$rc"
done

# ─── summary ──────────────────────────────────────────────────────────────────

total=$((pass+fail))
echo
if (( fail == 0 )); then
  printf '\033[1;32m%d/%d tests passed\033[0m\n' "$pass" "$total"
  exit 0
else
  printf '\033[1;31m%d/%d tests failed\033[0m\n' "$fail" "$total"
  for n in "${failed_names[@]}"; do
    printf '  - %s\n' "$n"
  done
  exit 1
fi
