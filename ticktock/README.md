# ticktock

Inline timestamps and per-turn deltas in your Claude Code transcript.

```
prompt 14:05:00  idle 3m12s
response 14:05:30  took 30s
```

- **prompt** lines show the time you submitted, plus how long you were idle since Claude's last response
- **response** lines show when Claude finished, plus how long the response took

## Install

```
/plugin marketplace add k33bs/ticktock
/plugin install ticktock@ticktock
```

Then open `/hooks` (or restart Claude Code) to register the hook events.

## Output

**Default** — one useful delta per event:

```
prompt 14:05:00  idle 3m12s
response 14:05:30  took 30s
```

**With session elapsed** (`CLAUDE_TS_SHOW_SESSION=1`):

```
prompt 14:05:00  idle 3m12s  session 12m
response 14:05:30  took 30s   session 12m30s
```

**Full date format** (`CLAUDE_TS_TIME_FORMAT="%Y-%m-%d %H:%M:%S"`):

```
prompt 2026-04-19 14:05:00  idle 3m12s
```

## Configuration

All configuration is via environment variables — set them in your Claude Code `settings.json` under `env`, or export them in your shell.

| Variable                    | Default                        | Description                                     |
| --------------------------- | ------------------------------ | ----------------------------------------------- |
| `CLAUDE_TS_STATE_DIR`       | `$HOME/.claude/timestamps`     | Where per-session state files live              |
| `CLAUDE_TS_TIME_FORMAT`     | `%H:%M:%S`                     | strftime format for the wall-clock time         |
| `CLAUDE_TS_PROMPT_LABEL`    | `prompt`                       | Label prefixing prompt lines                    |
| `CLAUDE_TS_RESPONSE_LABEL`  | `response`                     | Label prefixing response lines                  |
| `CLAUDE_TS_IDLE_LABEL`      | `idle`                         | Label for time-since-last-response              |
| `CLAUDE_TS_TOOK_LABEL`      | `took`                         | Label for response duration                     |
| `CLAUDE_TS_SESSION_LABEL`   | `session`                      | Label for session-elapsed                       |
| `CLAUDE_TS_SHOW_DELTAS`     | `1`                            | `1` to show per-event delta, `0` to hide        |
| `CLAUDE_TS_SHOW_SESSION`    | `0`                            | `1` to append session-elapsed on every line     |
| `CLAUDE_TS_SANITY_CAP`      | `86400` (24h)                  | Suppress deltas larger than N seconds           |
| `CLAUDE_TS_CLEANUP_DAYS`    | `30`                           | Prune state files older than N days (0 = off)   |

### Example: customize labels

```json
{
  "env": {
    "CLAUDE_TS_PROMPT_LABEL": "YOU",
    "CLAUDE_TS_RESPONSE_LABEL": "CLAUDE",
    "CLAUDE_TS_SHOW_SESSION": "1"
  }
}
```

Output:
```
YOU 14:05:00  idle 3m12s  session 12m
CLAUDE 14:05:30  took 30s  session 12m30s
```

## How it works

ticktock wires two hooks into Claude Code:

- **`UserPromptSubmit`** fires when you submit a prompt. The hook emits a `systemMessage` with the current time plus the idle delta (time since Claude's last response).
- **`Stop`** fires when Claude finishes responding. The hook emits a `systemMessage` with the current time plus the response duration.

Per-session state is kept in `$HOME/.claude/timestamps/` (override with `CLAUDE_TS_STATE_DIR`). Orphaned state from crashed sessions is auto-pruned after 30 days.

## Robustness

- **Sanity cap**: deltas larger than 24 hours (tune with `CLAUDE_TS_SANITY_CAP`) are suppressed, so an interrupted session from yesterday won't show "idle 23h" today.
- **Clock jumps**: negative deltas are silently dropped.
- **Missing deps**: the hook fails gracefully if `jq` or `date` aren't on PATH.
- **Concurrent sessions**: per-session state files keep parallel Claude Code sessions isolated.

## Requirements

- bash
- `jq`
- POSIX `date` with `+%s` and strftime (`+%H:%M:%S`)
- POSIX `find` with `-mtime` and `-delete`

Tested on macOS and Linux.

## About

Visit our Discord **EAT LASERS** at [absolutely.works](https://absolutely.works).

## License

MIT
