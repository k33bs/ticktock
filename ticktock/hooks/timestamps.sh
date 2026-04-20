#!/usr/bin/env bash
#
# ticktock — inline timestamps and per-turn deltas for Claude Code transcripts.
#
# Dispatched by five hook events with a matching kind arg:
#   prompt          <- UserPromptSubmit
#   response        <- Stop
#   subagent_start  <- SubagentStart (silent; records start time)
#   subagent_stop   <- SubagentStop  (emits "subagent NAME took Xs")
#   session_end     <- SessionEnd    (emits "session recap: ..." if turns ≥ threshold)
#
# Stdin: Claude Code hook JSON (session_id, agent_id, etc.).
#
# Configuration resolves in this order (highest wins):
#   1. CLAUDE_TICKTOCK_<NAME> environment variable (per-shell override)
#   2. CLAUDE_PLUGIN_OPTION_<NAME> (set via /plugin UI, declared in plugin.json)
#   3. Built-in default (below)
#
# See plugin README for the full option reference.

set -u

# ─── config: env > plugin option > default ────────────────────────────────────

readonly STATE_DIR="${CLAUDE_TICKTOCK_STATE_DIR:-${CLAUDE_PLUGIN_OPTION_STATE_DIR:-$HOME/.claude/timestamps}}"
readonly TIME_FORMAT="${CLAUDE_TICKTOCK_TIME_FORMAT:-${CLAUDE_PLUGIN_OPTION_TIME_FORMAT:-%H:%M:%S}}"
readonly PROMPT_LABEL="${CLAUDE_TICKTOCK_PROMPT_LABEL:-${CLAUDE_PLUGIN_OPTION_PROMPT_LABEL:-prompt}}"
readonly RESPONSE_LABEL="${CLAUDE_TICKTOCK_RESPONSE_LABEL:-${CLAUDE_PLUGIN_OPTION_RESPONSE_LABEL:-response}}"
readonly IDLE_LABEL="${CLAUDE_TICKTOCK_IDLE_LABEL:-${CLAUDE_PLUGIN_OPTION_IDLE_LABEL:-idle}}"
readonly TOOK_LABEL="${CLAUDE_TICKTOCK_TOOK_LABEL:-${CLAUDE_PLUGIN_OPTION_TOOK_LABEL:-took}}"
readonly SESSION_LABEL="${CLAUDE_TICKTOCK_SESSION_LABEL:-${CLAUDE_PLUGIN_OPTION_SESSION_LABEL:-session}}"
readonly SUBAGENT_LABEL="${CLAUDE_TICKTOCK_SUBAGENT_LABEL:-${CLAUDE_PLUGIN_OPTION_SUBAGENT_LABEL:-subagent}}"
readonly RECAP_LABEL="${CLAUDE_TICKTOCK_RECAP_LABEL:-${CLAUDE_PLUGIN_OPTION_RECAP_LABEL:-session recap:}}"

is_on() { [[ $1 == "1" || $1 == "true" || $1 == "yes" || $1 == "on" ]]; }

_raw_show_deltas="${CLAUDE_TICKTOCK_SHOW_DELTAS:-${CLAUDE_PLUGIN_OPTION_SHOW_DELTAS:-1}}"
_raw_show_session="${CLAUDE_TICKTOCK_SHOW_SESSION:-${CLAUDE_PLUGIN_OPTION_SHOW_SESSION:-1}}"
_raw_show_turn="${CLAUDE_TICKTOCK_SHOW_TURN:-${CLAUDE_PLUGIN_OPTION_SHOW_TURN:-1}}"
_raw_log_history="${CLAUDE_TICKTOCK_LOG_HISTORY:-${CLAUDE_PLUGIN_OPTION_LOG_HISTORY:-0}}"

SHOW_DELTAS=0;  is_on "$_raw_show_deltas"  && SHOW_DELTAS=1;  readonly SHOW_DELTAS
SHOW_SESSION=0; is_on "$_raw_show_session" && SHOW_SESSION=1; readonly SHOW_SESSION
SHOW_TURN=0;    is_on "$_raw_show_turn"    && SHOW_TURN=1;    readonly SHOW_TURN
LOG_HISTORY=0;  is_on "$_raw_log_history"  && LOG_HISTORY=1;  readonly LOG_HISTORY

