# ticktock

A Claude Code plugin that adds inline timestamps and per-turn deltas to your transcript.

```
prompt 14:05:00  idle 3m12s
response 14:05:30  took 30s
```

This repo is a Claude Code marketplace containing a single plugin (also named `ticktock`).

## Install

```
/plugin marketplace add k33bs/ticktock
/plugin install ticktock@ticktock
```

Then open `/hooks` (or restart Claude Code) to register the new hook events.

> **Note on the `/plugin` configure screen.**
> When Claude Code prompts you through ticktock's 16 configuration fields, every box appears **blank** — even though the plugin ships sensible defaults. The `/plugin` UI doesn't read the manifest's `default` values yet; this is tracked as [anthropics/claude-code#46477](https://github.com/anthropics/claude-code/issues/46477).
>
> Press Enter through every blank prompt — ticktock's built-in defaults apply to anything you leave empty. To customize, use the `CLAUDE_TICKTOCK_*` env vars (see the [plugin README](ticktock/README.md#configuration)).

See [`ticktock/README.md`](ticktock/README.md) for full documentation and configuration.

## Development

Layout:
```
ticktock/                       repo root (also a Claude Code marketplace)
├── .claude-plugin/
│   └── marketplace.json        marketplace manifest
├── ticktock/                   the plugin itself
│   ├── .claude-plugin/
│   │   └── plugin.json         plugin manifest
│   ├── hooks/
│   │   ├── hooks.json          hook event wiring
│   │   └── timestamps.sh       the script run on every event
│   └── README.md               user-facing docs
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

## About

Visit our Discord **EAT LASERS** at [absolutely.works](https://absolutely.works).

## License

MIT
