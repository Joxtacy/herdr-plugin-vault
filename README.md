# herdr-plugin-vault

Browse past Claude Code sessions in a [herdr](https://herdr.dev) popup and resume
the one you pick in a new tab.

Every Claude Code session leaves a transcript in `~/.claude/projects`. Vault turns
that pile into a searchable picker: when it was last touched, which project, and the
first thing you asked. Pick one and it comes back in a new herdr tab.

```
0m   dotfiles                  Can you add my herdr config in here?
2m   configurator-config-files For what are the strings "sip.livekit.cloud" used for
26d  k8s-apps                  Can you compare PR 1213 and 1250 and tell me what differs?
```

## Requirements

- herdr 0.8.0 or newer
- [`fzf`](https://github.com/junegunn/fzf) and [`jq`](https://jqlang.github.io/jq/) on `PATH`
- Claude Code (this plugin reads `~/.claude/projects`; it is Claude-specific by design)

## Install

```sh
herdr plugin install Joxtacy/herdr-plugin-vault
```

Then bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+v"
type = "shell"
command = "herdr plugin pane open --plugin vault --entrypoint vault"
```

Reload with `herdr server reload-config`.

## Use

`prefix+alt+v` opens the popup. Type to filter on project name or prompt text; the
right pane previews the conversation. Enter resumes.

If the session you pick is already running in a pane, vault focuses that pane instead
of resuming it — two processes appending to one transcript corrupts it.

Otherwise it creates a tab in the session's original working directory and launches
`claude --resume <id>` there via `herdr agent start`, which waits until Claude is
actually up. If the launch fails, the command is left on the prompt for you to run.

## Configuration

`CLAUDE_PROJECTS_DIR` overrides the transcript directory (default `~/.claude/projects`).

Popup size lives in `herdr-plugin.toml`.

## Notes

The listing reads only the first few records of each transcript, so a few hundred
sessions cost a couple of seconds and rows stream into fzf as they are found.
Subagent transcripts (`*/subagents/*.jsonl`) are excluded.

`./test_vault.sh` runs a self-check against a fixture transcript.

## License

MIT
