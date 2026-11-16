#!/usr/bin/env bash
# Bootstrap dev environment: zsh + Powerlevel10k, Go, jq, TypeScript (tsc), Claude Code CLI, RTK, git.
# `sh init.sh` uses dash on Debian/Ubuntu; re-exec with bash (this script needs pipefail and [[ ]]).
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

SUDO=""
if [[ "${EUID:-0}" -ne 0 ]]; then
  SUDO="sudo"
fi

log() { printf '%s\n' "$*"; }

die() { log "ERROR: $*"; exit 1; }

map_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

GOARCH="$(map_arch)"

# --- 1) Base packages (Debian/Ubuntu) ---
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y \
    zsh git curl wget ca-certificates gnupg unzip \
    build-essential bash-completion
else
  die "This script expects apt-get (Debian/Ubuntu). Install zsh/git/curl manually on other distros."
fi

# --- 2) Zsh plugins: Powerlevel10k + autosuggestions + syntax highlighting (no Oh My Zsh) ---
ZSH_PLUGINS_DIR="${HOME}/.config/zsh/plugins"
mkdir -p "${ZSH_PLUGINS_DIR}"

if [[ ! -d "${ZSH_PLUGINS_DIR}/powerlevel10k" ]]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_PLUGINS_DIR}/powerlevel10k"
fi
if [[ ! -d "${ZSH_PLUGINS_DIR}/zsh-autosuggestions" ]]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${ZSH_PLUGINS_DIR}/zsh-autosuggestions"
fi
if [[ ! -d "${ZSH_PLUGINS_DIR}/zsh-syntax-highlighting" ]]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "${ZSH_PLUGINS_DIR}/zsh-syntax-highlighting"
fi

ZSHRC="${HOME}/.zshrc"
[[ -f "${ZSHRC}" ]] || touch "${ZSHRC}"

# Powerlevel10k instant prompt — must be first in .zshrc
if ! grep -q 'p10k-instant-prompt' "${ZSHRC}"; then
  _p10k_tmp="$(mktemp)"
  cat >"${_p10k_tmp}" <<'ZSHINSTANT'
# Enable Powerlevel10k instant prompt (quiet mode)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

ZSHINSTANT
  cat "${ZSHRC}" >>"${_p10k_tmp}"
  mv "${_p10k_tmp}" "${ZSHRC}"
fi

# Source plugins directly (idempotent via marker)
if ! grep -q 'env-init: zsh plugins' "${ZSHRC}" 2>/dev/null; then
  cat >> "${ZSHRC}" <<'ZSHPLUGINS'

# env-init: zsh plugins
source "$HOME/.config/zsh/plugins/powerlevel10k/powerlevel10k.zsh-theme"
source "$HOME/.config/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "$HOME/.config/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHPLUGINS
fi

# Claude Code installs to ~/.local/bin; the native installer may not persist PATH for zsh (see anthropics/claude-code#21069).
mkdir -p "${HOME}/.local/bin"
if [[ -f "${ZSHRC}" ]] && ! grep -q 'env-init: user local bin' "${ZSHRC}" 2>/dev/null; then
  printf '\n# env-init: user local bin (Claude Code, pip --user)\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "${ZSHRC}"
fi

# --- 3) Go → /usr/local/go, symlinks in /usr/local/bin ---
# go.dev returns multiple lines (version + build time); only the first line is the release tag.
GO_VER_RAW="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1 | tr -d '\r\n')"
GO_VER="${GO_VER_RAW#go}"
if [[ ! "${GO_VER}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  die "unexpected Go version from go.dev (first line): ${GO_VER_RAW}"
fi
GO_TGZ="go${GO_VER}.linux-${GOARCH}.tar.gz"
TMP_GO="/tmp/${GO_TGZ}"
curl -fsSL "https://go.dev/dl/${GO_TGZ}" -o "${TMP_GO}"
$SUDO rm -rf /usr/local/go
$SUDO tar -C /usr/local -xzf "${TMP_GO}"
rm -f "${TMP_GO}"
$SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
$SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# --- 4) jq binary → /usr/local/bin ---
case "${GOARCH}" in
  amd64) JQ_ASSET="jq-linux-amd64" ;;
  arm64) JQ_ASSET="jq-linux-arm64" ;;
