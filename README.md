# init_ubuntu_dev

Single-script Ubuntu dev environment bootstrap. Installs and configures a full toolchain on Ubuntu 20.04+.

## What gets installed

| # | Tool | Notes |
|---|------|-------|
| 1 | **Zsh + Powerlevel10k** | Direct git clone — no Oh My Zsh, no zinit |
| 2 | **Go + golangci-lint** | Latest stable from go.dev; golangci-lint via official script |
| 3 | **jq** | Latest binary from GitHub releases; apt fallback |
| 4 | **Node.js 24** | Via nodesource (upgrades if < 22.18) + TypeScript global |
| 5 | **Claude Code** | Native installer → `~/.local/bin` |
| 6 | **RTK** | Rust Token Killer → `~/.local/bin`; initialized globally |
| 7 | **Claude plugins** | claude-code-setup, superpowers, claude-hud, caveman |
| 8 | **openspec** | Global npm install |

## Requirements

- Ubuntu 20.04 LTS or later (Debian-based)
- `sudo` access
- Internet connection

## Usage

```bash
git clone https://github.com/Marz32onE/init_ubuntu_dev.git
cd init_ubuntu_dev
chmod +x setup.sh
./setup.sh
```

After the script finishes:

```bash
exec zsh          # start zsh in the current terminal
p10k configure    # interactive Powerlevel10k prompt wizard
claude auth       # authenticate your Anthropic account
```

## Idempotent

Every step checks whether the tool is already installed before acting. Re-running `setup.sh` is safe.

## Linux note — Claude plugin installs

If `claude plugin install` fails with a cross-device error (`EXDEV: cross-device link not permitted`), run:

```bash
mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude plugin install <plugin>
```

This occurs when `/tmp` and `$HOME` are on different filesystems.
