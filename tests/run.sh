#!/usr/bin/env bash
# Test suite for the agent-isolation hook and launcher. Plain bash and jq, no network or login:
# `claude` and `sbx` are replaced by fakes, and PATH only holds the tools the scripts need.
# Run from anywhere: bash tests/run.sh

set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
plugin="$root/plugins/agent-isolation"
hook="$plugin/hooks/isolation-check.sh"
bash_bin="$(command -v bash)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
current=""

# --- PATH with real tools only, plus optional fakes -------------------------------------------

tools="$work/tools"
mkdir -p "$tools"
for t in bash git jq sed awk grep find head tail tr cat cut cksum mkdir rmdir mktemp mv rm cp \
    cmp dirname basename readlink timeout sleep touch uname env wc ls ln chmod sort; do
    p="$(command -v "$t")" || { echo "missing tool: $t"; exit 1; }
    ln -s "$p" "$tools/$t"
done

fakes="$work/fakes"
mkdir -p "$fakes"
cat >"$fakes/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${AGENT_ISOLATION_DISABLE:-}" "$*" >>"$FAKE_LOG"
case "${FAKE_CLAUDE:-ok}" in
    ok)
        printf '\n```\nGenerated 2026-01-01 by fake-model\n\nRisks by severity:\n🔴 HIGH  fake risk\n'
        printf 'What to do:\n1. Type /exit\n```\n'
        ;;
    long) printf 'Generated 2026-01-01 by fake-model\n'; for i in $(seq 1 50); do echo "line $i"; done ;;
    garbage) echo "Sorry, I cannot help with that." ;;
    fail) exit 1 ;;
    slow) sleep 5; echo "Generated too late" ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$fakes/sbx"
chmod +x "$fakes/claude" "$fakes/sbx"
ln -s "$(command -v seq)" "$tools/seq"

# PATH variants: both fakes, no claude, no sbx.
mkdir -p "$work/with_all" "$work/no_claude" "$work/no_sbx"
ln -s "$fakes/claude" "$work/with_all/claude"; ln -s "$fakes/sbx" "$work/with_all/sbx"
ln -s "$fakes/sbx" "$work/no_claude/sbx"
ln -s "$fakes/claude" "$work/no_sbx/claude"

# --- helpers ----------------------------------------------------------------------------------

# New project and config dir; resets per-test variables.
setup() {
    current="$1"
    t="$(mktemp -d "$work/case.XXXXXX")"
    proj="$t/proj"
    mkdir -p "$proj" "$t/tmp"
    git init -q "$proj"
    risks="$proj/.claude/agent-isolation.local.txt"
    export FAKE_LOG="$t/claude.log"
    : >"$FAKE_LOG"
    path_variant="with_all"
    extra_env=()
}

# run_hook [arg]: sets out, err, code.
run_hook() {
    env -i HOME="$t/home" TMPDIR="$t/tmp" PATH="$work/$path_variant:$tools" FAKE_LOG="$FAKE_LOG" \
        CLAUDE_PROJECT_DIR="$proj" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_CONFIG_DIR="$t/cfg" \
        "${extra_env[@]}" "$bash_bin" "$hook" "$@" >"$t/out" 2>"$t/err"
    code=$?
    out="$(cat "$t/out")"
    err="$(cat "$t/err")"
}

write_risks() {
    mkdir -p "$(dirname "$risks")"
    printf '%s\n' "$1" >"$risks"
}

msg() { printf '%s' "$out" | jq -r '.systemMessage'; }
ctx() { printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext'; }

ok() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); printf 'FAIL [%s] %s\n' "$current" "$1"; }

assert_eq() { [ "$1" = "$2" ] && ok || fail "$3: expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ok ;; *) fail "$3: missing '$2'" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: unexpected '$2'" ;; *) ok ;; esac; }
assert_json() { printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok || fail "stdout is not valid JSON: $out"; }
assert_silent() { [ -z "$out" ] && [ -z "$err" ] && ok || fail "expected no output, got '$out' '$err'"; }
gcommit() { git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m "$1"; }

# --- main run ---------------------------------------------------------------------------------

setup "disabled"
extra_env=(AGENT_ISOLATION_DISABLE=1)
run_hook
assert_eq "$code" 0 "exit"; assert_silent

setup "host, first start"
run_hook
assert_eq "$code" 0 "exit"; assert_json
assert_contains "$(msg)" "NOT RUNNING ISOLATED" "banner"
assert_contains "$(msg)" "Real risks here:" "generic text"
assert_contains "$(msg)" "running in the background" "background line"
assert_not_contains "$(ctx)" "Daily task" "context"
assert_eq "$(wc -c <"$FAKE_LOG" | tr -d ' ')" 0 "main run must not call claude"