esac
JQ_TAG="$(
  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: env-init.sh' \
    https://api.github.com/repos/jqlang/jq/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
)"
if [[ -n "${JQ_TAG}" ]] && curl -fsSL "https://github.com/jqlang/jq/releases/download/${JQ_TAG}/${JQ_ASSET}" -o /tmp/jq.bin; then
  $SUDO install -m 0755 /tmp/jq.bin /usr/local/bin/jq
  rm -f /tmp/jq.bin
else
  log "WARN: jq GitHub download failed; installing distro jq into /usr/local/bin"
  $SUDO apt-get install -y jq
  $SUDO install -m 0755 "$(command -v jq)" /usr/local/bin/jq
  rm -f /tmp/jq.bin
fi

# --- 5) Node.js (for tsc) + TypeScript global → /usr/local/bin ---
# Require Node >= 22.18 (claude-hud needs it); install/upgrade to Node 24 via nodesource otherwise.
node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v major minor
  v="$(node -v 2>/dev/null)"; v="${v#v}"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
  (( major > 22 || (major == 22 && minor >= 18) ))
}
if ! node_ok; then
  log "Node missing or older than 22.18 ($(node -v 2>/dev/null || echo none)); installing Node 24 via nodesource"
  if [[ -n "${SUDO}" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | $SUDO -E bash -
  else
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  fi
  $SUDO apt-get install -y nodejs || log "WARN: Node 24 install failed; install from https://nodejs.org"
fi
if ! $SUDO npm install -g typescript --prefix /usr/local; then
  log "WARN: global TypeScript (tsc) install failed; retry: sudo npm install -g typescript --prefix /usr/local"
fi

# --- 7) Claude Code CLI (native installer) ---
if ! curl -fsSL https://claude.ai/install.sh | bash; then
  log "WARN: Claude Code CLI install failed; retry: curl -fsSL https://claude.ai/install.sh | bash"
fi

# --- 8) Git global identity ---
git config --global user.email "death0032@gmail.com"
git config --global user.name "marz32one"

# --- 9) golangci-lint → /usr/local/bin (release tarball + checksums) ---
# Do not use golangci's curl|install.sh path: upstream verify greps basename and matches both
# `…linux-amd64.tar.gz` and `…linux-amd64.tar.gz.sbom.json`, so checksum verification always fails.
if [[ -x /usr/bin/curl ]]; then CURL_BIN=/usr/bin/curl; else CURL_BIN=curl; fi
GCI_TAG="$(
  "${CURL_BIN}" -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: setup.sh' \
    https://api.github.com/repos/golangci/golangci-lint/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
)"
GCI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/golangci-lint.XXXXXX")"
GCI_OK=0
if [[ -n "${GCI_TAG}" ]]; then
  GCI_VER="${GCI_TAG#v}"
  GCI_TB="golangci-lint-${GCI_VER}-linux-${GOARCH}.tar.gz"
  GCI_BASE="https://github.com/golangci/golangci-lint/releases/download/${GCI_TAG}"
  GCI_CHK="golangci-lint-${GCI_VER}-checksums.txt"
  if "${CURL_BIN}" -fsSL "${GCI_BASE}/${GCI_CHK}" -o "${GCI_TMP}/${GCI_CHK}" &&
    "${CURL_BIN}" -fsSL "${GCI_BASE}/${GCI_TB}" -o "${GCI_TMP}/${GCI_TB}"; then
    GCI_WANT="$(awk -v fn="${GCI_TB}" '$2 == fn { print $1; exit }' "${GCI_TMP}/${GCI_CHK}")"
    GCI_GOT="$(sha256sum "${GCI_TMP}/${GCI_TB}" | awk '{ print $1 }')"
    if [[ -n "${GCI_WANT}" && "${GCI_WANT}" == "${GCI_GOT}" ]]; then
      tar -C "${GCI_TMP}" -xzf "${GCI_TMP}/${GCI_TB}"
      if $SUDO install -m 0755 "${GCI_TMP}/golangci-lint-${GCI_VER}-linux-${GOARCH}/golangci-lint" /usr/local/bin/golangci-lint; then
        GCI_OK=1
        log "golangci-lint installed: $(/usr/local/bin/golangci-lint --version 2>/dev/null || true)"
      fi
    else
      log "WARN: golangci-lint tarball checksum mismatch or missing entry for ${GCI_TB}"
    fi
  else
    log "WARN: golangci-lint download failed (${GCI_TAG})"
  fi
else
  log "WARN: could not resolve golangci-lint latest release tag from GitHub API"
fi
rm -rf "${GCI_TMP}"
if [[ "${GCI_OK}" -ne 1 ]]; then
  log "WARN: golangci-lint not installed; see https://golangci-lint.run/welcome/install/"
fi

# --- 10) gopls → ~/go/bin (Go language server; Claude Code gopls-lsp plugin) ---
if command -v go >/dev/null 2>&1; then
  export PATH="${HOME}/go/bin:${PATH}"
  if ! command -v gopls >/dev/null 2>&1; then
    log "Installing gopls (go install; first run often needs 1–5 minutes and a working GOPROXY)…"
    if go install golang.org/x/tools/gopls@latest; then
      log "gopls installed: $(gopls version 2>/dev/null | head -n1 || true)"
    else
      log "WARN: gopls install failed; retry: go install golang.org/x/tools/gopls@latest"
    fi
  else
    log "gopls already present; skipping."
  fi
else
  log "WARN: go not found; skipping gopls install"
fi

# Ensure ~/go/bin (GOPATH/bin) is on PATH in zsh so `go install`-ed tools are found
if [[ -f "${ZSHRC}" ]] && ! grep -q 'env-init: go bin' "${ZSHRC}" 2>/dev/null; then
  printf '\n# env-init: go bin (GOPATH)\nexport PATH="${HOME}/go/bin:${PATH}"\n' >> "${ZSHRC}"
fi

# --- 12) RTK (Rust Token Killer) → ~/.local/bin — https://github.com/rtk-ai/rtk#quick-install-linuxmacos
if curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; then
  log "RTK installed: $(command -v rtk >/dev/null 2>&1 && rtk --version 2>/dev/null || echo 'rtk on PATH after new shell')"
else
  log "WARN: RTK install failed; retry: curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
fi

# --- 12b) typescript-language-server → /usr/local/bin (Claude Code typescript-lsp plugin) ---
if command -v npm >/dev/null 2>&1; then
  if ! command -v typescript-language-server >/dev/null 2>&1; then
    if $SUDO npm install -g typescript-language-server --prefix /usr/local; then
      log "typescript-language-server installed: $(typescript-language-server --version 2>/dev/null | head -n1 || true)"
    else
      log "WARN: typescript-language-server install failed; retry: sudo npm install -g typescript-language-server --prefix /usr/local"
    fi
  else
    log "typescript-language-server already present; skipping."
  fi
else
  log "WARN: npm not found; skipping typescript-language-server install"
fi

# --- 13) Claude Code plugins ---
if command -v claude >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/claude" ]]; then
  export PATH="${HOME}/.local/bin:${PATH}"
  claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
  claude plugin marketplace update claude-plugins-official 2>/dev/null || true
  claude plugin install claude-code-setup@claude-plugins-official 2>/dev/null || \
    log "WARN: claude-code-setup plugin install failed"
  claude plugin install security-guidance@claude-plugins-official 2>/dev/null || \
    log "WARN: security-guidance plugin install failed"
  claude plugin install frontend-design@claude-plugins-official 2>/dev/null || \
    log "WARN: frontend-design plugin install failed"
  claude plugin install code-review@claude-plugins-official 2>/dev/null || \
    log "WARN: code-review plugin install failed"
  claude plugin install code-simplifier@claude-plugins-official 2>/dev/null || \
    log "WARN: code-simplifier plugin install failed"
  claude plugin install rust-lsp@claude-plugins-official 2>/dev/null || \
    log "WARN: rust-lsp plugin install failed"
  claude plugin install typescript-lsp@claude-plugins-official 2>/dev/null || \
    log "WARN: typescript-lsp plugin install failed"
  claude plugin install gopls-lsp@claude-plugins-official 2>/dev/null || \
    log "WARN: gopls-lsp plugin install failed"
  claude plugin install pyright-lsp@claude-plugins-official 2>/dev/null || \
    log "WARN: pyright-lsp plugin install failed"
  claude plugin marketplace add jarrodwatts/claude-hud 2>/dev/null || true
  claude plugin install claude-hud 2>/dev/null || \
    log "WARN: claude-hud plugin install failed"
  claude plugin marketplace add JuliusBrussee/caveman 2>/dev/null || true
  claude plugin install caveman@caveman 2>/dev/null || \
    log "WARN: caveman plugin install failed"
  claude plugin marketplace add forrestchang/andrej-karpathy-skills 2>/dev/null || true
  claude plugin install andrej-karpathy-skills@karpathy-skills 2>/dev/null || \
    log "WARN: andrej-karpathy-skills plugin install failed"
  claude plugins install mattpocock-skills 2>/dev/null || \
    log "WARN: mattpocock-skills plugin install failed"
  claude plugin marketplace add JetBrains/go-modern-guidelines 2>/dev/null || true
  claude plugin install modern-go-guidelines@goland-claude-marketplace- 2>/dev/null || \
    log "WARN: modern-go-guidelines plugin install failed"
else
  log "WARN: claude CLI not found; skipping plugin installs"
fi

# --- 14) openspec (global npm) ---
# Note: bare `openspec` on npm is an abandoned 2019 stub (no bin). Real package is @fission-ai/openspec.
if command -v npm >/dev/null 2>&1; then
  if ! npm list -g @fission-ai/openspec >/dev/null 2>&1; then
    $SUDO npm install -g @fission-ai/openspec --prefix /usr/local || \
      log "WARN: openspec npm install failed"
  else
    log "openspec already installed globally; skipping."
  fi
else
  log "WARN: npm not found; skipping openspec install"
fi

# --- 15) Helm → /usr/local/bin (release tarball + sha256) ---
HELM_TAG="$(
  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: setup.sh' \
    https://api.github.com/repos/helm/helm/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
)"
HELM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/helm.XXXXXX")"
HELM_OK=0
if [[ -n "${HELM_TAG}" ]]; then
  HELM_TB="helm-${HELM_TAG}-linux-${GOARCH}.tar.gz"
  HELM_URL="https://get.helm.sh/${HELM_TB}"
  if curl -fsSL "${HELM_URL}" -o "${HELM_TMP}/${HELM_TB}" &&
    curl -fsSL "${HELM_URL}.sha256sum" -o "${HELM_TMP}/${HELM_TB}.sha256sum"; then
    HELM_WANT="$(awk '{ print $1; exit }' "${HELM_TMP}/${HELM_TB}.sha256sum")"
    HELM_GOT="$(sha256sum "${HELM_TMP}/${HELM_TB}" | awk '{ print $1 }')"
    if [[ -n "${HELM_WANT}" && "${HELM_WANT}" == "${HELM_GOT}" ]]; then
      tar -C "${HELM_TMP}" -xzf "${HELM_TMP}/${HELM_TB}"
      if $SUDO install -m 0755 "${HELM_TMP}/linux-${GOARCH}/helm" /usr/local/bin/helm; then
        HELM_OK=1
        log "helm installed: $(/usr/local/bin/helm version 2>/dev/null | head -n1 || true)"
      fi
    else
      log "WARN: helm tarball checksum mismatch (${HELM_TB})"
    fi
  else
    log "WARN: helm download failed (${HELM_TAG})"
  fi
