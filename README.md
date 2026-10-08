# agent-isolation

What your coding agent can reach on your host, and how isolating it protects you. For Claude Code.

A Claude Code plugin (and single-plugin marketplace) that reminds you, for every project you open, to run Claude Code isolated from your host.

At session start it:

- **On the host**: shows a warning listing the risks for this project and ranking the isolation options (sbx, Dev Containers, bubblewrap) with how to start each one.
- **Once a day** (on the host and inside sbx): runs, in the background, a headless read only Claude (`claude -p` with only Read, Glob and Grep, `.env` files and keys denied) that re-analyses the current project and rewrites that list, so it follows project changes and newer models. The warning shows at once with the previous analysis (or a generic one at the first start), and Claude shows the new analysis in the session as soon as it is ready, usually within a minute. If generation fails, Claude does it in the session after your first message instead. The result is cached in `.claude/agent-isolation.local.txt`, kept out of git through `.git/info/exclude`. A copy committed to git is ignored, since anyone with push access could have written it.
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

Each sbx sandbox has its own Claude Code configuration, so the plugin installed on the host is not there. It must be installed in the sandbox for the daily refresh and the DDEV install to run. The `kit/` directory is an sbx kit that does it. sbx only accepts kits from Docker Hub by default, so allow this repository once (keep any other entries you already have, see `sbx settings get kit.allowedSources`):

```bash
sbx settings set kit.allowedSources '["docker.io/","github.com/silvanoalda/agent-isolation"]'
```

Then, for a new sandbox, from the project directory:

```bash
sbx run claude --kit 'git+https://github.com/silvanoalda/agent-isolation.git#dir=kit'
```

`--kit` only applies when the sandbox is created. For a sandbox that already exists (its name is in `sbx ls`), add the kit once, then start it as usual with `sbx run claude`:

```bash
sbx kit add claude-<project> 'git+https://github.com/silvanoalda/agent-isolation.git#dir=kit'
```

Kits are an experimental sbx feature. If they are not available, install the plugin by hand inside the sandbox:

```bash
sbx exec claude-<project> -- claude plugin marketplace add https://github.com/silvanoalda/agent-isolation.git
sbx exec claude-<project> -- claude plugin install agent-isolation@agent-isolation
```

## Updates

Claude Code does not update plugins from third-party marketplaces unless you turn it on. Recommended: in a session, open `/plugin`, go to **Marketplaces**, select **agent-isolation** and choose **Enable auto-update**.

Without auto-update, the hook checks the marketplace once a day in the background and, when a newer version exists, shows at the next start:

```bash
claude plugin marketplace update agent-isolation
claude plugin update agent-isolation@agent-isolation
```

Then run `/reload-plugins` (or restart Claude Code). A marketplace added from a local path is not checked: run `git pull` in that directory, then the two commands above.

## Launcher (optional)

To be asked whether to use `sbx run claude` each time you start `claude` without arguments in a git repository, add this to `~/.bashrc` or `~/.zshrc` on the host:

```bash
source ~/.claude/agent-isolation/launcher.sh
```

The hook keeps that copy up to date. Set `AGENT_ISOLATION_LAUNCHER=off` to skip the prompt.

## Settings (environment variables)

| Variable | Default | Effect |
|---|---|---|
| `AGENT_ISOLATION_DISABLE` | unset | `1` disables the hook |
| `AGENT_ISOLATION_MAX_AGE_MINUTES` | `1440` | Age after which Claude refreshes the analysis |
| `AGENT_ISOLATION_MODEL` | `sonnet` | Model used to generate the analysis |
| `AGENT_ISOLATION_ANALYSIS_TIMEOUT` | `150` | Seconds before the background analysis gives up and falls back to the session |
| `AGENT_ISOLATION_LAUNCHER` | unset | `off` disables the launcher prompt |
| `AGENT_ISOLATION_UPDATE_CHECK` | unset | `off` disables the daily check for a newer plugin version |
| `DDEV_INSTALL_DIR` | `/usr/local/bin` | Where DDEV is installed inside sbx |

## License

MIT, see [LICENSE](LICENSE).