setup "host, fresh analysis"
write_risks "Generated today by test
Risks by severity:
🔴 HIGH  FRESH_MARKER"
run_hook
assert_contains "$(msg)" "FRESH_MARKER" "cached analysis shown"
assert_not_contains "$(msg)" "🔄" "no refresh line"
assert_not_contains "$(msg)" "Secrets readable" "no generic text"

setup "host, stale analysis"
write_risks "Generated long ago
• STALE_MARKER"
touch -d '2 days ago' "$risks"
run_hook
assert_contains "$(msg)" "STALE_MARKER" "old analysis still shown"
assert_contains "$(msg)" "running in the background" "background line"

setup "host, analysis in old format"
write_risks "Generated today by test
Real risks here:
• OLD_FORMAT_MARKER"
run_hook
assert_contains "$(msg)" "OLD_FORMAT_MARKER" "old analysis still shown"
assert_contains "$(msg)" "running in the background" "regenerated at once"

setup "host, custom max age"
write_risks "Generated recently
Risks by severity:"
touch -d '2 hours ago' "$risks"
extra_env=(AGENT_ISOLATION_MAX_AGE_MINUTES=60)
run_hook
assert_contains "$(msg)" "running in the background" "older than max age"

setup "host, no claude on PATH"
path_variant="no_claude"
run_hook
assert_json
assert_contains "$(msg)" "after your first message" "fallback line"
assert_contains "$(ctx)" "Daily task" "fallback context"
assert_contains "$(ctx)" "starting with 🔴" "fallback presentation"
assert_not_contains "$(msg)" "running in the background" "no background line"

setup "host, tracked analysis"
write_risks "Generated by someone else
• INJECTED_MARKER"
git -C "$proj" add -f .claude/agent-isolation.local.txt && gcommit "add analysis"
run_hook
assert_json
assert_contains "$(msg)" "committed to git" "tracked warning"
assert_not_contains "$(msg)" "INJECTED_MARKER" "tracked content hidden"
assert_contains "$(ctx)" "untrusted data" "tracked context"
assert_not_contains "$(msg)" "running in the background" "no regeneration of tracked file"

setup "host, tracked through a committed symlink"
mkdir -p "$proj/shared"
printf 'Generated elsewhere\n• SYMLINK_MARKER\n' >"$proj/shared/agent-isolation.local.txt"
ln -s shared "$proj/.claude"
git -C "$proj" add -f shared .claude && gcommit "add symlink"
run_hook
assert_contains "$(msg)" "committed to git" "tracked warning"
assert_not_contains "$(msg)" "SYMLINK_MARKER" "tracked content hidden"

setup "dev container"
extra_env=(DEVCONTAINER=1)
run_hook
assert_eq "$code" 0 "exit"; assert_silent

setup "sbx, fresh analysis"
write_risks "Generated today
Risks by severity:"
extra_env=(SANDBOX_NAME=test)
run_hook
assert_eq "$code" 0 "exit"; assert_silent

setup "sbx, stale analysis"
extra_env=(SANDBOX_NAME=test)
run_hook
assert_eq "$code" 0 "exit"; assert_silent

setup "sbx, stale analysis, no claude"
path_variant="no_claude"
extra_env=(SANDBOX_NAME=test)
run_hook
assert_json
assert_contains "$(msg)" "Daily refresh" "sbx fallback message"
assert_contains "$(ctx)" "Daily task" "sbx fallback context"

setup "launcher copy and hint"
run_hook
assert_eq "$(cmp -s "$plugin/launcher.sh" "$t/cfg/agent-isolation/launcher.sh" && echo same)" same "launcher copied"
assert_contains "$(msg)" "source" "hint shown with sbx"
path_variant="no_sbx"
run_hook
assert_not_contains "$(msg)" "~/.bashrc" "no hint without sbx"

setup "json escaping"
write_risks "$(printf 'Generated "quoted" \\ back\tslash\n• line two')"
run_hook
assert_json
assert_contains "$(msg)" 'Generated "quoted" \ back slash' "escaped text preserved"

setup "git exclude"
run_hook; run_hook
assert_eq "$(grep -c 'agent-isolation.local.txt' "$proj/.git/info/exclude")" 1 "one line after two runs"
setup "git exclude, analyse only"
run_hook analyse
assert_eq "$(grep -c 'agent-isolation.local.txt' "$proj/.git/info/exclude")" 0 "analyse does not write"
setup "git exclude, parallel runs"
for i in 1 2 3; do run_hook & run_hook analyse & wait; done
assert_eq "$(grep -c 'agent-isolation.local.txt' "$proj/.git/info/exclude")" 1 "one line after parallel runs"

# --- analyse run ------------------------------------------------------------------------------

