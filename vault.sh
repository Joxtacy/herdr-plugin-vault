#!/usr/bin/env bash
# Vault: pick a past Claude Code session, resume it in a new herdr tab.
set -euo pipefail

ROOT="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

age() {
	local now d
	now=$(date +%s)
	d=$((now - $1))
	if [ $d -lt 3600 ]; then echo "$((d / 60))m"
	elif [ $d -lt 86400 ]; then echo "$((d / 3600))h"
	else echo "$((d / 86400))d"
	fi
}

# ponytail: only the first few "user" records are read per transcript (grep -m8 stops there).
# Reading whole files is ~50x slower and the first real prompt is the only title we need.
row() {
	local f=$1 id line ts
	[ -f "$f" ] || return 0
	id=${f##*/}
	id=${id%.jsonl}
	line=$(grep -m8 '"type":"user"' "$f") || return 0
	ts=$(mtime "$f")
	printf '%s\n' "$line" | jq -rs --arg id "$id" --arg f "$f" --arg ts "$ts" --arg age "$(age "$ts")" '
		(.[0].cwd // "?") as $cwd
		| (($cwd | split("/") | last) // "?") as $proj
		| ([.[] | .message.content? | select(type == "string")
			| select(startswith("<") | not)] | .[0] // "(no prompt)"
			| gsub("\\s+"; " ") | .[0:100]) as $title
		| (($age + "     ")[0:5] + ($proj + "                         ")[0:25] + " " + $title) as $display
		| [$ts, $display, $f, $id, $cwd] | @tsv'
}

# Row lookup by fzf's zero-based item index. The meta file keeps path/id/cwd out of the
# picker display without relying on fzf field placeholders, which see only the display text.
meta_row() { sed -n "$(($1 + 1))p" "$2"; }

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
	# List mode: also the seam the self-check runs against.
	# Scanning is process-bound, not IO-bound, so it fans out 8 ways. A global sort would
	# hold every row back until the last one landed, so instead the files go through in
	# mtime order in chunks: each chunk streams out as it finishes, newest first.
	--list)
		{ stat -f '%m %N' "$ROOT"/*/*.jsonl 2>/dev/null ||
			stat -c '%Y %n' "$ROOT"/*/*.jsonl; } |
			sort -rn | cut -d' ' -f2- | tr '\n' '\0' |
			xargs -0 -n 16 "$SELF" --chunk
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

		# Hand the launch to a plugin action and exit. The action runs under the herdr
		# server, so it outlives this popup; anything backgrounded here dies with the pane.
		printf '%s\t%s\t%s\n' "$pane" "$id" "$label" > "$(pending_file)"
		herdr plugin action invoke launch --plugin vault >/dev/null
		exit 0
		;;
	--launch)
		pending=$(pending_file)
		[ -f "$pending" ] || exit 0
		read -r pane id label < "$pending"
		rm -f "$pending"

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

# tee keeps the index lookups working while fzf consumes the same rows live: a row is
# only selectable once it has been written, and both sides see identical ordering.
# awk rather than cut: cut block-buffers into a pipe, which holds every row back until
# the scan finishes and silently undoes the chunking.
"$SELF" --list | tee "$meta" | awk -F'\t' '{ print $1; fflush() }' | fzf \
	--preview="$SELF --preview {n} $meta" --preview-window='right:55%:wrap' \
	--bind="enter:become($SELF --resume {n} $meta)" \
	--header='enter: resume in new tab   esc: cancel' \
	--prompt='vault> '
