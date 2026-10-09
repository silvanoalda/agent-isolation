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
    cmp dirname basename readlink timeout sleep touch uname env wc ls ln chmod sort date; do
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
cat >"$fakes/sbx" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_SBX_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_SBX_LOG"
case "$*" in
    "run claude -d") printf 'progress line\n%s\n' "${FAKE_SBX_ID-4d390e74-13f0}" ;;
    "ls --json")
        printf '{"sandboxes":[{"name":"claude-other","id":"0000"},{"name":"claude-proj","id":"%s"}]}\n' \
            "${FAKE_SBX_ID-4d390e74-13f0}" ;;
    exec*) exit "${FAKE_SBX_EXEC:-0}" ;;
esac
exit 0
EOF
chmod +x "$fakes/claude" "$fakes/sbx"
ln -s "$(command -v seq)" "$tools/seq"

# PATH variants: both fakes, no claude, no sbx.
mkdir -p "$work/with_all" "$work/no_claude" "$work/no_sbx"
ln -s "$fakes/claude" "$work/with_all/claude"; ln -s "$fakes/sbx" "$work/with_all/sbx"
ln -s "$fakes/sbx" "$work/no_claude/sbx"
ln -s "$fakes/claude" "$work/no_sbx/claude"
mkdir -p "$work/mac_no_sbx"
ln -s "$fakes/claude" "$work/mac_no_sbx/claude"
printf '#!/usr/bin/env bash\ncase "$1" in -m) echo "${FAKE_ARCH:-arm64}" ;; *) echo Darwin ;; esac\n' >"$work/mac_no_sbx/uname"
chmod +x "$work/mac_no_sbx/uname"

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
    # System files the hook checks for sbx: a usable KVM device on Ubuntu by default.
    sys="$t/sys"
    mkdir -p "$sys/dev" "$sys/etc"
    : >"$sys/dev/kvm"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$sys/etc/os-release"
}

