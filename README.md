# herdr-plugin-vault

Browse past Claude Code sessions in a [herdr](https://herdr.dev) popup and resume
the one you pick in a new tab.

Every Claude Code session leaves a transcript in `~/.claude/projects`. Vault turns
that pile into a searchable picker: when it was last touched, which project, and what
it was about. Pick one and it comes back in a new herdr tab.

```
0m   dotfiles                  Terminal vim mode breakage
2h   blog                      Draft post on the new build pipeline [drafts/ci]
26d  api-server                Flaky retry test on CI [main]
90d  old-spike                 Benchmark the queue client (folder gone)
```

Each row shows the session's name and the git branch it ran on. The name is the one
you gave it with `/rename` if you did, otherwise the title Claude gave it, otherwise
your first prompt.

## Requirements

- herdr 0.8.0 or newer
- [`fzf`](https://github.com/junegunn/fzf) 0.38 or newer and [`jq`](https://jqlang.github.io/jq/) on `PATH`
- Claude Code (this plugin reads `~/.claude/projects`; it is Claude-specific by design)
- macOS or Linux

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

`prefix+alt+v` opens the popup. Type to filter on project, title or branch; the right
pane previews the conversation.

| Key      | Action                                                              |
| -------- | ------------------------------------------------------------------- |
| `enter`  | Resume the session in a new tab                                     |
| `ctrl-f` | Fork it: a new session that starts from the old one's history       |
| `ctrl-p` | Show only sessions from the project you opened vault from           |
| `ctrl-a` | Show all projects again                                             |

"The project you opened vault from" is the focused pane's git repository, or its
directory when it is not in one; sessions started in subdirectories count. The keys
only appear when vault can tell which pane that was.

Sessions whose folder no longer exists are dimmed and marked `(folder gone)`.

If the session you pick is already running in a pane, vault focuses that pane instead
of resuming it — two processes appending to one transcript corrupts it. A fork writes
to a new transcript, so it always opens a new tab, even while the original runs.

Otherwise it creates a tab in the session's original working directory and launches
`claude --resume <id>` (plus `--fork-session` for a fork) there via `herdr agent start`, which waits until Claude is
actually up. If the launch fails, the command is left on the prompt for you to run.

## Configuration

`CLAUDE_PROJECTS_DIR` overrides the transcript directory (default `~/.claude/projects`).

Popup size lives in `herdr-plugin.toml`.

## Notes

The listing reads only the first few records of each transcript and scans in parallel,
in newest-first chunks, so the first rows appear almost at once and about 120 sessions
finish in a second or two. Subagent transcripts (`*/subagents/*.jsonl`) are excluded.

The branch is the one Claude recorded when the session started. Repos where git sits on
a detached `HEAD` (Jujutsu, for example) show no branch.

`./test_vault.sh` runs a self-check against fixture transcripts, including a picker
startup with `fzf` and `herdr` stubbed out. CI runs it on macOS and Linux.

## License

MIT
