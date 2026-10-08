# agent-isolation

Claude Code plugin shipped as a single-plugin marketplace. User docs are in README.md.

## Structure

- `.claude-plugin/marketplace.json`: the marketplace, pointing at `plugins/agent-isolation`.
- `plugins/agent-isolation/.claude-plugin/plugin.json`: plugin manifest (name, version).
- `plugins/agent-isolation/hooks/hooks.json`: registers the SessionStart hook.
- `plugins/agent-isolation/hooks/isolation-check.sh`: the hook. On the host (`SANDBOX_NAME`
  unset, not in a container) it prints the warning; inside sbx it installs DDEV when `.ddev/`
  exists; in both cases it asks Claude to refresh `.claude/agent-isolation.local.txt` when that
  file is missing or older than a day. In a Dev Container or other container it exits silently.
- `plugins/agent-isolation/launcher.sh`: optional shell function, copied by the hook to
  `~/.claude/agent-isolation/launcher.sh`.

The hook must always exit 0 and print either nothing or one valid JSON object.

## Testing the hook

```bash
claude plugin validate . && claude plugin validate plugins/agent-isolation
bash -n plugins/agent-isolation/hooks/isolation-check.sh plugins/agent-isolation/launcher.sh

t=$(mktemp -d); git init -q "$t/proj"
CLAUDE_PROJECT_DIR="$t/proj" CLAUDE_PLUGIN_ROOT="$PWD/plugins/agent-isolation" \
CLAUDE_CONFIG_DIR="$t/cfg" bash plugins/agent-isolation/hooks/isolation-check.sh | jq .
```

Vary the case with `SANDBOX_NAME=test` (sbx), `AGENT_ISOLATION_DISABLE=1`, or by writing
`$t/proj/.claude/agent-isolation.local.txt` and aging it with `touch -d '2 days ago'`.
The host branch stays silent when run inside a container (`/.dockerenv`).

## Publishing

1. Bump `version` in `plugins/agent-isolation/.claude-plugin/plugin.json` (users only get
   updates when it changes).
2. Validate, commit, push.
3. Users run `claude plugin marketplace update agent-isolation` and
   `claude plugin update agent-isolation@agent-isolation`.
