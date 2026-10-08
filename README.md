# agent-isolation

What your coding agent can reach on your host, and how isolating it protects you. For Claude Code.

A Claude Code plugin (and single-plugin marketplace) that reminds you, for every project you open, to run Claude Code isolated from your host.

At session start it:

- **On the host**: shows a warning listing the risks for this project and ranking the isolation options (sbx, Dev Containers, bubblewrap) with how to start each one.
- **Once a day** (on the host and inside sbx): runs a headless, read only Claude (`claude -p` with only Read, Glob and Grep, `.env` files and keys denied) that re-analyses the current project and rewrites that list before the warning is shown, so it follows project changes and newer models. Startup takes about 10 to 30 seconds longer that time. If it fails or times out, Claude does it in the session after your first message instead. The result is cached in `.claude/agent-isolation.local.txt`, kept out of git through `.git/info/exclude`. A copy committed to git is ignored, since anyone with push access could have written it.
- **Inside sbx**: installs DDEV from GitHub releases when the project has a `.ddev/` directory and `ddev` is missing.
- **Inside a Dev Container or other container**: stays silent.

## Install

```bash
claude plugin marketplace add /path/to/agent-isolation
claude plugin install agent-isolation@agent-isolation
```

Or `/plugin marketplace add …` and `/plugin install …` from inside Claude Code. After `git pull` in this directory, run `claude plugin marketplace update agent-isolation` and `claude plugin update agent-isolation@agent-isolation`.

The plugin must also be installed inside sbx for the daily refresh and the DDEV install to run there.

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
| `AGENT_ISOLATION_ANALYSIS_TIMEOUT` | `150` | Seconds before the analysis falls back to the session |
| `AGENT_ISOLATION_LAUNCHER` | unset | `off` disables the launcher prompt |
| `DDEV_INSTALL_DIR` | `/usr/local/bin` | Where DDEV is installed inside sbx |

## License

MIT, see [LICENSE](LICENSE).
