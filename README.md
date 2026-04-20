# ticktock

Inline timestamps and per-turn deltas in your Claude Code transcript.

```
prompt #1 14:05:00
response #1 14:05:30  took 30s

prompt #2 14:06:12  idle 42s
subagent Explore  took 8s
response #2 14:08:10  took 1m58s

session recap: 1h23m · 17 turns · avg response 11s · longest 2m15s
```

Every prompt and response gets a small timestamp line. You see how long Claude is taking, how long you're idle between turns, how long subagents run, and how the session went overall.

---

## Install

```
/plugin marketplace add k33bs/ticktock
/plugin install ticktock@ticktock
```

Open `/hooks` (or restart Claude Code) once to register the hook events. That's it — the useful features are on by default.

> **Heads up on the `/plugin` configure screen.**
> When you enable ticktock, Claude Code opens a multi-field configuration UI. Every field is currently shown **blank** — even though ticktock declares sensible `default` values in its manifest, the `/plugin` UI doesn't pre-fill from them yet. This is tracked upstream as [anthropics/claude-code#46477](https://github.com/anthropics/claude-code/issues/46477).
>
> **What to do:** press Enter / Tab through every blank field. ticktock's built-in defaults apply to anything left empty, so you end up with the intended behavior anyway. If you want to customize, use the `CLAUDE_TICKTOCK_*` env vars (see [Configuration](#configuration)) — they take precedence over the plugin menu.

---

## What you see on every turn

By default, ticktock adds two kinds of lines to the transcript:

**Prompt line** — emitted when you submit a message.
```
prompt 14:05:00  idle 3m12s
```
- `14:05:00` — wall-clock time you submitted
- `idle 3m12s` — time since Claude's last response (how long you were thinking / away)

**Response line** — emitted when Claude finishes responding.
```
response 14:05:30  took 30s
```
- `14:05:30` — wall-clock time the response ended
- `took 30s` — how long the response took (prompt → completion)

The `idle` delta is hidden on the first prompt of a session (no prior response to compare against). The `took` delta is always present on a response because the matching prompt just fired moments earlier. Any delta larger than 24 hours (configurable via `sanity_cap`) is silently suppressed so stale state from a crashed session doesn't surface as bogus numbers — see [Robustness](#robustness).

---

## Features

### Session elapsed *(on by default)*

Appends running session time to every prompt and response line (not to subagent or recap lines — those stay compact).

```
prompt 14:05:00  idle 3m12s  session 12m
response 14:05:30  took 30s  session 12m30s
```

Disable via `CLAUDE_TICKTOCK_SHOW_SESSION=0` (or `show_session = 0` in the plugin menu).

### Turn counter *(on by default)*

Prefixes prompt and response lines with a per-session turn number. Useful for long sessions where "which prompt was that?" matters.

```
prompt #5 14:05:00  idle 3m12s
response #5 14:05:30  took 30s
```

Disable via `CLAUDE_TICKTOCK_SHOW_TURN=0` (or `show_turn = 0` in the plugin menu).

### Subagent timing

When a subagent finishes, a dedicated line shows its duration. Nothing to enable — if you don't use subagents, you never see this. Parallel subagents are tracked independently by their `agent_id`, so two subagents running at the same time don't step on each other.

```
prompt 14:06:12  idle 42s
subagent Explore  took 8s
subagent code-reviewer  took 1m04s
response 14:08:10  took 1m58s
```

### Session recap

One summary line at session end (triggered by `/clear`, `/compact`, quit, or any other `SessionEnd` event). Only shown for sessions with at least `recap_min_turns` turns (default `3`) so quick "what time is it" sessions don't generate noise.

```
session recap: 1h23m · 17 turns · avg response 11s · longest 2m15s
```

### History log (JSON lines) *(opt-in)*

Persistent, structured log of every event for external analysis. Machine-readable JSON, one event per line. **Off by default** — enable when you want it.

