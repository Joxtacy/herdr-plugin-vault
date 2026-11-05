#!/usr/bin/env bash
# Self-check for vault.sh. Run: ./test_vault.sh
# Covers row parsing, ordering, the project filter, resume/fork handoff, and picker
# startup, with fzf and herdr stubbed.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
field() { printf '%s\n' "$1" | cut -f"$2"; }
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

projects="$tmp/projects"
work="$tmp/work"
mkdir -p "$projects/a" "$projects/b" "$projects/c" "$work/demo/sub" "$work/other"
new="$projects/a/11111111-2222-3333-4444-555555555555.jsonl"
sub="$projects/b/22222222-2222-3333-4444-555555555555.jsonl"
old="$projects/c/66666666-7777-8888-9999-000000000000.jsonl"

# Newest: has Claude's own title, a branch, and noise records before the real prompt.
cat > "$new" <<EOF
{"type":"file-history-snapshot","messageId":"x"}
{"type":"user","cwd":"$work/demo","gitBranch":"feat/login","message":{"content":"<command-name>/init</command-name>"}}
{"type":"user","cwd":"$work/demo","gitBranch":"feat/login","message":{"content":[{"type":"tool_result","content":"noise"}]}}
{"type":"user","cwd":"$work/demo","gitBranch":"feat/login","message":{"content":"real   first\nprompt"}}
{"type":"ai-title","aiTitle":"Login form   validation","sessionId":"x"}
EOF
# Middle: a subdirectory of demo, no title record, detached HEAD.
cat > "$sub" <<EOF
{"type":"user","cwd":"$work/demo/sub","gitBranch":"HEAD","message":{"content":"sub prompt"}}
EOF
# Oldest: its folder is gone.
cat > "$old" <<EOF
{"type":"user","cwd":"$work/deleted","message":{"content":"older prompt"}}
EOF
touch -t 202501010000 "$sub"
touch -t 202001010000 "$old"

# --list: rows newest first, nothing on stderr.
out=$(CLAUDE_PROJECTS_DIR="$projects" ./vault.sh --list 2>"$tmp/err")
[ ! -s "$tmp/err" ] || fail "--list wrote to stderr: $(cat "$tmp/err")"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 3 ] || fail "expected 3 rows, got: $out"

r=$(printf '%s\n' "$out" | sed -n 1p)
[ "$(field "$r" 2)" = "$new" ] || fail "path=$(field "$r" 2)"
[ "$(field "$r" 3)" = "11111111-2222-3333-4444-555555555555" ] || fail "newest row first, got id=$(field "$r" 3)"
[ "$(field "$r" 4)" = "$work/demo" ] || fail "cwd=$(field "$r" 4)"
[ "$(field "$r" 5)" = "Login form validation" ] || fail "ai-title not used: $(field "$r" 5)"
[ "$(field "$r" 6)" = "feat/login" ] || fail "branch=$(field "$r" 6)"
display=$(field "$r" 1 | strip)
[ "$display" = "0m   demo                      Login form validation [feat/login]" ] ||
	fail "bad display: $display"

r=$(printf '%s\n' "$out" | sed -n 2p)
[ "$(field "$r" 5)" = "sub prompt" ] || fail "first prompt is the fallback title, got: $(field "$r" 5)"
[ -z "$(field "$r" 6)" ] || fail "HEAD should not show as a branch: $(field "$r" 6)"
[[ "$(field "$r" 1 | strip)" =~ ^[0-9]+d\ *sub\ +sub\ prompt$ ]] || fail "bad display: $(field "$r" 1 | strip)"

r=$(printf '%s\n' "$out" | sed -n 3p)
[ "$(field "$r" 3)" = "66666666-7777-8888-9999-000000000000" ] || fail "oldest row last, got id=$(field "$r" 3)"
[[ "$(field "$r" 1 | strip)" == *"older prompt (folder gone)" ]] || fail "gone folder not marked: $(field "$r" 1 | strip)"
case "$(field "$r" 1)" in $'\033[2m'*) ;; *) fail "gone row not dimmed" ;; esac

# --list DIR: only sessions in DIR or below. demo2 must not match demo by prefix.
mkdir -p "$work/demo2"
filtered=$(CLAUDE_PROJECTS_DIR="$projects" ./vault.sh --list "$work/demo" | cut -f3 | tr '\n' ' ')
[ "$filtered" = "11111111-2222-3333-4444-555555555555 22222222-2222-3333-4444-555555555555 " ] ||
	fail "--list DIR kept the wrong rows: $filtered"
[ -z "$(CLAUDE_PROJECTS_DIR="$projects" ./vault.sh --list "$work/demo2")" ] || fail "--list matched a sibling by prefix"

# --cached: filters the picker's saved rows without rescanning once the scan is done,
# and falls back to a real scan while it is not.
CLAUDE_PROJECTS_DIR="$projects" ./vault.sh --list > "$tmp/cache"
mkdir -p "$tmp/empty"
[ "$(CLAUDE_PROJECTS_DIR="$tmp/empty" ./vault.sh --cached "$tmp/cache" "$work/demo" | wc -l | tr -d ' ')" -eq 0 ] ||
	fail "--cached used a partial cache instead of scanning"
: > "$tmp/cache.done"
[ "$(CLAUDE_PROJECTS_DIR="$tmp/empty" ./vault.sh --cached "$tmp/cache" "$work/demo" | wc -l | tr -d ' ')" -eq 2 ] ||
	fail "--cached DIR did not filter the saved rows"