# Numeric knobs: validate regex + force base 10 so values like "08" don't blow up arithmetic.
_num() {  # $1=raw $2=default ; echoes sanitized value
  local v=$1 d=$2
  [[ $v =~ ^[0-9]+$ ]] || v=$d
  printf '%s' "$((10#$v))"
}

readonly SANITY_CAP=$(_num  "${CLAUDE_TICKTOCK_SANITY_CAP:-${CLAUDE_PLUGIN_OPTION_SANITY_CAP:-86400}}"          86400)
readonly CLEANUP_DAYS=$(_num "${CLAUDE_TICKTOCK_CLEANUP_DAYS:-${CLAUDE_PLUGIN_OPTION_CLEANUP_DAYS:-30}}"         30)
readonly RECAP_MIN_TURNS=$(_num "${CLAUDE_TICKTOCK_RECAP_MIN_TURNS:-${CLAUDE_PLUGIN_OPTION_RECAP_MIN_TURNS:-3}}" 3)
readonly LOG_MONTHS=$(_num "${CLAUDE_TICKTOCK_LOG_MONTHS:-${CLAUDE_PLUGIN_OPTION_LOG_MONTHS:-12}}"               12)

# History log lives in CLAUDE_PLUGIN_DATA when running as a plugin (survives updates),
# or falls back to STATE_DIR when running as a standalone script.
readonly LOG_DIR="${CLAUDE_PLUGIN_DATA:-$STATE_DIR}"

# ─── args ─────────────────────────────────────────────────────────────────────

kind=${1:-}
case "$kind" in
  prompt|response|subagent_start|subagent_stop|session_end) ;;
  *) echo "usage: $0 {prompt|response|subagent_start|subagent_stop|session_end}" >&2; exit 2 ;;
esac

# ─── dependencies ─────────────────────────────────────────────────────────────

for bin in jq date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ticktock: missing dependency: $bin" >&2
    exit 127
  fi
done

# ─── helpers ──────────────────────────────────────────────────────────────────

format_delta() {
  local t=$1
  if   (( t < 60 ));   then printf '%ds' "$t"
  elif (( t < 3600 )); then printf '%dm%02ds' "$((t/60))" "$((t%60))"
  else                      printf '%dh%02dm' "$((t/3600))" "$(((t%3600)/60))"
  fi
}