File: `${CLAUDE_PLUGIN_DATA}/history-YYYY-MM.jsonl` — monthly rotation, files older than `log_months` are pruned on each run (default 12 months; set to 0 to keep forever).

```jsonl
{"v":1,"ts":"2026-04-19T14:05:00Z","session":"abc123","kind":"prompt","turn":5}
{"v":1,"ts":"2026-04-19T14:05:20Z","session":"abc123","kind":"subagent","turn":5,"name":"Explore","took_s":8}
{"v":1,"ts":"2026-04-19T14:05:30Z","session":"abc123","kind":"response","turn":5,"took_s":30}
{"v":1,"ts":"2026-04-19T15:00:00Z","session":"abc123","kind":"session_end","turns":17,"elapsed_s":4980,"total_response_s":204,"longest_response_s":135}
```

Fields common to every event:

| Field     | Type   | Description                                        |
| --------- | ------ | -------------------------------------------------- |
| `v`       | int    | Schema version (currently `1`)                     |
| `ts`      | string | ISO 8601 UTC timestamp                             |
| `session` | string | Session id                                         |
| `kind`    | string | `prompt` / `response` / `subagent` / `session_end` |

Kind-specific fields:

| `kind`        | Fields                                                                                         |
| ------------- | ---------------------------------------------------------------------------------------------- |
| `prompt`      | `turn` (int), `idle_s` (int, omitted on first prompt)                                          |
| `response`    | `turn` (int), `took_s` (int)                                                                   |
| `subagent`    | `turn` (int), `name` (string), `took_s` (int) — logged on `SubagentStop`, one line per run     |
| `session_end` | `turns` (int), `elapsed_s` (int), `total_response_s` (int), `longest_response_s` (int)         |

Enable via plugin menu (`log_history = 1`) or `CLAUDE_TICKTOCK_LOG_HISTORY=1`. The log dir is cleaned up when you uninstall ticktock — the `/plugin` UI asks first, the `claude plugin uninstall` CLI deletes by default (pass `--keep-data` to preserve).

---

## Configuration

Two layers. The plugin menu covers every non-path option; `CLAUDE_TICKTOCK_*` environment variables override anything in the menu for per-shell tweaks.

### Via plugin menu

When you enable or reconfigure ticktock, Claude Code prompts for each of these. Leave any prompt blank to keep its default.

| Prompt             | Default          | Values          | Effect                                              |
| ------------------ | ---------------- | --------------- | --------------------------------------------------- |
| `time_format`      | `%H:%M:%S`       | strftime string | Wall-clock format on each line                       |
| `prompt_label`     | `prompt`         | any string      | Label prefixing prompt lines                         |
| `response_label`   | `response`       | any string      | Label prefixing response lines                       |
| `idle_label`       | `idle`           | any string      | Label for time-since-last-response                   |
| `took_label`       | `took`           | any string      | Label for response duration                          |
| `session_label`    | `session`        | any string      | Label for session-elapsed                            |
| `subagent_label`   | `subagent`       | any string      | Label on subagent lines                              |
| `recap_label`      | `session recap:` | any string      | Prefix on the recap line                             |
| `show_deltas`      | `1`              | `0` / `1`       | Show idle/took delta on prompt and response lines    |
| `show_session`     | `1`              | `0` / `1`       | Append `session Xm` to prompt and response lines     |
| `show_turn`        | `1`              | `0` / `1`       | Prefix lines with turn counter (`#1`, `#2`, …)       |
| `log_history`      | `0`              | `0` / `1`       | Write events to `history-YYYY-MM.jsonl`              |
| `recap_min_turns`  | `3`              | integer         | Only emit recap when session has ≥ N turns           |
| `log_months`       | `12`             | integer         | Prune history files older than N months (0 = never)  |
| `sanity_cap`       | `86400`          | integer seconds | Suppress deltas larger than N seconds (24h default)  |
| `cleanup_days`     | `30`             | integer         | Prune state files older than N days (0 = never)      |

Truthy values for the `show_*` and `log_history` toggles: `1`, `true`, `yes`, `on` (case-sensitive). Anything else is treated as off.

