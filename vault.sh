#!/usr/bin/env bash
# Vault: pick a past Claude Code session, resume it in a new herdr tab.
set -euo pipefail

ROOT="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# GNU and BSD stat disagree on flags, and BSD-style `stat -f` under GNU does not fail
# cleanly: it prints filesystem info for the file before erroring. Detect once instead
# of trying one and falling back. GNU coreutils on a Mac takes the GNU branch.
if stat -c %Y / >/dev/null 2>&1; then
	mtimes() { stat -c '%Y %n' "$@"; }
else
	mtimes() { stat -f '%m %N' "$@"; }
fi
mtime() { mtimes "$1" | cut -d' ' -f1; }

age() {
	local now d
	now=$(date +%s)
	d=$((now - $1))
	if [ $d -lt 3600 ]; then echo "$((d / 60))m"
	elif [ $d -lt 86400 ]; then echo "$((d / 3600))h"
	else echo "$((d / 86400))d"
	fi
}

# One TSV row per transcript: mtime, display, path, id, cwd, title, branch.
# The picker shows only the display; the rest rides along as hidden fzf fields.
# ponytail: only the first few "user" records and the first "ai-title" record are read
# (grep -m stops there). Reading whole files is ~50x slower, and Claude's title for a
# session almost never changes after it is first written.
row() {
	local f=$1 id users title cwd ts gone=0
	[ -f "$f" ] || return 0
	id=${f##*/}
	id=${id%.jsonl}
	users=$(grep -m8 '"type":"user"' "$f") || return 0
	title=$(grep -m1 '"type":"ai-title"' "$f") || true
	cwd=$(printf '%s\n' "$users" | grep -m1 -o '"cwd":"[^"]*"') || true
	cwd=${cwd#\"cwd\":\"}
	cwd=${cwd%\"}
	[ -z "$cwd" ] || [ -d "$cwd" ] || gone=1
	ts=$(mtime "$f")
	printf '%s\n%s\n' "$users" "$title" |
		jq -rs --arg id "$id" --arg f "$f" --arg ts "$ts" --arg age "$(age "$ts")" --arg gone "$gone" '
		"\u001b[2m" as $dim | "\u001b[0m" as $reset
		| [.[] | select(.type == "user")] as $u
		| ($u[0].cwd // "?") as $cwd
		| (($cwd | split("/") | last) // "?") as $proj
		| ([$u[] | .gitBranch? // empty | select(. != "" and . != "HEAD")] | .[0] // "") as $branch
		| ([.[] | select(.type == "ai-title") | .aiTitle? // empty | select(. != "")] | .[0]) as $ai
		| ([$u[] | .message.content? | select(type == "string")
			| select(startswith("<") | not)] | .[0]) as $prompt
		| ($ai // $prompt // "(no prompt)" | gsub("\\s+"; " ") | .[0:100]) as $title
		| (($age + "     ")[0:5] + ($proj + "                         ")[0:25] + " " + $title) as $base
		| (if $branch == "" then "" else " [" + $branch + "]" end) as $tag
		| (if $gone == "1" then $dim + $base + $tag + " (folder gone)" + $reset
			else $base + $dim + $tag + $reset end) as $display
		| [$ts, $display, $f, $id, $cwd, $title, $branch] | @tsv'
}

# The project the user was looking at when vault opened: the focused pane's directory,
# widened to its git root so sessions started in subdirectories count too.
here_root() {
	local dir
	dir=$(herdr pane list 2>/dev/null | jq -r --arg self "${HERDR_PANE_ID:-}" '
		[.result.panes[]? | select(.focused and .pane_id != $self)][0]
		| .foreground_cwd // .cwd // empty' 2>/dev/null) || true
	# A popup that reports itself as the focused pane would point at the plugin dir.
	[ -n "$dir" ] && [ -d "$dir" ] && [ "$dir" != "${SELF%/*}" ] || return 0
	git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$dir"
}

# Handoff between the picker and the launch action. herdr injects the state dir into
# both, so this only falls back when the script is run outside herdr.
# ponytail: one fixed path, read ~30ms after it is written. Two picks would have to land
# inside that window to collide; make it per-invocation if that ever happens.
pending_file() {
	local dir=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}
	mkdir -p "$dir"
	printf '%s/pending' "$dir"
}

case "${1:-}" in
	# One row for one transcript. Exists so --list can fan out over xargs.
	--row)
		row "$2"
		exit 0
		;;
	# One chunk of transcripts, fanned out and re-ordered within the chunk.
	--chunk)
		shift
		printf '%s\0' "$@" | xargs -0 -P 8 -n 1 "$SELF" --row | sort -rn -k1,1 | cut -f2-
		exit 0
		;;
	# List mode: also the seam the self-check runs against. `--list DIR` keeps only
	# sessions started in DIR or below it.
	# Scanning is process-bound, not IO-bound, so it fans out 8 ways. A global sort would
	# hold every row back until the last one landed, so instead the files go through in
	# mtime order in chunks: each chunk streams out as it finishes, newest first.
	--list)
		shopt -s nullglob
		files=("$ROOT"/*/*.jsonl)
		[ ${#files[@]} -gt 0 ] || exit 0
		mtimes "${files[@]}" |
			sort -rn | cut -d' ' -f2- | tr '\n' '\0' |
			xargs -0 -n 16 "$SELF" --chunk |
			VAULT_UNDER=${2:-} awk -F'\t' '
				BEGIN { r = ENVIRON["VAULT_UNDER"] }
				r == "" || $4 == r || index($4, r "/") == 1 { print; fflush() }'
		exit 0
		;;
	# Args: path id cwd title branch (hidden fields 2-6 of the row).
	--preview)
		path=$2 id=$3 cwd=$4 title=${5:-} branch=${6:-}
		printf '\033[1m%s\033[0m\n%s' "$title" "$cwd"
		[ -z "$branch" ] || printf '  [%s]' "$branch"
		[ -d "$cwd" ] || printf '  \033[31m(folder gone)\033[0m'
		printf '\n\033[2m%s\033[0m\n\n' "$id"
		jq -r 'select(.type == "user" or .type == "assistant")
			| (.message.content // "") as $c
			| (if ($c | type) == "string" then $c
				else ([$c[]? | select(.type == "text") | .text] | join(" ")) end) as $t
			| select($t != "")
			| "\(.type | ascii_upcase): \($t[0:400])\n"' "$path" 2>/dev/null | tail -60
		exit 0
		;;
	# Args: id cwd [--fork]. Forking starts a new session from the old one's history.
	--resume)
		id=$2 cwd=$3 mode=resume
		[ "${4:-}" = --fork ] && mode=fork
		if [ ! -d "$cwd" ]; then
			echo "This session's folder no longer exists: $cwd"
			echo "Press Enter to close."
			read -r _
			exit 1
		fi

		# Already running: focus it. Resuming a live session twice corrupts the transcript.
		# A fork writes to a new transcript, so it can run alongside the original.
		if [ "$mode" = resume ]; then
			pane=$(herdr agent list 2>/dev/null |
				jq -r --arg id "$id" '.result.agents[]? | select(.agent_session.value == $id) | .pane_id' |
				head -1)
			if [ -n "$pane" ]; then
				herdr agent focus "$pane" >/dev/null
				exit 0
			fi
		fi

		label=${cwd##*/}
		pane=$(herdr tab create --cwd "$cwd" --label "$label" --focus |
			jq -r '.result.root_pane.pane_id')

		# Hand the launch to a plugin action and exit. The action runs under the herdr
		# server, so it outlives this popup; anything backgrounded here dies with the pane.
		printf '%s\t%s\t%s\t%s\n' "$pane" "$id" "$mode" "$label" > "$(pending_file)"
		herdr plugin action invoke launch --plugin vault >/dev/null
		exit 0
		;;
	--launch)
		pending=$(pending_file)
		[ -f "$pending" ] || exit 0
		IFS=$'\t' read -r pane id mode label < "$pending"
		rm -f "$pending"
		args=(--resume "$id")
		[ "$mode" = fork ] && args+=(--fork-session)

		# Wait for the prompt, then clear the line: agent start appends to whatever is
		# already on it, and a keystroke can land here between tab create and launch.
		herdr pane wait-output "$pane" --regex '\S' --timeout 10000 >/dev/null 2>&1 || true
		sleep 0.5
		herdr pane send-keys "$pane" ctrl+u >/dev/null 2>&1 || true

		herdr agent start "$label" --kind claude --pane "$pane" -- "${args[@]}" >/dev/null ||
			# Leave the command on the prompt so the resume is one keypress away.
			herdr pane send-text "$pane" "claude ${args[*]}" >/dev/null
		exit 0
		;;
esac

for bin in fzf jq herdr; do
	command -v "$bin" >/dev/null || { echo "vault needs $bin on PATH"; read -r _; exit 1; }
done

# fzf hands these strings to a shell, so quote the paths in case they contain spaces.
# Placeholders like {3} are quoted by fzf itself.
self_q=$(printf '%q' "$SELF")
header='enter: resume   ctrl-f: fork   esc: cancel'
binds=(
	--bind="enter:become($self_q --resume {3} {4})"
	--bind="ctrl-f:become($self_q --resume {3} {4} --fork)"
)

here=$(here_root)
if [ -n "$here" ]; then
	name=${here##*/}
	name=${name//[\[\]]/}
	# reload: goes last in its colon form so a ")" in the path cannot end it early.
	binds+=(
		--bind="ctrl-p:change-prompt[$name> ]+reload:$self_q --list $(printf '%q' "$here")"
		--bind="ctrl-a:change-prompt[vault> ]+reload:$self_q --list"
	)
	header="$header"$'\n'"ctrl-p: only $name   ctrl-a: all projects"
fi

"$SELF" --list | fzf --ansi --delimiter='\t' --with-nth=1 \
	--preview="$self_q --preview {2} {3} {4} {5} {6}" --preview-window='right:55%:wrap' \
	"${binds[@]}" \
	--header="$header" \
	--prompt='vault> '
