# Asking an agent to install zsh-reap

Copy the block below into a fresh chat with your agent (Claude Code, an
editor's AI pane, etc.). It is written so the agent does the
discovery and copying, and stops to ask you before anything that
modifies your shell init.

---

```
Please install gauravmm/zsh-reap for me so you can restart my
long-running foreground commands without asking. The repo is at
https://github.com/gauravmm/zsh-reap.

1. Pick a stable location for the clone. Look at where I already keep
   tooling (e.g. `~/src`, `~/code`, `~/work`, `~/.local/share`). If
   it's not obvious, ask me. Clone the repo there.

2. Figure out which zsh plugin manager I use. Check `~/.zshrc` first,
   then look for the signatures of common managers:
     - zgenom:    `~/.zgen-setup`, `~/.zgenom`, or `zgenom load` lines
     - zgen:      `~/.zgen` directory, `zgen load` lines
     - antidote:  `~/.zsh_plugins.txt` or `antidote` in `.zshrc`
     - sheldon:   `~/.config/sheldon/plugins.toml`
     - oh-my-zsh: `~/.oh-my-zsh/`, `plugins=(...)` in `.zshrc`
     - znap:      `znap source` lines in `.zshrc`
     - none:      just `source` lines in `.zshrc`

   The repo's README has a one-line install snippet per manager. Show
   me the exact line you intend to add and the exact file you'll add
   it to (and where in the file — most managers want the line in a
   specific block). Ask me to confirm. After I say yes, append it; do
   not edit any other line. If a `zsh-reap` line already exists in
   that file, stop and ask — don't add a duplicate. Back up the file
   to `<file>.bak.<timestamp>` before writing.

3. Install the agent skill so future agent sessions know about the
   tool. Default to a user-wide install:
     mkdir -p ~/.claude/skills/zsh-reap
     cp <clone-path>/skills/zsh-reap/SKILL.md ~/.claude/skills/zsh-reap/SKILL.md

   If we're working inside one specific project repo and the tool is
   only relevant there, use `.claude/skills/zsh-reap/` inside that
   project instead. Tell me which scope you picked and why.

4. Once I've added the plugin-manager line and started a new zsh
   session (or sourced .zshrc), verify with:
     command -v zsh-reap && zsh-reap list
   `list` will be empty until I start a long-running foreground
   command, which is fine — it confirms the CLI is on PATH and the
   state directory exists.

Constraints:
- The only shell init edit you may make is the single plugin-manager
  line in step 2, after I've confirmed it. Touch no other lines.
  Always back up the file first.
- Don't run any commands as root; this tool is per-user.
- Don't install or upgrade anything else (no homebrew, no apt, no pip).
  zsh-reap's only dependencies (ps, pgrep, kill) are already on every
  Unix system.
- If you hit a conflict (an existing zsh-reap install in a different
  location, a plugin-manager setup that doesn't match the table above,
  an unfamiliar custom loader, etc.) stop and ask me before resolving
  it.
```

---

When the agent is done, the next time you start a long-running command
in your interactive zsh (something that takes more than 5 seconds),
the agent in any subsequent session will see it via `zsh-reap list`
and be able to `restart` it for you.