### Via environment variables

Everything above also has a matching `CLAUDE_TICKTOCK_*` environment variable — useful for per-shell tweaks, or for setting `CLAUDE_TICKTOCK_STATE_DIR` (the only option not exposed in the menu).

| Variable                     | Default                     |
| ---------------------------- | --------------------------- |
| `CLAUDE_TICKTOCK_STATE_DIR`        | `$HOME/.claude/timestamps`  |
| `CLAUDE_TICKTOCK_TIME_FORMAT`      | `%H:%M:%S`                  |
| `CLAUDE_TICKTOCK_PROMPT_LABEL`     | `prompt`                    |
| `CLAUDE_TICKTOCK_RESPONSE_LABEL`   | `response`                  |
| `CLAUDE_TICKTOCK_IDLE_LABEL`       | `idle`                      |
| `CLAUDE_TICKTOCK_TOOK_LABEL`       | `took`                      |
| `CLAUDE_TICKTOCK_SESSION_LABEL`    | `session`                   |
| `CLAUDE_TICKTOCK_SUBAGENT_LABEL`   | `subagent`                  |
| `CLAUDE_TICKTOCK_RECAP_LABEL`      | `session recap:`            |
| `CLAUDE_TICKTOCK_SHOW_DELTAS`      | `1`                         |
| `CLAUDE_TICKTOCK_SHOW_SESSION`     | `1`                         |
| `CLAUDE_TICKTOCK_SHOW_TURN`        | `1`                         |
| `CLAUDE_TICKTOCK_LOG_HISTORY`      | `0`                         |
| `CLAUDE_TICKTOCK_RECAP_MIN_TURNS`  | `3`                         |
| `CLAUDE_TICKTOCK_LOG_MONTHS`       | `12`                        |
| `CLAUDE_TICKTOCK_SANITY_CAP`       | `86400`                     |
| `CLAUDE_TICKTOCK_CLEANUP_DAYS`     | `30`                        |

Set them in your shell rc, or in the `env` block of Claude Code's `settings.json`.

### Precedence

Settings resolve in this order (highest wins):
1. `CLAUDE_TICKTOCK_*` environment variable
2. `CLAUDE_PLUGIN_OPTION_*` (set via `/plugin` UI, per the `userConfig` section in `plugin.json`)
3. Built-in default

Env vars being the top priority means you can override the plugin menu in a single shell session without touching the UI.

### Example: custom labels

Set in Claude Code's `settings.json`:
```json
{
  "env": {
    "CLAUDE_TICKTOCK_PROMPT_LABEL": "YOU",
    "CLAUDE_TICKTOCK_RESPONSE_LABEL": "CLAUDE",
    "CLAUDE_TICKTOCK_SHOW_SESSION": "1"
  }
}
```

Output:
```
YOU 14:05:00  idle 3m12s  session 12m
CLAUDE 14:05:30  took 30s  session 12m30s
```

---

## How it works

ticktock wires five hook events, each invoking the same script with a different `kind` argument:

| Hook event         | What ticktock does                                                                |
| ------------------ | --------------------------------------------------------------------------------- |
| `UserPromptSubmit` | Emit `prompt` line with idle delta; increment turn counter; persist prompt time    |
| `Stop`             | Emit `response` line with took delta; update response tallies                      |
| `SubagentStart`    | Silently record the subagent's start time keyed by `agent_id`                      |
| `SubagentStop`     | Compute subagent duration, emit `subagent NAME  took Xs`, delete the start-state   |
| `SessionEnd`       | Emit `session recap: …` if turns ≥ threshold; log `session_end`; clean up session  |

Each hook reads the current time, reads any relevant prior timestamps from small per-session state files, computes the delta, and writes a single-line `{"systemMessage": "..."}` on stdout. Claude Code renders that inline in the transcript.

### State files

Per-session state lives in `STATE_DIR` (default `~/.claude/timestamps/`):