else
  log "WARN: could not resolve helm latest release tag from GitHub API"
fi
rm -rf "${HELM_TMP}"
if [[ "${HELM_OK}" -ne 1 ]]; then
  log "WARN: helm not installed; fallback: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash"
fi

# --- 16) Shell completions (git + helm) for zsh ---
# git ships bash completions; contrib/completion/git-completion.zsh is the zsh wrapper and must
# be installed as `_git` on fpath, with a zstyle pointing it at the bash file it sources.
ZSH_COMPL_DIR="${HOME}/.config/zsh/completions"
mkdir -p "${ZSH_COMPL_DIR}"
GIT_COMPL_BASE="https://raw.githubusercontent.com/git/git/master/contrib/completion"
GIT_COMPL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-completion.XXXXXX")"
if curl -fsSL "${GIT_COMPL_BASE}/git-completion.bash" -o "${GIT_COMPL_TMP}/git-completion.bash" &&
  curl -fsSL "${GIT_COMPL_BASE}/git-completion.zsh" -o "${GIT_COMPL_TMP}/_git"; then
  # Move only after both downloads succeed, so a partial fetch never lands on fpath.
  install -m 0644 "${GIT_COMPL_TMP}/git-completion.bash" "${ZSH_COMPL_DIR}/git-completion.bash"
  install -m 0644 "${GIT_COMPL_TMP}/_git" "${ZSH_COMPL_DIR}/_git"
  log "git completion installed: ${ZSH_COMPL_DIR}/_git"
