#!/usr/bin/env bash
# Vault: pick a past Claude Code session, resume it in a new herdr tab.
set -euo pipefail

ROOT="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

age() {
	local mtime now d
	mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1")
	now=$(date +%s)
	d=$((now - mtime))
	if [ $d -lt 3600 ]; then echo "$((d / 60))m"
	elif [ $d -lt 86400 ]; then echo "$((d / 3600))h"
	else echo "$((d / 86400))d"
	fi
}

# ponytail: only the first few "user" records are read per transcript (grep -m8 stops there).
# Reading whole files is ~50x slower and the first real prompt is the only title we need.
row() {
	local f=$1 id line
	id=${f##*/}
	id=${id%.jsonl}
	line=$(grep -m8 '"type":"user"' "$f") || return 0
	printf '%s\n' "$line" | jq -rs --arg id "$id" --arg f "$f" --arg age "$(age "$f")" '
		(.[0].cwd // "?") as $cwd
		| (($cwd | split("/") | last) // "?") as $proj
		| ([.[] | .message.content? | select(type == "string")
			| select(startswith("<") | not)] | .[0] // "(no prompt)"
			| gsub("\\s+"; " ") | .[0:100]) as $title
		| (($age + "     ")[0:5] + ($proj + "                         ")[0:25] + " " + $title) as $display
		| [$display, $f, $id, $cwd] | @tsv'
}

# Row lookup by fzf's zero-based item index. The meta file keeps path/id/cwd out of the
# picker display without relying on fzf field placeholders, which see only the display text.
meta_row() { sed -n "$(($1 + 1))p" "$2"; }

case "${1:-}" in
	# List mode: also the seam the self-check runs against.
	# command ls -t gives newest-first; no extra sort needed.
	--list)
		command ls -t "$ROOT"/*/*.jsonl 2>/dev/null | while read -r f; do row "$f"; done
		exit 0
		;;
	--preview)
		jq -r 'select(.type == "user" or .type == "assistant")
			| (.message.content // "") as $c
			| (if ($c | type) == "string" then $c
				else ([$c[]? | select(.type == "text") | .text] | join(" ")) end) as $t
			| select($t != "")
			| "\(.type | ascii_upcase): \($t[0:400])\n"' "$(meta_row "$2" "$3" | cut -f2)" 2>/dev/null | tail -60
		exit 0
		;;
	--resume)
		row=$(meta_row "$2" "$3")
		rm -f "$3"
		id=$(printf '%s' "$row" | cut -f3)
		cwd=$(printf '%s' "$row" | cut -f4)
		[ -d "$cwd" ] || { echo "gone: $cwd"; read -r _; exit 1; }

		# Already running: focus it. Resuming a live session twice corrupts the transcript.
		pane=$(herdr agent list 2>/dev/null |
			jq -r --arg id "$id" '.result.agents[]? | select(.agent_session.value == $id) | .pane_id' |
			head -1)
		if [ -n "$pane" ]; then
			herdr agent focus "$pane" >/dev/null
			exit 0
		fi

		label=${cwd##*/}
		pane=$(herdr tab create --cwd "$cwd" --label "$label" --focus |
			jq -r '.result.root_pane.pane_id')

		# Wait for the prompt, then clear the line: agent start appends to whatever is
		# already on it, and a keystroke can land here between tab create and launch.
		herdr pane wait-output "$pane" --regex '\S' --timeout 10000 >/dev/null 2>&1 || true
		sleep 0.5
		herdr pane send-keys "$pane" ctrl+u >/dev/null 2>&1 || true

		herdr agent start "$label" --kind claude --pane "$pane" -- --resume "$id" >/dev/null ||
			# Leave the command on the prompt so the resume is one keypress away.
			herdr pane send-text "$pane" "claude --resume $id" >/dev/null
		exit 0
		;;
esac

for bin in fzf jq herdr; do
	command -v "$bin" >/dev/null || { echo "vault needs $bin on PATH"; read -r _; exit 1; }
done

meta=$(mktemp -t herdr-vault)
trap 'rm -f "$meta"' EXIT
"$SELF" --list > "$meta"

cut -f1 "$meta" | fzf \
	--preview="$SELF --preview {n} $meta" --preview-window='right:55%:wrap' \
	--bind="enter:become($SELF --resume {n} $meta)" \
	--header='enter: resume in new tab   esc: cancel' \
	--prompt='vault> '