[ "$(CLAUDE_PROJECTS_DIR="$tmp/empty" ./vault.sh --cached "$tmp/cache" | wc -l | tr -d ' ')" -eq 3 ] ||
	fail "--cached without DIR did not return every saved row"

# --list on an empty projects dir: no rows, clean exit.
out=$(CLAUDE_PROJECTS_DIR="$tmp/empty" ./vault.sh --list 2>"$tmp/err") || fail "--list on empty dir exited non-zero"
[ -z "$out" ] || fail "--list on empty dir printed: $out"
[ ! -s "$tmp/err" ] || fail "--list on empty dir wrote to stderr: $(cat "$tmp/err")"

# Stubs. herdr logs its calls and answers the few queries vault makes. The fzf stub
# records its args and the rows it got, then runs the preview for row 1 the way fzf
# would: hidden fields substituted for {2}..{6}, each one shell-quoted.
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_OUT/herdr.log"
case "$1 $2" in
	"pane list") printf '{"result":{"panes":[{"pane_id":"w1:p1","focused":true,"cwd":"%s"}]}}\n' "${STUB_FOCUSED:-}" ;;
	"agent list") printf '{"result":{"agents":[{"pane_id":"w1:p5","agent_session":{"value":"%s"}}]}}\n' "${STUB_RUNNING:-}" ;;
	"tab create") echo '{"result":{"root_pane":{"pane_id":"w1:p9"}}}' ;;
esac
EOF
cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_OUT/fzf.args"
cat > "$STUB_OUT/rows"
IFS=$'\t' read -r -a f < "$STUB_OUT/rows"
for arg; do
	case "$arg" in --preview=*)
		cmd=${arg#--preview=}
		for i in 2 3 4 5 6; do cmd=${cmd//\{$i\}/$(printf '%q' "${f[$((i - 1))]}")}; done
		bash -c "$cmd" > "$STUB_OUT/preview" ;;
	esac
done
EOF
chmod +x "$tmp/bin/herdr" "$tmp/bin/fzf"
export STUB_OUT=$tmp HERDR_PLUGIN_STATE_DIR="$tmp/state"
stubbed() { PATH="$tmp/bin:$PATH" CLAUDE_PROJECTS_DIR="$projects" "$@"; }

# Picker startup, opened from a pane in demo/sub: the project filter targets demo/sub.
STUB_FOCUSED="$work/demo/sub" stubbed ./vault.sh </dev/null >/dev/null 2>"$tmp/err" ||
	fail "picker exited non-zero: $(cat "$tmp/err")"
[ ! -s "$tmp/err" ] || fail "picker wrote to stderr: $(cat "$tmp/err")"
[ "$(wc -l < "$tmp/rows" | tr -d ' ')" -eq 3 ] || fail "fzf got $(wc -l < "$tmp/rows") rows, expected 3"
grep -q 'Login form validation' "$tmp/preview" || fail "preview header missing title: $(cat "$tmp/preview")"
grep -q 'USER: real   first' "$tmp/preview" || fail "preview missing conversation: $(cat "$tmp/preview")"
grep -q -- "--cached .* $(printf '%q' "$work/demo/sub")\$" "$tmp/fzf.args" || fail "ctrl-p not bound to the focused pane's dir: $(cat "$tmp/fzf.args")"

# With no focused pane, the project keys are left out rather than bound to nothing.
STUB_FOCUSED="" stubbed ./vault.sh </dev/null >/dev/null 2>&1 || fail "picker failed with no focused pane"
! grep -q 'ctrl-p' "$tmp/fzf.args" || fail "ctrl-p bound with no focused pane"

# Resume: a session already running is focused, not started again.
: > "$tmp/herdr.log"
STUB_RUNNING=11111111-2222-3333-4444-555555555555 stubbed ./vault.sh --resume 11111111-2222-3333-4444-555555555555 "$work/demo" >/dev/null
grep -q '^agent focus w1:p5$' "$tmp/herdr.log" || fail "running session not focused: $(cat "$tmp/herdr.log")"
! grep -q '^tab create' "$tmp/herdr.log" || fail "running session was started twice"

# Fork: always a new tab, even while the original runs, and claude gets --fork-session.
: > "$tmp/herdr.log"
STUB_RUNNING=11111111-2222-3333-4444-555555555555 stubbed ./vault.sh --resume 11111111-2222-3333-4444-555555555555 "$work/demo" --fork >/dev/null
grep -q '^tab create' "$tmp/herdr.log" || fail "fork did not open a tab: $(cat "$tmp/herdr.log")"
stubbed ./vault.sh --launch
grep -q -- '^agent start demo --kind claude --pane w1:p9 -- --resume 11111111-2222-3333-4444-555555555555 --fork-session$' "$tmp/herdr.log" ||
	fail "fork launch wrong: $(cat "$tmp/herdr.log")"

# Plain resume launches without --fork-session.
: > "$tmp/herdr.log"
stubbed ./vault.sh --resume 22222222-2222-3333-4444-555555555555 "$work/demo/sub" >/dev/null
stubbed ./vault.sh --launch
grep -q -- '^agent start sub --kind claude --pane w1:p9 -- --resume 22222222-2222-3333-4444-555555555555$' "$tmp/herdr.log" ||
	fail "resume launch wrong: $(cat "$tmp/herdr.log")"

echo "ok"