# run_hook [arg]: sets out, err, code.
run_hook() {
    env -i HOME="$t/home" TMPDIR="$t/tmp" PATH="$work/$path_variant:$tools" FAKE_LOG="$FAKE_LOG" \
        CLAUDE_PROJECT_DIR="$proj" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_CONFIG_DIR="$t/cfg" \
        AGENT_ISOLATION_SYSROOT="$sys" "${extra_env[@]}" "$bash_bin" "$hook" "$@" >"$t/out" 2>"$t/err"
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
assert_not_contains "$(msg)" "Real risks here:" "no generic text while the analysis runs"
assert_contains "$(msg)" "running in the background" "background line"
assert_not_contains "$(ctx)" "Daily task" "context"
assert_eq "$(wc -c <"$FAKE_LOG" | tr -d ' ')" 0 "main run must not call claude"

setup "host, start command on its own line"
run_hook
assert_contains "$(msg)" "$(printf '\n        ▶  sbx run claude\n')" "command alone on an indented line"

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
assert_not_contains "$(msg)" "Real risks here:" "no generic text before the in-session refresh"

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
assert_contains "$(msg)" "Real risks here:" "generic text when no analysis comes"

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

sources() { grep -c 'agent-isolation/launcher.sh' "$1" 2>/dev/null; }

setup "launcher added to existing shell rc files"
mkdir -p "$t/home"; echo "# mine" >"$t/home/.bashrc"; echo "# mine" >"$t/home/.zshrc"
run_hook
assert_eq "$(cmp -s "$plugin/launcher.sh" "$t/cfg/agent-isolation/launcher.sh" && echo same)" same "launcher copied"
assert_eq "$(sources "$t/home/.bashrc")" 1 "added to .bashrc"
assert_eq "$(sources "$t/home/.zshrc")" 1 "added to .zshrc"
assert_contains "$(head -n 1 "$t/home/.bashrc")" "# mine" "existing content kept"
assert_contains "$(msg)" "added to ~/.bashrc ~/.zshrc" "change announced"
assert_contains "$(msg)" "new terminal" "says when it takes effect"
assert_eq "$("$bash_bin" -c "HOME='$t/home'; source '$t/home/.bashrc'; type -t sbx")" function "line loads the launcher"
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 1 "added once"
assert_not_contains "$(msg)" "~/.bashrc" "no message once added"

setup "launcher, rc file for the login shell created"
mkdir -p "$t/home"
extra_env=(SHELL=/bin/zsh)
run_hook
assert_eq "$(sources "$t/home/.zshrc")" 1 "created .zshrc"
assert_eq "$([ -e "$t/home/.bashrc" ] && echo yes)" "" "no .bashrc created"

setup "launcher line removed by the user"
mkdir -p "$t/home"; : >"$t/home/.bashrc"
run_hook
printf '# mine\n' >"$t/home/.bashrc"
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 1 "added back"
assert_contains "$(msg)" "added to ~/.bashrc" "re-add announced"

setup "launcher, no shell rc file known"
mkdir -p "$t/home"
extra_env=(SHELL=/usr/bin/fish)
run_hook
assert_contains "$(msg)" "source" "manual hint when there is no rc file to edit"

setup "launcher, rc file not writable"
mkdir -p "$t/home"; echo "# mine" >"$t/home/.bashrc"; chmod 444 "$t/home/.bashrc"
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 0 "unchanged"
assert_not_contains "$(msg)" "Launcher added" "no false claim"
assert_contains "$(msg)" "source" "manual hint instead"
chmod 644 "$t/home/.bashrc"

setup "launcher, old one-time marker removed"
mkdir -p "$t/cfg/agent-isolation" "$t/home"; : >"$t/cfg/agent-isolation/rc-added"
run_hook
assert_eq "$([ -e "$t/cfg/agent-isolation/rc-added" ] && echo left)" "" "marker cleaned up"

setup "launcher already sourced by the user"
mkdir -p "$t/home"; echo 'source ~/.claude/agent-isolation/launcher.sh' >"$t/home/.bashrc"
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 1 "not duplicated"
assert_not_contains "$(msg)" "~/.bashrc" "nothing to say"

setup "launcher not added without sbx or when off"
mkdir -p "$t/home"; : >"$t/home/.bashrc"
path_variant="no_sbx"
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 0 "not added without sbx"
assert_not_contains "$(msg)" "~/.bashrc" "no hint without sbx"
path_variant="with_all"
extra_env=(AGENT_ISOLATION_LAUNCHER=off)
run_hook
assert_eq "$(sources "$t/home/.bashrc")" 0 "not added when off"

setup "sbx installed, KVM usable"
run_hook
assert_not_contains "$(msg)" "not installed" "no install guide"
assert_not_contains "$(msg)" "KVM" "no KVM notice"

setup "sbx missing on Ubuntu"
path_variant="no_sbx"
run_hook
assert_json
assert_contains "$(msg)" "sbx is not installed" "install guide"
assert_contains "$(msg)" "REPO_ONLY=1 sh" "Ubuntu repository step"
assert_contains "$(msg)" "sudo apt install docker-sbx" "Ubuntu package step"
assert_contains "$(msg)" "sbx login" "login step"
assert_contains "$(msg)" "no Docker" "says Docker is not needed"
assert_contains "$(msg)" "Install sbx" "exit line points to the install"
assert_contains "$(ctx)" "sbx is not installed" "context"
assert_contains "$(ctx)" "with !" "Claude lets the developer run sudo"

setup "sbx missing on an Ubuntu derivative"
path_variant="no_sbx"
printf 'ID=pop\nID_LIKE="ubuntu debian"\n' >"$sys/etc/os-release"
run_hook
assert_contains "$(msg)" "sudo apt install docker-sbx" "Ubuntu steps on derivatives"
assert_contains "$(msg)" "not officially supported" "derivative caveat"

setup "sbx missing on another Linux"
path_variant="no_sbx"
printf 'ID=fedora\n' >"$sys/etc/os-release"
run_hook
assert_contains "$(msg)" "sbx-releases/releases" "release packages"
assert_not_contains "$(msg)" "apt install" "no apt elsewhere"

setup "KVM missing"
rm "$sys/dev/kvm"
run_hook
assert_json
assert_contains "$(msg)" "KVM is not available" "kvm missing notice"
assert_contains "$(msg)" "lsmod | grep kvm" "kvm check command"

setup "KVM not accessible"
chmod 000 "$sys/dev/kvm"
run_hook
assert_contains "$(msg)" "sudo usermod -aG kvm" "kvm group step"
chmod 600 "$sys/dev/kvm"

setup "sbx missing on macOS"
path_variant="mac_no_sbx"
run_hook
assert_json
assert_contains "$(msg)" "brew install docker/tap/sbx" "Homebrew step"
assert_not_contains "$(msg)" "KVM" "no KVM on macOS"

setup "sbx missing on an Intel Mac"
path_variant="mac_no_sbx"
extra_env=(FAKE_ARCH=x86_64)
run_hook
assert_contains "$(msg)" "Apple silicon" "unsupported Mac explained"
assert_not_contains "$(msg)" "brew install" "no install steps"
assert_not_contains "$(msg)" "▶  sbx run claude" "no sbx command where it cannot run"

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
assert_contains "$err" "fenced code block" "start command in its own code block"
assert_contains "$err" "not a shell command" "no bash block for /sandbox or a web page"
assert_contains "$err" "**▶ Run:**" "start command highlighted"
assert_contains "$(cat "$FAKE_LOG")" "on its own line" "analysis puts the start command on its own line"
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

# run_sbx_launcher args: sbx through the launcher; sets code, sbx_log.
run_sbx_launcher() {
    env -i HOME="$t/home" PATH="$work/with_all:$tools" FAKE_SBX_LOG="$t/sbx.log" \
        CLAUDE_CONFIG_DIR="$t/cfg" "${extra_env[@]}" \
        "$bash_bin" -c "source '$plugin/launcher.sh'; cd '$proj' && sbx $1" </dev/null >"$t/out" 2>&1
    code=$?
    sbx_log="$(grep -v '^ ' "$t/sbx.log" 2>/dev/null | cut -d' ' -f1-3)"
}

setup "sbx launcher, plugin installed once per sandbox"
run_sbx_launcher "run claude"
assert_eq "$code" 0 "exit"
assert_eq "$sbx_log" "$(printf 'run claude -d\nls --json\nexec claude-proj --\nrun claude')" "detached start, install, attach"
assert_contains "$(cat "$t/out")" "Installing the agent-isolation plugin in sandbox claude-proj" "install shown"
assert_eq "$(ls "$t/cfg/agent-isolation/sandboxes")" "4d390e74-13f0" "marker per sandbox id"
rm -f "$t/sbx.log"
run_sbx_launcher "run claude"
assert_eq "$sbx_log" "$(printf 'run claude -d\nrun claude')" "no install the second time"

setup "sbx launcher, recreated sandbox"
run_sbx_launcher "run claude"
rm -f "$t/sbx.log"
extra_env=(FAKE_SBX_ID=9f00aa11-2222)
run_sbx_launcher "run claude"
assert_contains "$sbx_log" "exec claude-proj" "new id installs again"

setup "sbx launcher, install fails"
extra_env=(FAKE_SBX_EXEC=1)
run_sbx_launcher "run claude"
assert_contains "$(cat "$t/out")" "Could not install it" "failure shown"
assert_contains "$sbx_log" "$(printf 'exec claude-proj --\nrun claude')" "still attaches"
assert_eq "$(ls "$t/cfg/agent-isolation/sandboxes" 2>/dev/null)" "" "no marker"

setup "sbx launcher, unexpected detached output"
extra_env=(FAKE_SBX_ID="not an id")
run_sbx_launcher "run claude"
assert_eq "$sbx_log" "$(printf 'run claude -d\nrun claude')" "skips the install, attaches"

setup "sbx launcher, other commands and opt-out"
run_sbx_launcher "ls -q"
assert_eq "$sbx_log" "ls -q" "other commands unchanged"
rm -f "$t/sbx.log"
run_sbx_launcher "run claude --name x"
assert_eq "$sbx_log" "run claude --name" "run with more arguments unchanged"
rm -f "$t/sbx.log"
extra_env=(AGENT_ISOLATION_LAUNCHER=off)
run_sbx_launcher "run claude"
assert_eq "$sbx_log" "run claude" "off skips the install"
rm -f "$t/sbx.log"
extra_env=(SANDBOX_NAME=test)
run_sbx_launcher "run claude"
assert_eq "$sbx_log" "run claude" "inside sbx unchanged"

# --- status line segment -----------------------------------------------------------------------

# run_segment json: the segment as a status line command would call it; sets out.
run_segment() {
    out="$(printf '%s' "$1" | env -i HOME="$t/home" TMPDIR="$t/tmp" PATH="$tools" \
        "$bash_bin" "$plugin/statusline.sh")"
}
lock_of() { printf '%s' "$t/tmp/agent-isolation-$(printf '%s' "$1" | cksum | cut -d' ' -f1).lock"; }

setup "segment, no analysis running"
run_segment "{\"workspace\":{\"project_dir\":\"$proj\",\"current_dir\":\"$proj\"}}"
assert_eq "$out" "" "prints nothing"

setup "segment, analysis running"
mkdir "$(lock_of "$proj")"
run_segment "{\"workspace\":{\"project_dir\":\"$proj\",\"current_dir\":\"$proj/sub\"}}"
assert_contains "$out" "Analysing isolation risks" "label"
assert_eq "$(printf '%s' "$out" | grep -cE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]')" 1 "spinner frame"
run_segment "{\"workspace\":{\"current_dir\":\"$proj\"}}"
assert_contains "$out" "Analysing" "falls back to current_dir"
run_segment "{\"workspace\":{\"project_dir\":\"$proj/other\"}}"
assert_eq "$out" "" "other project: nothing"

setup "segment, stale lock"
mkdir "$(lock_of "$proj")"; touch -d '20 minutes ago' "$(lock_of "$proj")"
run_segment "{\"workspace\":{\"project_dir\":\"$proj\"}}"
assert_eq "$out" "" "stale lock ignored"

setup "segment, lock matches the analyse run"
extra_env=(FAKE_CLAUDE=slow AGENT_ISOLATION_ANALYSIS_TIMEOUT=3)
run_hook analyse &
for _ in $(seq 1 50); do [ -d "$(lock_of "$proj")" ] && break; sleep 0.1; done
run_segment "{\"workspace\":{\"project_dir\":\"$proj\"}}"
assert_contains "$out" "Analysing" "shown while the analyse run works"
wait
run_segment "{\"workspace\":{\"project_dir\":\"$proj\"}}"
assert_eq "$out" "" "gone when it ends"

setup "segment copied for the status line"
run_hook
assert_eq "$(cmp -s "$plugin/statusline.sh" "$t/cfg/agent-isolation/statusline.sh" && echo same)" same "statusline copied"

# --- summary ----------------------------------------------------------------------------------

printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
