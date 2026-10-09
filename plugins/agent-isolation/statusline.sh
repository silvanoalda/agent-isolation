#!/usr/bin/env bash
# agent-isolation status line segment: an animated spinner while the background risk analysis runs
# for the current project, nothing otherwise. Plugins cannot set the status line, so call it from
# yours with the JSON Claude Code passes on stdin, and set "refreshInterval": 1 so it animates:
#   seg="$(printf '%s' "$input" | ~/.claude/agent-isolation/statusline.sh)"
# The plugin keeps a stable copy at ~/.claude/agent-isolation/statusline.sh ($CLAUDE_CONFIG_DIR
# instead of ~/.claude when set).

input="$(cat)"
dir=""
if command -v jq >/dev/null 2>&1; then
    dir="$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty' 2>/dev/null)"
fi
[ -n "$dir" ] || dir="$PWD"

# The analyse run holds this lock while it works (see isolation-check.sh); stale ones expire there too.
lock="${TMPDIR:-/tmp}/agent-isolation-$(printf '%s' "$dir" | cksum | cut -d' ' -f1).lock"
[ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0

frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
now="${EPOCHSECONDS:-$(date +%s)}"  # EPOCHSECONDS needs bash 5, macOS ships 3.2
printf '\033[33m%s Analysing isolation risks\033[0m' "${frames[$((now % 10))]}"