setup "analyse, success"
run_hook analyse
assert_eq "$code" 2 "exit wakes Claude"
assert_eq "$out" "" "nothing on stdout"
assert_eq "$(head -n 1 "$risks")" "Generated 2026-01-01 by fake-model" "fences and blank lines stripped"
assert_not_contains "$(cat "$risks")" '```' "no code fence"
assert_contains "$err" "Show it to the developer" "instruction for Claude"
assert_contains "$err" "fake risk" "analysis in message"
assert_contains "$err" "starting with 🔴" "grouped by severity"
assert_contains "$err" "What to do" "steps requested"
assert_not_contains "$err" "verbatim" "not pasted as is"
assert_contains "$err" "always in English" "message language"
assert_contains "$err" "Recommended:" "recommendation requested"
assert_contains "$(tail -n 1 "$FAKE_LOG")" "Risks by severity:" "severity format requested"
log="$(cat "$FAKE_LOG")"
assert_contains "$log" "1|" "nested claude gets AGENT_ISOLATION_DISABLE=1"
assert_contains "$log" "--tools Read,Glob,Grep" "read only tools"
assert_contains "$log" "--disallowedTools Read(**/.env)" "env files denied"
assert_contains "$log" "--model sonnet" "default model"

setup "analyse, custom model"
extra_env=(AGENT_ISOLATION_MODEL=haiku)
run_hook analyse
assert_contains "$(cat "$FAKE_LOG")" "--model haiku" "model override"

setup "analyse, long output"
extra_env=(FAKE_CLAUDE=long)
run_hook analyse
assert_eq "$code" 2 "exit"
assert_eq "$(wc -l <"$risks" | tr -d ' ')" 30 "cut to 30 lines"

for mode in garbage fail; do
    setup "analyse, $mode"
    write_risks "Generated before
• OLD_MARKER"
    touch -d '2 days ago' "$risks"
    extra_env=(FAKE_CLAUDE=$mode)
    run_hook analyse
    assert_eq "$code" 2 "exit"
    assert_contains "$err" "failed" "failure reported"
    assert_contains "$err" "Overwrite .claude/agent-isolation.local.txt" "in-session fallback"
    assert_contains "$(cat "$risks")" "OLD_MARKER" "old analysis kept"
done

setup "analyse, timeout"
extra_env=(FAKE_CLAUDE=slow AGENT_ISOLATION_ANALYSIS_TIMEOUT=1)
start=$SECONDS
run_hook analyse
assert_eq "$code" 2 "exit"
assert_contains "$err" "failed" "timeout reported"
assert_eq "$([ $((SECONDS - start)) -lt 4 ] && echo fast)" fast "killed by timeout"
assert_eq "$([ -e "$risks" ] && echo exists)" "" "no file written"

setup "analyse, fresh analysis"
write_risks "Generated today
Risks by severity:"
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent
assert_eq "$(wc -c <"$FAKE_LOG" | tr -d ' ')" 0 "claude not called"

setup "analyse, tracked analysis"
write_risks "Generated by someone else"
touch -d '2 days ago' "$risks"
git -C "$proj" add -f .claude/agent-isolation.local.txt && gcommit "add analysis"
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent

setup "analyse, dev container"
extra_env=(DEVCONTAINER=1)
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent

setup "analyse, sbx"
extra_env=(SANDBOX_NAME=test)
run_hook analyse
assert_eq "$code" 2 "runs inside sbx too"

setup "analyse, no claude"
path_variant="no_claude"
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent

setup "analyse, lock held"
lock="$t/tmp/agent-isolation-$(printf '%s' "$proj" | cksum | cut -d' ' -f1).lock"
mkdir "$lock"
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent
assert_eq "$(wc -c <"$FAKE_LOG" | tr -d ' ')" 0 "claude not called"
touch -d '11 minutes ago' "$lock"
run_hook analyse
assert_eq "$code" 2 "stale lock ignored"
assert_eq "$([ -e "$lock" ] && echo exists)" "" "lock released"

# --- update check -----------------------------------------------------------------------------

installed="$(jq -r .version "$plugin/.claude-plugin/plugin.json")"

