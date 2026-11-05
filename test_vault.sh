#!/usr/bin/env bash
# Self-check for vault.sh. Run: ./test_vault.sh
# Covers row parsing, ordering, the empty case, and picker startup (with fzf/herdr stubbed).
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

projects="$tmp/projects"
mkdir -p "$projects/-Users-x-demo" "$projects/-Users-x-old"
new="$projects/-Users-x-demo/11111111-2222-3333-4444-555555555555.jsonl"
old="$projects/-Users-x-old/66666666-7777-8888-9999-000000000000.jsonl"
cat > "$new" <<'EOF'
{"type":"file-history-snapshot","messageId":"x"}
{"type":"user","cwd":"/Users/x/demo","message":{"content":"<command-name>/init</command-name>"}}
{"type":"user","cwd":"/Users/x/demo","message":{"content":[{"type":"tool_result","content":"noise"}]}}
{"type":"user","cwd":"/Users/x/demo","message":{"content":"real   first\nprompt"}}
EOF
cat > "$old" <<'EOF'
{"type":"user","cwd":"/Users/x/old","message":{"content":"older prompt"}}
EOF
touch -t 202001010000 "$old"

# --list: rows newest first, nothing on stderr.
out=$(CLAUDE_PROJECTS_DIR="$projects" ./vault.sh --list 2>"$tmp/err")
[ ! -s "$tmp/err" ] || fail "--list wrote to stderr: $(cat "$tmp/err")"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ] || fail "expected 2 rows, got: $out"

IFS=$'\t' read -r display path id cwd <<<"$(printf '%s\n' "$out" | sed -n 1p)"
[ "$id" = "11111111-2222-3333-4444-555555555555" ] || fail "newest row first, got id=$id"
[ "$cwd" = "/Users/x/demo" ] || fail "cwd=$cwd"
[ "$path" = "$new" ] || fail "path=$path"
case "$display" in
	"0m   demo"*"real first prompt") ;;
	*) fail "bad age, project or unsquashed title: $display" ;;
esac
case "$display" in
	*"<command-name>"*) fail "slash-command record used as title" ;;
esac

IFS=$'\t' read -r display _ id _ <<<"$(printf '%s\n' "$out" | sed -n 2p)"
[ "$id" = "66666666-7777-8888-9999-000000000000" ] || fail "oldest row last, got id=$id"
[[ "$display" =~ ^[0-9]+d\ *old\ +older\ prompt$ ]] || fail "bad age for old row: $display"

# --list on an empty projects dir: no rows, clean exit.
mkdir -p "$tmp/empty"
out=$(CLAUDE_PROJECTS_DIR="$tmp/empty" ./vault.sh --list 2>"$tmp/err") || fail "--list on empty dir exited non-zero"
[ -z "$out" ] || fail "--list on empty dir printed: $out"
[ ! -s "$tmp/err" ] || fail "--list on empty dir wrote to stderr: $(cat "$tmp/err")"

# Picker startup, with fzf and herdr stubbed. The fzf stub records the rows it got and
# runs the preview command fzf would run, so the quoted paths are exercised too.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_OUT/rows"
for arg; do
	case "$arg" in --preview=*) cmd=${arg#--preview=}; bash -c "${cmd//\{n\}/0}" > "$STUB_OUT/preview" ;; esac
done
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/herdr"
chmod +x "$tmp/bin/fzf" "$tmp/bin/herdr"

STUB_OUT=$tmp PATH="$tmp/bin:$PATH" CLAUDE_PROJECTS_DIR="$projects" ./vault.sh </dev/null >/dev/null 2>"$tmp/err" ||
	fail "picker exited non-zero: $(cat "$tmp/err")"
[ ! -s "$tmp/err" ] || fail "picker wrote to stderr: $(cat "$tmp/err")"
[ "$(wc -l < "$tmp/rows" | tr -d ' ')" -eq 2 ] || fail "fzf got $(wc -l < "$tmp/rows") rows, expected 2"
grep -q 'USER: real   first' "$tmp/preview" || fail "preview of row 0 wrong: $(cat "$tmp/preview")"

echo "ok"