else
  log "WARN: git completion download failed; zsh's bundled _git will be used instead"
fi
rm -rf "${GIT_COMPL_TMP}"

if command -v helm >/dev/null 2>&1; then
  if helm completion zsh >"${ZSH_COMPL_DIR}/_helm" 2>/dev/null; then
    chmod 0644 "${ZSH_COMPL_DIR}/_helm"
    log "helm completion installed: ${ZSH_COMPL_DIR}/_helm"
  else
    rm -f "${ZSH_COMPL_DIR}/_helm"
    log "WARN: helm completion generation failed"
  fi
fi

# compinit is what actually turns the completions above on; -i skips insecure-dir prompts.
if [[ -f "${ZSHRC}" ]] && ! grep -q 'env-init: completions' "${ZSHRC}" 2>/dev/null; then
  cat >> "${ZSHRC}" <<'ZSHCOMPL'

# env-init: completions (git, helm)
fpath=("$HOME/.config/zsh/completions" $fpath)
zstyle ':completion:*:*:git:*' script "$HOME/.config/zsh/completions/git-completion.bash"
autoload -Uz compinit && compinit -i
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
ZSHCOMPL
fi

# bash users get git completion from the bash-completion package; source helm's there too.
BASHRC="${HOME}/.bashrc"
if [[ -f "${BASHRC}" ]] && ! grep -q 'env-init: completions' "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" <<'BASHCOMPL'

# env-init: completions (git, helm)
[[ -f /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
command -v helm >/dev/null 2>&1 && source <(helm completion bash)
BASHCOMPL
fi

log "Done. Open a new zsh session (or run: exec zsh) and run 'p10k configure' once to finish Powerlevel10k."
log "If zsh is not your login shell yet: chsh -s \"$(command -v zsh)\""
log ""
log "RTK init is interactive — run in a terminal after ~/.local/bin is on PATH (e.g. new zsh):"
log "  rtk init -g"