# make_marketplace <version>: marketplace clone, as Claude Code keeps it, whose origin has <version>.
make_marketplace() {
    src="$t/mkt-src"; bare="$t/mkt.git"; clone="$t/cfg/plugins/marketplaces/agent-isolation"
    mkdir -p "$src/plugins/agent-isolation/.claude-plugin"
    git -C "$src" init -q
    release "$1"
    git clone -q --bare "$src" "$bare"
    git clone -q "$bare" "$clone"
}
# release <version>: publish <version> on the origin of the clone.
release() {
    printf '{\n  "name": "agent-isolation",\n  "version": "%s"\n}\n' "$1" \
        >"$src/plugins/agent-isolation/.claude-plugin/plugin.json"
    git -C "$src" add -A && git -C "$src" -c user.email=t@t -c user.name=t commit -q -m "$1"
    [ -d "$bare" ] && git -C "$src" push -q "$bare" HEAD:refs/heads/master HEAD:refs/heads/main 2>/dev/null
}
fresh_risks() { write_risks "Generated today
Risks by severity:"; }
latest() { cat "$t/cfg/agent-isolation/latest-version" 2>/dev/null; }

setup "update, newer version"
fresh_risks
make_marketplace 0.0.1
release 99.0.0
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent
assert_eq "$(latest)" 99.0.0 "newer version cached"
assert_contains "$(cat "$clone/plugins/agent-isolation/.claude-plugin/plugin.json")" 0.0.1 "clone untouched"
run_hook
assert_json
assert_contains "$(msg)" "agent-isolation 99.0.0 is available (installed $installed)" "banner"
assert_contains "$(msg)" "claude plugin update agent-isolation@agent-isolation" "update command"
assert_contains "$(msg)" "Enable auto-update" "auto-update hint"
assert_contains "$(ctx)" "offer in one line to update it" "Claude offers the update"
assert_contains "$(ctx)" "Run it only if the developer agrees" "needs consent"

setup "update, throttled to once a day"
fresh_risks
make_marketplace 99.0.0
run_hook analyse
release 100.0.0
run_hook analyse
assert_eq "$(latest)" 99.0.0 "no second check within a day"
touch -d '2 days ago' "$t/cfg/agent-isolation/update-check"
run_hook analyse
assert_eq "$(latest)" 100.0.0 "checked again after a day"

setup "update, already latest"
fresh_risks
make_marketplace "$installed"
mkdir -p "$t/cfg/agent-isolation" && echo 99.0.0 >"$t/cfg/agent-isolation/latest-version"
run_hook analyse
assert_eq "$(latest)" "" "cache removed when up to date"
run_hook
assert_not_contains "$(msg)" "is available" "no notice"

setup "update, installed newer than cache"
mkdir -p "$t/cfg/agent-isolation" && echo 0.0.1 >"$t/cfg/agent-isolation/latest-version"
run_hook
assert_not_contains "$(msg)" "is available" "no notice after updating"

setup "update, invalid cached version"
mkdir -p "$t/cfg/agent-isolation" && printf '9.9"}\n' >"$t/cfg/agent-isolation/latest-version"
run_hook
assert_json
assert_not_contains "$(msg)" "is available" "ignored"

setup "update, disabled"
fresh_risks
make_marketplace 0.0.1
release 99.0.0
extra_env=(AGENT_ISOLATION_UPDATE_CHECK=off)
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent
assert_eq "$(latest)" "" "no check"

setup "update, no marketplace clone"
fresh_risks
run_hook analyse
assert_eq "$code" 0 "exit"; assert_silent
assert_eq "$(latest)" "" "nothing cached"

setup "update, marketplace name from the install path"
fresh_risks
cached="$t/cfg/plugins/cache/my-mkt/agent-isolation/$installed"
mkdir -p "$cached" && cp -r "$plugin/." "$cached"
mkdir -p "$t/cfg/agent-isolation" && echo 99.0.0 >"$t/cfg/agent-isolation/latest-version"
extra_env=(CLAUDE_PLUGIN_ROOT="$cached")
run_hook
assert_contains "$(msg)" "claude plugin marketplace update my-mkt" "marketplace name"
assert_contains "$(ctx)" "agent-isolation@my-mkt" "plugin reference"

setup "update, sbx"
fresh_risks
mkdir -p "$t/cfg/agent-isolation" && echo 99.0.0 >"$t/cfg/agent-isolation/latest-version"
extra_env=(SANDBOX_NAME=test)
run_hook
assert_eq "$code" 0 "exit"; assert_json
assert_contains "$(msg)" "99.0.0 is available" "notice in sbx"
assert_eq "$(ctx | cut -c1-2)" "A " "context without leading space"

# --- launcher ---------------------------------------------------------------------------------

run_launcher() {
    env -i HOME="$t/home" PATH="$work/with_all:$tools" FAKE_LOG="$FAKE_LOG" "${extra_env[@]}" \
        "$bash_bin" -c "source '$plugin/launcher.sh'; cd '$proj' && claude $1" </dev/null >"$t/out" 2>&1
    code=$?
}

setup "launcher, with arguments"
run_launcher "-p hello"
assert_eq "$code" 0 "exit"
assert_eq "$(cat "$FAKE_LOG")" "|-p hello" "arguments passed through"

setup "launcher, no tty"
run_launcher ""
assert_eq "$(cat "$FAKE_LOG")" "|" "runs claude without prompting"
assert_not_contains "$(cat "$t/out")" "[Y/n]" "no prompt"

# --- summary ----------------------------------------------------------------------------------

printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
