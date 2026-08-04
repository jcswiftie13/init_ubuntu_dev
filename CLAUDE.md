# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Single-file Ubuntu dev environment bootstrap. One script (`setup.sh`) installs and configures a full dev toolchain on Ubuntu 20.04+.

## Running the script

```bash
chmod +x setup.sh
./setup.sh
```

Re-running is safe — every step guards with `command -v` or file-existence checks before acting.

## Script structure

`setup.sh` is a flat, numbered-section bash script (no functions, no `main()`). Sections run sequentially top to bottom:

| Section | What it does |
|---|---|
| `# --- 1)` | apt update + base packages (zsh, git, curl, build-essential, bash-completion) |
| `# --- 2)` | zsh + Powerlevel10k + autosuggestions + syntax-highlighting (direct git clone, no Oh My Zsh) |
| `# --- 3)` | Latest Go tarball → `/usr/local/go`; symlinks in `/usr/local/bin` |
| `# --- 4)` | Latest jq binary → `/usr/local/bin` (GitHub release; apt fallback) |
| `# --- 5)` | Node.js 22 via nodesource + TypeScript global → `/usr/local/bin` |
| `# --- 6)` | Cursor (official `.deb`, latest version resolved from the update JSON API; skips re-download when already current) |
| `# --- 6b)` | Cursor extensions: git-graph, gitlens, gitblame, golang.go, claude-code |
| `# --- 7)` | Claude Code CLI via `claude.ai/install.sh` → `~/.local/bin` |
| `# --- 8)` | Git global identity (`user.email` / `user.name`) |
| `# --- 9)` | golangci-lint → `/usr/local/bin` |
| `# --- 11)` | Clone `otel-traces-test` → `~/Documents/otel-traces-test` |
| `# --- 12)` | RTK (Rust Token Killer) installer → `~/.local/bin` |
| `# --- 12b)` | `rtk init -g` + `rtk init -g --agent cursor` |
| `# --- 13)` | Claude Code plugins: claude-code-setup, gopls-lsp, superpowers, claude-hud, caveman |
| `# --- 14)` | openspec global npm install |
| `# --- 15)` | Helm → `/usr/local/bin` (latest release tarball + sha256 verify) |
| `# --- 16)` | git + helm shell completions → `~/.config/zsh/completions`; `compinit` block in `~/.zshrc`, bash-completion block in `~/.bashrc` |

## Key patterns

- **Idempotency guard**: `command -v <tool>` or `[[ ! -d <path> ]]` before every install — re-running is safe.
- **Shell rc patching**: `~/.zshrc` is patched with `grep -q '<marker>'` checks before appending blocks. Marker strings are the first line of each block; changing a marker causes duplicate entries on re-run.
- **`~/.local/bin` on PATH**: Claude Code and RTK install here; the script appends `export PATH="${HOME}/.local/bin:${PATH}"` to `~/.zshrc` (marker: `env-init: user local bin`).
- **Go PATH**: `~/go/bin` (GOPATH/bin) appended to `~/.zshrc` (marker: `env-init: go bin`).
- **Zsh plugins**: sourced directly in `~/.zshrc` from `~/.config/zsh/plugins/` (marker: `env-init: zsh plugins`).
- **Completions**: `~/.config/zsh/completions/` holds `_git` (git's `contrib/completion/git-completion.zsh`), its companion `git-completion.bash`, and `_helm`; `~/.zshrc` puts that dir on `fpath` and runs `compinit -i` (marker: `env-init: completions`, same marker in `~/.bashrc`).

## Extending the script

Add a new numbered section following the pattern: idempotency guard → install command → `log "WARN: ..."` fallback. Insert before the final `log "Done."` lines.

Helper used throughout: `log()` — thin wrapper around `printf '%s\n'`; `die()` — logs and exits 1.

## Claude plugin install commands (section 13)

```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace update claude-plugins-official
claude plugin install claude-code-setup@claude-plugins-official
claude plugin install gopls-lsp@claude-plugins-official
claude plugin install superpowers@claude-plugins-official
claude plugin marketplace add jarrodwatts/claude-hud
claude plugin install claude-hud
claude plugin marketplace add JuliusBrussee/caveman
claude plugin install caveman@caveman
```

On Linux, if `claude plugin install` fails with a cross-device error (`EXDEV`), prefix with `TMPDIR=~/.cache/tmp`:
```bash
mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude plugin install <plugin>
```
