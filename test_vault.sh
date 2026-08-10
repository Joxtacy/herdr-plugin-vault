#!/usr/bin/env bash
# Self-check for vault.sh row parsing. Run: ./test_vault.sh
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/-Users-x-demo"
cat > "$tmp/-Users-x-demo/11111111-2222-3333-4444-555555555555.jsonl" <<'EOF'
{"type":"file-history-snapshot","messageId":"x"}
{"type":"user","cwd":"/Users/x/demo","message":{"content":"<command-name>/init</command-name>"}}
{"type":"user","cwd":"/Users/x/demo","message":{"content":[{"type":"tool_result","content":"noise"}]}}
{"type":"user","cwd":"/Users/x/demo","message":{"content":"real   first\nprompt"}}
EOF

line=$(CLAUDE_PROJECTS_DIR="$tmp" ./vault.sh --list)
[ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || { echo "FAIL: expected 1 row"; exit 1; }

IFS=$'\t' read -r display path id cwd <<<"$line"
[ "$id" = "11111111-2222-3333-4444-555555555555" ] || { echo "FAIL: id=$id"; exit 1; }
[ "$cwd" = "/Users/x/demo" ] || { echo "FAIL: cwd=$cwd"; exit 1; }
[ -f "$path" ] || { echo "FAIL: path=$path"; exit 1; }
case "$display" in
	*"real first prompt"*) ;;
	*) echo "FAIL: synthetic or unsquashed title: $display"; exit 1 ;;
esac
case "$display" in
	*"<command-name>"*) echo "FAIL: slash-command record used as title"; exit 1 ;;
esac

echo "ok"
