# agent-isolation

What your coding agent can reach on your host, and how isolating it protects you. For Claude Code.

A Claude Code plugin (and single-plugin marketplace) that reminds you, for every project you open, to run Claude Code isolated from your host.

At session start it:

- **On the host**: shows a warning listing the risks for this project and ranking the isolation options (sbx, Dev Containers, bubblewrap) with how to start each one. When sbx is missing, it shows how to install it for your system (sbx needs no Docker), and on Linux it checks that KVM, which sbx needs, is available to your user.
- **Once a day** (on the host and inside sbx): runs, in the background, a headless read only Claude (`claude -p` with only Read, Glob and Grep, `.env` files and keys denied) that re-analyses the current project and rewrites that list, so it follows project changes and newer models. The warning shows at once with the previous analysis (at the first start, only a line saying it is being generated), and Claude shows the new analysis in the session as soon as it is ready, usually within a minute. If generation fails, Claude does it in the session after your first message instead. The result is cached in `.claude/agent-isolation.local.txt`, kept out of git through `.git/info/exclude`. A copy committed to git is ignored, since anyone with push access could have written it.
- **Inside sbx**: installs DDEV from GitHub releases when the project has a `.ddev/` directory and `ddev` is missing.
- **Inside a Dev Container or other container**: stays silent.
- **Once a day** (on the host and inside sbx): checks the marketplace for a newer version of the plugin. When there is one, the next start shows the update commands and Claude offers to run them.

## Install

```bash
claude plugin marketplace add silvanoalda/agent-isolation
claude plugin install agent-isolation@agent-isolation
```

Or `/plugin marketplace add …` and `/plugin install …` from inside Claude Code.

### Inside sbx

Each sbx sandbox has its own Claude Code configuration, so the plugin installed on the host is not there. It must be installed in the sandbox for the daily refresh and the DDEV install to run.

The [launcher](#launcher) does it for you: `sbx run claude` installs the plugin in the project's sandbox the first time (new or existing sandbox), then starts the session. Nothing else to do.

Without the launcher, the `kit/` directory is an sbx kit that does the same. sbx only accepts kits from Docker Hub by default, so allow this repository once (keep any other entries you already have, see `sbx settings get kit.allowedSources`):

```bash
sbx settings set kit.allowedSources '["docker.io/","github.com/silvanoalda/agent-isolation"]'
```

Then, for a new sandbox, from the project directory:

```bash
sbx run claude --kit 'git+https://github.com/silvanoalda/agent-isolation.git#dir=kit'
```

`--kit` only applies when the sandbox is created. For a sandbox that already exists (its name is in `sbx ls`), add the kit once:

```bash
sbx kit add claude-<project> 'git+https://github.com/silvanoalda/agent-isolation.git#dir=kit'
```

## Updates

Claude Code does not update plugins from third-party marketplaces unless you turn it on. Recommended: in a session, open `/plugin`, go to **Marketplaces**, select **agent-isolation** and choose **Enable auto-update**.

Without auto-update, the hook checks the marketplace once a day in the background and, when a newer version exists, shows at the next start:

```bash
claude plugin marketplace update agent-isolation
claude plugin update agent-isolation@agent-isolation
```

Then run `/reload-plugins` (or restart Claude Code). A marketplace added from a local path is not checked: run `git pull` in that directory, then the two commands above.

## Launcher

When sbx is installed, the hook adds the launcher to `~/.bashrc` and `~/.zshrc` (those that exist, or the one of your login shell) at the first start on the host, and says so in the warning. It takes effect in new terminals. A removed line is added back at the next start: to opt out, set `AGENT_ISOLATION_LAUNCHER=off`. If none of those files can be used, the warning shows the line to add yourself:

```bash
source ~/.claude/agent-isolation/launcher.sh
```

With the launcher:

- `sbx run claude` installs the plugin in the project's sandbox when it is not there yet (a few seconds, once per sandbox, also when a sandbox is recreated), then starts the session as usual. With other arguments, `sbx` runs unchanged.
- `claude` without arguments in a git repository asks whether to start it with `sbx run claude` instead of on the host.

The hook keeps that copy up to date. Set `AGENT_ISOLATION_LAUNCHER=off` to turn both off and keep the hook from adding the line.

## Status line (optional)

The analysis runs in the background for about a minute. To see an animated spinner in the status line meanwhile, call the segment the plugin keeps at `~/.claude/agent-isolation/statusline.sh` (under `$CLAUDE_CONFIG_DIR` instead of `~/.claude` if you set it, as for the launcher) from your status line script, passing it the JSON Claude Code gives on stdin. It prints nothing when no analysis runs:

```bash
input=$(cat)
# ... your status line ...
seg="$(printf '%s' "$input" | ~/.claude/agent-isolation/statusline.sh 2>/dev/null)"
[ -n "$seg" ] && printf ' | %s' "$seg"
```

Then add `"refreshInterval": 1` to `statusLine` in `~/.claude/settings.json`, so the status line is redrawn every second while the session is idle. Plugins cannot set the status line themselves, which is why this step is manual.

## Settings (environment variables)

| Variable | Default | Effect |
|---|---|---|
| `AGENT_ISOLATION_DISABLE` | unset | `1` disables the hook |
| `AGENT_ISOLATION_MAX_AGE_MINUTES` | `1440` | Age after which Claude refreshes the analysis |
| `AGENT_ISOLATION_MODEL` | `sonnet` | Model used to generate the analysis |
| `AGENT_ISOLATION_ANALYSIS_TIMEOUT` | `150` | Seconds before the background analysis gives up and falls back to the session |
| `AGENT_ISOLATION_LAUNCHER` | unset | `off` disables the launcher (prompt and plugin install in sbx) |
| `AGENT_ISOLATION_UPDATE_CHECK` | unset | `off` disables the daily check for a newer plugin version |
| `DDEV_INSTALL_DIR` | `/usr/local/bin` | Where DDEV is installed inside sbx |

## License

MIT, see [LICENSE](LICENSE).
