# agent-isolation

Claude Code plugin shipped as a single-plugin marketplace. User docs are in README.md.

## Structure

- `.claude-plugin/marketplace.json`: the marketplace, pointing at `plugins/agent-isolation`.
- `plugins/agent-isolation/.claude-plugin/plugin.json`: plugin manifest (name, version).
- `plugins/agent-isolation/hooks/hooks.json`: registers the SessionStart hook twice: the main run,
  which shows the warning at once, and an `analyse` run (`asyncRewake`) that regenerates the
  analysis in the background and wakes Claude to show it.
- `plugins/agent-isolation/hooks/isolation-check.sh`: the hook. On the host (`SANDBOX_NAME`
  unset, not in a container) it prints the warning; inside sbx it installs DDEV when `.ddev/`
  exists; in both cases the `analyse` run regenerates `.claude/agent-isolation.local.txt` with a headless
  read only `claude -p` when that file is missing or older than a day (falling back to asking
  Claude in the session if that fails). In a Dev Container or other container it exits silently.
- `plugins/agent-isolation/launcher.sh`: optional shell function, copied by the hook to
  `~/.claude/agent-isolation/launcher.sh`.

The main run must always exit 0 and print either nothing or one valid JSON object. The `analyse`
run prints nothing on stdout and exits 2 with a message for Claude on stderr, or 0 to stay quiet.

## Testing the hook

```bash
claude plugin validate . && claude plugin validate plugins/agent-isolation
bash -n plugins/agent-isolation/hooks/isolation-check.sh plugins/agent-isolation/launcher.sh
bash tests/run.sh
```

`tests/run.sh` covers the hook (main and `analyse` runs) and the launcher with fake `claude`
and `sbx` binaries, so it needs no login or network. Add a case there for every behaviour
change. CI (`.github/workflows/test.yml`) runs the same three steps on every push.
Not covered: the DDEV install in sbx and the interactive launcher prompt.

For a manual run against the real `claude`:

```bash
t=$(mktemp -d); git init -q "$t/proj"
CLAUDE_PROJECT_DIR="$t/proj" CLAUDE_PLUGIN_ROOT="$PWD/plugins/agent-isolation" \
CLAUDE_CONFIG_DIR="$t/cfg" bash plugins/agent-isolation/hooks/isolation-check.sh | jq .
```

Pass `analyse` as first argument to test the background run. It needs a logged in `claude`, so
drop `CLAUDE_CONFIG_DIR` to exercise it.
Vary the case with `AGENT_ISOLATION_ANALYSIS_TIMEOUT=1` (fallback), `SANDBOX_NAME=test` (sbx), `AGENT_ISOLATION_DISABLE=1`, or by writing
`$t/proj/.claude/agent-isolation.local.txt` and aging it with `touch -d '2 days ago'`.
The host branch stays silent when run inside a container (`/.dockerenv`).

## Publishing

1. Bump `version` in `plugins/agent-isolation/.claude-plugin/plugin.json` (users only get
   updates when it changes).
2. Validate, commit, push.
3. Users run `claude plugin marketplace update agent-isolation` and
   `claude plugin update agent-isolation@agent-isolation`.
