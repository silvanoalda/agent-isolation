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
# installs the plugin in the sandbox when it is not there yet; other sbx commands are unchanged.
# Set AGENT_ISOLATION_LAUNCHER=off to skip both.

# Starts the sandbox of the current directory detached (creating it if needed), installs the
# plugin once per sandbox, then attaches. Any failure only skips the install.
_agent_isolation_sbx_claude() {
    local id name done_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-isolation/sandboxes"
    id="$(command sbx run claude -d </dev/null 2>/dev/null | tail -n 1)"
    case "$id" in "" | *[!0-9a-f-]*) id="" ;; esac
    # A recreated sandbox gets a new id, so the marker never hides a missing plugin.
    if [ -n "$id" ] && [ ! -e "$done_dir/$id" ] && command -v jq >/dev/null 2>&1; then
        name="$(command sbx ls --json 2>/dev/null \
            | jq -r --arg id "$id" '.sandboxes[]? | select(.id == $id) | .name' 2>/dev/null)"
        if [ -n "$name" ]; then
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
    fi
    command sbx run claude
}

sbx() {
    if [ $# -eq 2 ] && [ "$1" = run ] && [ "$2" = claude ] && [ -z "${SANDBOX_NAME:-}" ] \
        && [ "${AGENT_ISOLATION_LAUNCHER:-}" != "off" ]; then
        _agent_isolation_sbx_claude
        return $?
    fi
    command sbx "$@"
}

claude() {
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
