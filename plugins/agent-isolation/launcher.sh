# agent-isolation launcher: offers to start Claude Code inside the sbx sandbox.
#
# The plugin keeps a stable copy at ~/.claude/agent-isolation/launcher.sh.
# Source it once from ~/.bashrc or ~/.zshrc on the host:
#   source ~/.claude/agent-isolation/launcher.sh
#
# When `claude` is run without arguments on the host inside a git repository,
# it asks for confirmation and runs `sbx run claude` from the repository root.
# With arguments (claude -p, claude plugin ..., claude --resume) or outside
# a repository it runs Claude Code unchanged. Set AGENT_ISOLATION_LAUNCHER=off to skip.

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