| File                                         | Purpose                                                    |
| -------------------------------------------- | ---------------------------------------------------------- |
| `prompt-<session_id>`                        | Epoch seconds of last `UserPromptSubmit`                    |
| `response-<session_id>`                      | Epoch seconds of last `Stop`                                |
| `stats-<session_id>`                         | `first_ts`, `turns`, `total_response_s`, `longest_response_s` (key=value) |
| `subagent-<session_id>-<agent_id>`           | Epoch seconds of `SubagentStart`; deleted on matching `SubagentStop` |

Files are tiny (≤ 80 bytes each), per-session, and pruned after `cleanup_days` days of inactivity. `SessionEnd` deletes this session's files as soon as the recap is emitted.

### History log

When `log_history=1`, every event is also appended as a JSON line to `${CLAUDE_PLUGIN_DATA}/history-YYYY-MM.jsonl`. Files rotate monthly; files older than `log_months` months are pruned on each run. Storage in `CLAUDE_PLUGIN_DATA` means the log survives plugin updates, and is cleaned up automatically when you uninstall the plugin (the `/plugin` UI asks first; the CLI deletes by default — pass `--keep-data` to preserve).

---

## Robustness

- **Sanity cap** — deltas larger than 24 h (`sanity_cap`) are silently suppressed. If a session crashed yesterday, today's first prompt won't show "idle 23h" nonsense.
- **Clock jumps** — negative deltas (NTP corrections, timezone changes) are dropped silently.
- **Unwritable state dir** — if `STATE_DIR` is read-only, the hook still emits the timestamp line and degrades gracefully (no deltas, no cleanup, no stderr noise).
- **Invalid or missing stdin** — the hook falls back to a `default` session id and still emits a line.
- **Bad config values** — non-numeric values for numeric options fall back to their defaults. Values like `08` that look numeric but are invalid octal are correctly coerced to base 10.
- **Command injection** — untrusted env values can't execute code; all arithmetic uses bash's `(( ))` which rejects non-numeric expressions, and shell command strings never inline user-controlled data without quoting.
- **Path traversal via `session_id`** — filenames are sanitized (only alphanumerics, `.`, `_`, `-` survive), so even a maliciously crafted `session_id` can't escape `STATE_DIR`.
- **Concurrent sessions** — every file is scoped by `session_id`, so parallel Claude Code windows don't collide.
- **Parallel subagents** — `SubagentStart`/`SubagentStop` events are correlated by `agent_id`, each in its own state file.

---

## Requirements

- **bash 3.2+** (macOS default bash works; no bash 4 features used)
- **`jq`** — JSON parsing on stdin, safe JSON output
- **`date`** — `+%s` (epoch seconds) and `+%H:%M:%S` (strftime) support
- **`find`** — `-mtime` and `-delete` flags

Tested on macOS and Linux. Windows is untested but should work under WSL.

---

## Development

This repo is a Claude Code marketplace containing a single plugin (also named `ticktock`).

Layout:
```
ticktock/                       repo root (also a Claude Code marketplace)
├── .claude-plugin/
│   └── marketplace.json        marketplace manifest
├── ticktock/                   the plugin itself
│   ├── .claude-plugin/
│   │   └── plugin.json         plugin manifest
│   └── hooks/
│       ├── hooks.json          hook event wiring
│       └── timestamps.sh       the script run on every event
├── tests/
│   └── test.sh                 regression suite (run before committing)
└── README.md                   this file
```

### Run the tests

```
./tests/test.sh
```

The suite verifies manifest validity, the happy path, cross-deltas, session elapsed, sanity-cap / clock-jump / garbage-state handling, read-only-directory behavior, numeric-env-var validation, injection resistance, and argument validation. It exits non-zero if anything fails.

To test against a different copy of the script:
```
SCRIPT=/path/to/timestamps.sh ./tests/test.sh
```

Test state is isolated in a tempdir and cleaned up on exit — the suite does not touch your real `~/.claude/timestamps/`.

---

## About

Visit our Discord **EAT LASERS** at [absolutely.works](https://absolutely.works).

## License

MIT
