@AGENTS.md

# Claude Code specifics

Everything in AGENTS.md applies. These are the traps specific to driving this repo from
Claude Code, each hit at least once:

- **The Bash tool runs zsh, not bash.** An unquoted `$list` is not word-split in zsh, which is
  how `security list-keychains -s $list` once replaced the user's keychain search list with a
  single bogus path. Anything with arrays, word splitting, `set -euo pipefail` or more than a
  couple of steps goes in a `#!/bin/bash` script (or `bash -c '…'`), never a zsh one-liner.
- **`grep` in the Bash tool is a ugrep wrapper that skips gitignored files.** `.build/`, `dist/`
  and anything else ignored are invisible to it. Use `/usr/bin/grep` or `find` when looking
  inside build output.
- **Long waits go in the background.** The update scenario, `harness permission` and
  `gh run watch` run for minutes: use `run_in_background` and wait for the notification instead
  of polling. Never `sleep` in a loop waiting for a person.
- **Nothing on screen reaches you.** DiveMac usually has its lid closed: `screencapture` returns
  black and permission prompts time out unanswered. Check before asking someone to look at
  something (`Scripts/harness status`), and when a click is needed, ask for exactly that click.
- **Read before reporting.** Background agents and long commands report back later; never
  describe a result you have not read. If a check passed only locally, or was skipped, say so.
- **Pushing is publishing.** Do not push to `main` unless the user asked for a release or
  approved the push; follow the checklist in AGENTS.md › Releases when they do.
