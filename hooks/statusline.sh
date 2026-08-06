#!/usr/bin/env bash
# statusLine wrapper. Claude Code hands the status line a JSON payload that carries two numbers
# it hands to nobody else: rate_limits (5h / 7d usage) and context_window.context_window_size.
# Limits in particular are never written to disk by Claude Code — they live in the process and
# leave through this one door. So the door gets a doorman.
#
# Everything the user already had keeps working: the previously configured command is saved
# verbatim, receives the exact same bytes on stdin, and its output is passed through untouched.
# Install and uninstall: scripts/mcpbar.py statusline --install | --uninstall
set -u

ROOT="${CONTROL_BAR_ROOT:-$HOME/.claude/control-bar}"

# Self-wrapping guard. The installer refuses to wrap itself, but the sidecar file is plain text
# a human can edit — and a wrapper calling itself forks until the machine gives up. The guard is
# an environment sentinel, not a check on the saved command's text: statusline.sh is the file
# name from the official Claude Code example, so matching on the name silenced any FOREIGN
# status line that happened to be called that. Only this script sets the variable, so seeing it
# means the caller IS this script — whatever the command around it looks like.
if [ -n "${CONTROL_BAR_STATUSLINE_ACTIVE:-}" ]; then exit 0; fi
export CONTROL_BAR_STATUSLINE_ACTIVE=1

# Script directory without a subshell: $(cd … && pwd) is another fork on every single redraw,
# and the status line redraws constantly.
SELF_DIR="${BASH_SOURCE[0]%/*}"
[ "$SELF_DIR" = "${BASH_SOURCE[0]}" ] && SELF_DIR="$ROOT"

# read -d '' keeps the trailing newline that $(cat) strips. The inner command has to receive
# byte-for-byte what Claude Code sent, or a script that counts bytes sees a different payload.
payload=""
IFS= read -r -d '' payload || :

# Background, with stdout AND stderr closed. Not cosmetic: a background child inherits the
# status line's stdout and holds it open, and Claude Code reads that pipe until EOF — so the
# whole status line freezes for exactly as long as the capture runs.
if [ -f "$SELF_DIR/statusline.py" ]; then
  printf '%s' "$payload" | /usr/bin/python3 "$SELF_DIR/statusline.py" >/dev/null 2>&1 &
fi

# read -d '' takes the whole file, not its first line: a saved command may well be several lines
# (a shell function, a pipeline broken across lines), and reading one line silently handed the
# user back a fragment of their own status line.
inner=""
[ -f "$ROOT/statusline-inner-command" ] && IFS= read -r -d '' inner < "$ROOT/statusline-inner-command"
inner="${inner%$'\n'}"   # the installer's own trailing newline is not part of the command
[ -n "$inner" ] || exit 0

# printf, not a here-string: <<< appends a newline and breaks the byte equality promised above.
printf '%s' "$payload" | bash -c "$inner"