read_epoch() {
  local file=$1 value
  [[ -f $file ]] || return 1
  value=$(cat "$file" 2>/dev/null) || return 1
  [[ $value =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

sanitize_id() {
  printf '%s' "$1" | tr -c '[:alnum:]._-' '_'
}

safe_delta() {
  local diff=$(( now_epoch - $1 ))
  (( diff < 0 || diff > SANITY_CAP )) && return
  format_delta "$diff"
}

iso_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Emit a JSON line to history-YYYY-MM.jsonl.
# Args: <kind> [key=value ...]
# Values matching ^-?[0-9]+$ become JSON numbers; everything else becomes strings.
log_event() {
  (( LOG_HISTORY == 1 )) || return 0
  local evt_kind=$1; shift
  local ts file jq_expr k v
  ts=$(iso_utc_now)
  file="$LOG_DIR/history-$(date -u +%Y-%m).jsonl"
  { mkdir -p "$LOG_DIR"; } 2>/dev/null || true
  local -a jq_args=(
    -cn
    --argjson v 1
    --arg ts "$ts"
    --arg session "$session_id"
    --arg kind "$evt_kind"
  )
  jq_expr='{v:$v,ts:$ts,session:$session,kind:$kind}'
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    if [[ $v =~ ^-?[0-9]+$ ]]; then
      jq_args+=( --argjson "$k" "$v" )
    else
      jq_args+=( --arg "$k" "$v" )
    fi
    jq_expr="$jq_expr + {$k:\$$k}"
  done
  local line
  line=$(jq "${jq_args[@]}" "$jq_expr" 2>/dev/null) || return 0
  { { printf '%s\n' "$line" >> "$file"; } 2>/dev/null; } || true
}

# Stats file: key=value lines tracking session-level tallies.
stats_first_ts=0
stats_turns=0
stats_total_response_s=0
stats_longest_response_s=0

read_stats() {
  stats_first_ts=0
  stats_turns=0
  stats_total_response_s=0
  stats_longest_response_s=0
  [[ -f $stats_file ]] || return
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      first_ts)           [[ $v =~ ^[0-9]+$ ]] && stats_first_ts=$((10#$v)) ;;
      turns)              [[ $v =~ ^[0-9]+$ ]] && stats_turns=$((10#$v)) ;;
      total_response_s)   [[ $v =~ ^[0-9]+$ ]] && stats_total_response_s=$((10#$v)) ;;
      longest_response_s) [[ $v =~ ^[0-9]+$ ]] && stats_longest_response_s=$((10#$v)) ;;
    esac
  done < "$stats_file"
}

write_stats() {
  {
    {
      printf 'first_ts=%d\n' "$stats_first_ts"
      printf 'turns=%d\n' "$stats_turns"
      printf 'total_response_s=%d\n' "$stats_total_response_s"
      printf 'longest_response_s=%d\n' "$stats_longest_response_s"
    } > "$stats_file"
  } 2>/dev/null || true
}

emit_systemmessage() {
  jq -cn --arg m "$1" '{systemMessage: $m}'
}

# ─── parse stdin (shared across handlers) ─────────────────────────────────────

stdin_json=$(cat)
raw_sid=$(printf '%s' "$stdin_json" | jq -r '.session_id // "default"' 2>/dev/null || printf 'default')
session_id=$(sanitize_id "$raw_sid")

raw_agent_id=$(printf '%s' "$stdin_json" | jq -r '.agent_id // ""' 2>/dev/null || printf '')
agent_id=$(sanitize_id "$raw_agent_id")
agent_type=$(printf '%s' "$stdin_json" | jq -r '.agent_type // "subagent"' 2>/dev/null || printf 'subagent')

{ mkdir -p "$STATE_DIR"; } 2>/dev/null || true

prompt_file="$STATE_DIR/prompt-$session_id"
response_file="$STATE_DIR/response-$session_id"
stats_file="$STATE_DIR/stats-$session_id"
subagent_file="$STATE_DIR/subagent-$session_id-$agent_id"

now_epoch=$(date +%s)
now_human=$(date "+$TIME_FORMAT")

# ─── compose helpers ──────────────────────────────────────────────────────────

session_elapsed_suffix() {  # echoes "  session Xm" or empty
  (( SHOW_SESSION == 1 )) || return
  (( stats_first_ts > 0 )) || return
  local d
  d=$(safe_delta "$stats_first_ts")
  [[ -n $d ]] || return
  printf '  %s %s' "$SESSION_LABEL" "$d"
}

turn_prefix() {  # echoes "#N " or empty, depending on SHOW_TURN and stats_turns
  (( SHOW_TURN == 1 )) || return
  (( stats_turns > 0 )) || return
  printf '#%d ' "$stats_turns"
}

# ─── handlers ─────────────────────────────────────────────────────────────────

handle_prompt() {
  read_stats
  (( stats_first_ts == 0 )) && stats_first_ts=$now_epoch
  stats_turns=$(( stats_turns + 1 ))
  write_stats

  local delta_str="" d prev idle_s=-1
  if (( SHOW_DELTAS == 1 )) && prev=$(read_epoch "$response_file"); then
    d=$(safe_delta "$prev")
    if [[ -n $d ]]; then
      delta_str="$IDLE_LABEL $d"
      idle_s=$(( now_epoch - prev ))
    fi
  fi

  { { printf '%s\n' "$now_epoch" > "$prompt_file"; } 2>/dev/null; } || true

  local msg="$(turn_prefix)$PROMPT_LABEL $now_human"
  [[ -n $delta_str ]] && msg="$msg  $delta_str"
  msg="$msg$(session_elapsed_suffix)"

  # log event
  if (( idle_s >= 0 )); then
    log_event prompt "turn=$stats_turns" "idle_s=$idle_s"
  else
    log_event prompt "turn=$stats_turns"
  fi

  emit_systemmessage "$msg"
}

handle_response() {
  read_stats

  local took_s=-1 prev
  if prev=$(read_epoch "$prompt_file"); then
    took_s=$(( now_epoch - prev ))
    (( took_s < 0 )) && took_s=-1
  fi

  # update stats (only if we have a valid took)
  if (( took_s >= 0 )); then
    stats_total_response_s=$(( stats_total_response_s + took_s ))
    (( took_s > stats_longest_response_s )) && stats_longest_response_s=$took_s
    write_stats
  fi

  { { printf '%s\n' "$now_epoch" > "$response_file"; } 2>/dev/null; } || true

  local delta_str=""
  if (( SHOW_DELTAS == 1 )) && (( took_s >= 0 )) && (( took_s <= SANITY_CAP )); then
    delta_str="$TOOK_LABEL $(format_delta "$took_s")"
  fi

  local msg="$(turn_prefix)$RESPONSE_LABEL $now_human"
  [[ -n $delta_str ]] && msg="$msg  $delta_str"
  msg="$msg$(session_elapsed_suffix)"

  if (( took_s >= 0 )); then
    log_event response "turn=$stats_turns" "took_s=$took_s"
  else
    log_event response "turn=$stats_turns"
  fi

  emit_systemmessage "$msg"
}

handle_subagent_start() {
  # Silent — just record start time. If we have no agent_id, we can't correlate later, so skip.
  [[ -n $agent_id ]] || return 0
  { { printf '%s\n' "$now_epoch" > "$subagent_file"; } 2>/dev/null; } || true
}

handle_subagent_stop() {
  read_stats

  local took_s=-1 prev
  if [[ -n $agent_id ]] && prev=$(read_epoch "$subagent_file"); then
    took_s=$(( now_epoch - prev ))
    (( took_s < 0 )) && took_s=-1
    { rm -f "$subagent_file"; } 2>/dev/null || true
  fi

  if (( took_s >= 0 )) && (( took_s <= SANITY_CAP )); then
    local msg="$SUBAGENT_LABEL $agent_type  $TOOK_LABEL $(format_delta "$took_s")"
    log_event subagent "turn=$stats_turns" "name=$agent_type" "took_s=$took_s"
    emit_systemmessage "$msg"
  fi
  # If we couldn't compute took_s (no matching start, missed hook), stay silent.
}

handle_session_end() {
  read_stats

  local elapsed_s=0
  (( stats_first_ts > 0 )) && elapsed_s=$(( now_epoch - stats_first_ts ))
  (( elapsed_s < 0 )) && elapsed_s=0

  # Always log the session_end event (if logging is on), regardless of threshold.
  log_event session_end \
    "turns=$stats_turns" \
    "elapsed_s=$elapsed_s" \
    "total_response_s=$stats_total_response_s" \
    "longest_response_s=$stats_longest_response_s"

  # Only emit a user-visible recap when there were enough turns to matter.
  if (( stats_turns >= RECAP_MIN_TURNS )); then
    local avg_s=0
    (( stats_turns > 0 )) && avg_s=$(( stats_total_response_s / stats_turns ))
    local msg="$RECAP_LABEL $(format_delta "$elapsed_s") · ${stats_turns} turns"
    msg="$msg · avg response $(format_delta "$avg_s")"
    msg="$msg · longest $(format_delta "$stats_longest_response_s")"
    emit_systemmessage "$msg"
  fi

  # Cleanup session state files (they're single-session, no point keeping them).
  { rm -f \
      "$STATE_DIR/prompt-$session_id" \
      "$STATE_DIR/response-$session_id" \
      "$STATE_DIR/stats-$session_id" \
      "$STATE_DIR/subagent-$session_id-"*; } 2>/dev/null || true
}

# ─── dispatcher ───────────────────────────────────────────────────────────────

case "$kind" in
  prompt)         handle_prompt ;;
  response)       handle_response ;;
  subagent_start) handle_subagent_start ;;
  subagent_stop)  handle_subagent_stop ;;
  session_end)    handle_session_end ;;
esac

# ─── background maintenance ───────────────────────────────────────────────────

# Prune old state files (scoped to our name prefixes so we never touch unrelated files).
if (( CLEANUP_DAYS > 0 )) && [[ -d $STATE_DIR ]]; then
  find "$STATE_DIR" -type f \
    \( -name 'prompt-*' -o -name 'response-*' -o -name 'stats-*' -o -name 'subagent-*' \) \
    -mtime "+$CLEANUP_DAYS" -delete 2>/dev/null
fi

# Prune old history files.
if (( LOG_MONTHS > 0 )) && [[ -d $LOG_DIR ]]; then
  find "$LOG_DIR" -type f -name 'history-*.jsonl' \
    -mtime "+$((LOG_MONTHS * 30))" -delete 2>/dev/null
fi
