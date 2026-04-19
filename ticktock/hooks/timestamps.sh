#!/usr/bin/env bash
#
# claude-timestamps — inline timestamps + deltas in Claude Code transcripts.
#
# Wires into two hook events and emits a single-line systemMessage per turn:
#   UserPromptSubmit  ->  "prompt HH:MM:SS  idle 3m12s"    (time since last response)
#   Stop              ->  "response HH:MM:SS  took 30s"    (response duration)
#
# Optional session-elapsed suffix ("session 12m") when CLAUDE_TS_SHOW_SESSION=1.
#
# Usage:
#   timestamp-hook.sh {prompt|response}
# Stdin:
#   Claude Code hook JSON; session_id is used to scope per-session state.
#
# Configuration (all env, all optional):
#   CLAUDE_TS_STATE_DIR       where state files live        default: $HOME/.claude/timestamps
#   CLAUDE_TS_TIME_FORMAT     strftime format                default: %H:%M:%S
#   CLAUDE_TS_PROMPT_LABEL    prompt-line prefix             default: prompt
#   CLAUDE_TS_RESPONSE_LABEL  response-line prefix           default: response
#   CLAUDE_TS_IDLE_LABEL      user-idle delta label          default: idle
#   CLAUDE_TS_TOOK_LABEL      response-duration label        default: took
#   CLAUDE_TS_SESSION_LABEL   session-elapsed label          default: session
#   CLAUDE_TS_SHOW_DELTAS     show per-event delta           default: 1
#   CLAUDE_TS_SHOW_SESSION    show session elapsed           default: 0
#   CLAUDE_TS_SANITY_CAP      suppress deltas > N seconds    default: 86400   (24h)
#   CLAUDE_TS_CLEANUP_DAYS    prune state older than N days  default: 30      (0 = off)

set -u

# ─── config ───────────────────────────────────────────────────────────────────

readonly STATE_DIR="${CLAUDE_TS_STATE_DIR:-$HOME/.claude/timestamps}"
readonly TIME_FORMAT="${CLAUDE_TS_TIME_FORMAT:-%H:%M:%S}"
readonly PROMPT_LABEL="${CLAUDE_TS_PROMPT_LABEL:-prompt}"
readonly RESPONSE_LABEL="${CLAUDE_TS_RESPONSE_LABEL:-response}"
readonly IDLE_LABEL="${CLAUDE_TS_IDLE_LABEL:-idle}"
readonly TOOK_LABEL="${CLAUDE_TS_TOOK_LABEL:-took}"
readonly SESSION_LABEL="${CLAUDE_TS_SESSION_LABEL:-session}"
readonly SHOW_DELTAS="${CLAUDE_TS_SHOW_DELTAS:-1}"
readonly SHOW_SESSION="${CLAUDE_TS_SHOW_SESSION:-0}"
readonly SANITY_CAP="${CLAUDE_TS_SANITY_CAP:-86400}"
readonly CLEANUP_DAYS="${CLAUDE_TS_CLEANUP_DAYS:-30}"

# ─── args ─────────────────────────────────────────────────────────────────────

kind=${1:-}
case "$kind" in
  prompt|response) ;;
  *) echo "usage: $0 {prompt|response}" >&2; exit 2 ;;
esac

# ─── dependencies ─────────────────────────────────────────────────────────────

for bin in jq date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "claude-timestamps: missing dependency: $bin" >&2
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

# ─── input ────────────────────────────────────────────────────────────────────

stdin_json=$(cat)
raw_sid=$(printf '%s' "$stdin_json" | jq -r '.session_id // "default"' 2>/dev/null || printf 'default')
session_id=$(sanitize_id "$raw_sid")

mkdir -p "$STATE_DIR" 2>/dev/null || true

prompt_file="$STATE_DIR/prompt-$session_id"
response_file="$STATE_DIR/response-$session_id"
session_file="$STATE_DIR/session-$session_id"

# ─── clocks ───────────────────────────────────────────────────────────────────

now_epoch=$(date +%s)
now_human=$(date "+$TIME_FORMAT")

# ─── cross-event delta (the interesting one per event) ────────────────────────

delta_str=""
if [[ $SHOW_DELTAS == "1" ]]; then
  case "$kind" in
    prompt)
      if prev=$(read_epoch "$response_file"); then
        d=$(safe_delta "$prev")
        [[ -n $d ]] && delta_str="$IDLE_LABEL $d"
      fi
      ;;
    response)
      if prev=$(read_epoch "$prompt_file"); then
        d=$(safe_delta "$prev")
        [[ -n $d ]] && delta_str="$TOOK_LABEL $d"
      fi
      ;;
  esac
fi

# ─── session elapsed (opt-in) ─────────────────────────────────────────────────

session_str=""
if [[ $SHOW_SESSION == "1" ]]; then
  if ! prev=$(read_epoch "$session_file"); then
    printf '%s\n' "$now_epoch" > "$session_file" 2>/dev/null || true
    prev=$now_epoch
  fi
  d=$(safe_delta "$prev")
  [[ -n $d ]] && session_str="$SESSION_LABEL $d"
fi

# ─── persist current event timestamp ──────────────────────────────────────────

case "$kind" in
  prompt)   printf '%s\n' "$now_epoch" > "$prompt_file"   2>/dev/null || true ;;
  response) printf '%s\n' "$now_epoch" > "$response_file" 2>/dev/null || true ;;
esac

# ─── cleanup (scoped by filename prefix) ──────────────────────────────────────

if (( CLEANUP_DAYS > 0 )) && [[ -d $STATE_DIR ]]; then
  find "$STATE_DIR" -type f \
    \( -name 'prompt-*' -o -name 'response-*' -o -name 'session-*' \) \
    -mtime "+$CLEANUP_DAYS" -delete 2>/dev/null
fi

# ─── compose + emit ───────────────────────────────────────────────────────────

if [[ $kind == "prompt" ]]; then
  label=$PROMPT_LABEL
else
  label=$RESPONSE_LABEL
fi

msg="$label $now_human"
[[ -n $delta_str   ]] && msg="$msg  $delta_str"
[[ -n $session_str ]] && msg="$msg  $session_str"

jq -cn --arg m "$msg" '{systemMessage: $m}'
