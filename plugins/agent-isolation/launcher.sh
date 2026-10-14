# agent-isolation launcher: offers to start Claude Code inside the sbx sandbox, and installs the
# plugin in that sandbox, whose ~/.claude is separate from the host one.
#
# The plugin keeps a stable copy at ~/.claude/agent-isolation/launcher.sh.
# Source it once from ~/.bashrc or ~/.zshrc on the host:
#   source ~/.claude/agent-isolation/launcher.sh
#
# When `claude` is run without arguments on the host inside a git repository,
# it asks for confirmation and runs `sbx run claude` from the repository root.
# With arguments (claude -p, claude plugin ..., claude --resume) or outside
# a repository it runs Claude Code unchanged.
# `sbx run claude` (from this launcher or typed directly, without further arguments) first
# installs the plugin in the sandbox when it is not there yet, and DDEV when the project has a
# .ddev directory and the sandbox lacks it; other sbx commands are unchanged.
# Set AGENT_ISOLATION_LAUNCHER=off to skip both.

# Shells keep the functions they sourced at startup, so a terminal opened before a plugin update
# would run the old launcher. Each call reloads the stable copy when its content changed.
_agent_isolation_launcher="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-isolation/launcher.sh"
_agent_isolation_launcher_sum="$( { cksum <"$_agent_isolation_launcher"; } 2>/dev/null)"

# Returns 0 after loading a changed copy, so the caller runs the new definition instead.
_agent_isolation_reload() {
    local sum
    [ -f "$_agent_isolation_launcher" ] || return 1
    sum="$(cksum <"$_agent_isolation_launcher" 2>/dev/null)"
    [ -n "$sum" ] && [ "$sum" != "$_agent_isolation_launcher_sum" ] || return 1
    . "$_agent_isolation_launcher"
}

# Starts the sandbox of the current directory detached (creating it if needed), installs the
# plugin once per sandbox and, for DDEV projects, DDEV when the sandbox lacks it, then attaches.
# Any failure only skips the install, with a warning.
_agent_isolation_sbx_claude() {
    local id name state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-isolation"
    local done_dir="$state_dir/sandboxes" ddev_script="$state_dir/install-ddev.sh"
    id="$(command sbx run claude -d </dev/null 2>/dev/null | tail -n 1)"
    case "$id" in "" | *[!0-9a-f-]*) id="" ;; esac
    # A recreated sandbox gets a new id, so the marker never hides a missing plugin.
    if [ -n "$id" ] && { [ ! -e "$done_dir/$id" ] || [ -d .ddev ]; }; then
        # sbx ls --json prints a bare array; older sbx versions wrapped it in {"sandboxes": [...]}.
        command -v jq >/dev/null 2>&1 && name="$(command sbx ls --json 2>/dev/null \
            | jq -r --arg id "$id" '(.sandboxes? // .)[]? | select(.id == $id) | .name' 2>/dev/null)"
        [ -z "$name" ] && printf '⚠️  Could not find sandbox %s (needs jq and sbx ls --json), plugin and DDEV installs skipped.\n' "$id"
    elif [ -z "$id" ]; then
        printf '⚠️  Could not identify the sandbox (sbx run claude -d), plugin and DDEV installs skipped.\n'
    fi
    if [ -n "$name" ] && [ ! -e "$done_dir/$id" ]; then
        printf '🔌 Installing the agent-isolation plugin in sandbox %s...\n' "$name"
        # HTTPS: the sandbox has no SSH access to GitHub.
        if command sbx exec "$name" -- sh -c 'export PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"
            claude plugin list 2>/dev/null | grep -q "agent-isolation@agent-isolation" && exit 0
            claude plugin marketplace add https://github.com/silvanoalda/agent-isolation.git \
                && claude plugin install agent-isolation@agent-isolation' </dev/null >/dev/null 2>&1; then
            mkdir -p "$done_dir" && : >"$done_dir/$id"
        else
            printf '⚠️  Could not install it, the session starts without the plugin.\n'
        fi
    fi
    # Installed here rather than by the plugin hook, so the progress shows and no hook timeout applies.
    if [ -n "$name" ] && [ -d .ddev ] && [ -f "$ddev_script" ] \
        && ! command sbx exec "$name" -- sh -c 'command -v ddev' </dev/null >/dev/null 2>&1; then
        printf '📦 Installing DDEV in sandbox %s...\n' "$name"
        if command sbx exec -i "$name" -- bash -s <"$ddev_script" 2>&1; then
            printf '✅ DDEV is ready: run ddev start in the session.\n'
        else
            printf '⚠️  Could not install DDEV, the plugin tries again when the session starts.\n'
        fi
    fi
    command sbx run claude
}

sbx() {
    _agent_isolation_reload && { sbx "$@"; return $?; }
    if [ $# -eq 2 ] && [ "$1" = run ] && [ "$2" = claude ] && [ -z "${SANDBOX_NAME:-}" ] \
        && [ "${AGENT_ISOLATION_LAUNCHER:-}" != "off" ]; then
        _agent_isolation_sbx_claude
        return $?
    fi
    command sbx "$@"
}

claude() {
    _agent_isolation_reload && { claude "$@"; return $?; }
    if [ $# -eq 0 ] && [ -z "${SANDBOX_NAME:-}" ] && [ "${AGENT_ISOLATION_LAUNCHER:-}" != "off" ] \
        && [ -t 0 ] && command -v sbx >/dev/null 2>&1; then
        _claude_repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        if [ -n "$_claude_repo_root" ]; then
            printf '\n⚠️  Claude Code is about to run on your host, without any isolation.\n'
            printf '   Start it with "sbx run claude" in %s? [Y/n] ' "$(basename "$_claude_repo_root")"
            read -r _claude_reply
            case "$_claude_reply" in
                [nN]*)
                    printf '   Starting Claude Code on the host.\n\n'
                    ;;
                *)
                    (cd "$_claude_repo_root" && sbx run claude)
                    return $?
                    ;;
            esac
        fi
    fi
    command claude "$@"
}
