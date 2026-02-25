#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Gas Town Factory Setup Script
# =============================================================================
# Creates a fully functional Gas Town multi-agent workspace from scratch.
#
# Two modes:
#   Root mode  — OS provisioning (user, SSH, Tailscale)
#   User mode  — Dev tools, Gas Town, services
# =============================================================================

# =============================================================================
# Helper: prompt for a non-empty value (no default)
# =============================================================================
prompt() {
  local var_name="$1" prompt_text="$2" value=""
  while [[ -z "$value" ]]; do
    read -rp "$prompt_text" value
  done
  printf -v "$var_name" '%s' "$value"
}

# =============================================================================
# Root mode
# =============================================================================
if [[ $EUID -eq 0 ]]; then

  # --- Gather input -----------------------------------------------------------
  prompt HOSTNAME   "Hostname: "
  prompt USERNAME   "Username: "
  prompt SSH_PUBKEY "SSH public key: "

  # Set hostname
  echo ">>> Setting hostname to ${HOSTNAME}"
  hostnamectl set-hostname "$HOSTNAME"

  # Install sudo
  if ! command -v sudo &>/dev/null; then
    echo ">>> Installing sudo"
    apt-get update && apt-get install -y sudo
  else
    echo ">>> sudo already installed"
  fi

  # Create user with passwordless sudo and SSH key
  if id "$USERNAME" &>/dev/null; then
    echo ">>> User ${USERNAME} already exists"
  else
    echo ">>> Creating user ${USERNAME}"
    useradd -m -s /bin/bash "$USERNAME"
    passwd -d "$USERNAME"
  fi

  SSH_DIR="/home/${USERNAME}/.ssh"
  mkdir -p "$SSH_DIR"
  if ! grep -qF "$SSH_PUBKEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    echo ">>> Adding SSH public key"
    echo "$SSH_PUBKEY" >> "$SSH_DIR/authorized_keys"
  else
    echo ">>> SSH key already present"
  fi
  chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  chmod 600 "$SSH_DIR/authorized_keys"

  SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"
  if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo ">>> Configuring passwordless sudo for ${USERNAME}"
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
  else
    echo ">>> Sudoers entry already exists"
  fi

  # Install curl + Tailscale
  if ! command -v curl &>/dev/null; then
    echo ">>> Installing curl"
    apt-get update && apt-get install -y curl
  else
    echo ">>> curl already installed"
  fi

  if ! command -v tailscale &>/dev/null; then
    echo ">>> Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    echo ">>> Tailscale already installed"
  fi

  # Tailscale up
  tailscale up

  echo ""
  echo ">>> Root setup complete. Now log in as ${USERNAME} and run setup.sh again."

# =============================================================================
# User mode
# =============================================================================
else

  # --- SSH key setup ----------------------------------------------------------
  SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
  SSH_PRIVATE_KEY=""
  SSH_KEY_PASSPHRASE=""

  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "Paste your SSH private key (ends with '-----END OPENSSH PRIVATE KEY-----'):"
    while IFS= read -r line; do
      SSH_PRIVATE_KEY+="$line"$'\n'
      [[ "$line" == *"END OPENSSH PRIVATE KEY"* ]] && break
    done
    read -rsp "Key passphrase (leave empty if none): " SSH_KEY_PASSPHRASE
    echo ""
  fi

  # --- Install dev packages ---------------------------------------------------
  PACKAGES=(build-essential git libicu-dev libzstd-dev sqlite3 tmux curl)
  MISSING=()
  for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
      MISSING+=("$pkg")
    fi
  done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ">>> Installing dev packages: ${MISSING[*]}"
    sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
  else
    echo ">>> Dev packages already installed"
  fi

  # --- Write SSH private key ---------------------------------------------------
  if [[ -n "$SSH_PRIVATE_KEY" ]]; then
    echo ">>> Writing SSH private key"
    mkdir -p "$HOME/.ssh"
    echo -n "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"

    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
      echo ">>> Stripping passphrase from key"
      ssh-keygen -p -f "$SSH_KEY_PATH" -P "$SSH_KEY_PASSPHRASE" -N ""
    fi
  elif [[ -f "$SSH_KEY_PATH" ]]; then
    echo ">>> SSH key already exists at ${SSH_KEY_PATH}"
  fi

  # --- Install Go from go.dev -------------------------------------------------
  if command -v go &>/dev/null; then
    echo ">>> Go already installed ($(go version))"
  else
    echo ">>> Installing Go from go.dev"
    GO_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
    GO_VERSION="$(echo "$GO_JSON" | grep -m1 '"version"' | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    ARCH="$(dpkg --print-architecture)"
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
  fi

  # --- Add Go, ~/.local/bin, and /usr/local/bin to PATH -----------------------
  PATH_LINE='export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"'
  if grep -qF '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo ">>> Updating PATH in .bashrc"
    sed -i '/\/usr\/local\/go\/bin/d' "$HOME/.bashrc"
  else
    echo ">>> Adding PATH to .bashrc"
  fi
  sed -i '/\.local\/bin.*go\/bin/d' "$HOME/.bashrc"
  echo "$PATH_LINE" >> "$HOME/.bashrc"
  export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"

  # --- Install Claude Code ----------------------------------------------------
  if command -v claude &>/dev/null; then
    echo ">>> Claude Code already installed"
  else
    echo ">>> Installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash
  fi

  echo ">>> Launching Claude to force login..."
  claude

  # --- Install gh CLI ---------------------------------------------------------
  if command -v gh &>/dev/null; then
    echo ">>> gh already installed"
  else
    echo ">>> Installing gh"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update && sudo apt-get install -y gh
  fi

  # --- Authenticate with GitHub ------------------------------------------------
  if gh auth status &>/dev/null 2>&1; then
    echo ">>> Already authenticated with GitHub"
  else
    echo ">>> Authenticating with GitHub"
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
  fi

  # --- Configure git identity --------------------------------------------------
  echo ">>> Setting git identity from GitHub profile"
  GIT_NAME="$(gh api user --jq '.name')"
  if [[ -z "$GIT_NAME" || "$GIT_NAME" == "null" ]]; then
    GIT_NAME="$(gh api user --jq '.login')"
  fi
  GIT_EMAIL="$(gh api user --jq '.email')"
  if [[ -z "$GIT_EMAIL" || "$GIT_EMAIL" == "null" ]]; then
    GIT_EMAIL="$(gh api user --jq '.login')@localhost"
  fi
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
  echo "    name:  $GIT_NAME"
  echo "    email: $GIT_EMAIL"

  echo ">>> Configuring git to use gh"
  gh auth setup-git

  git config --global init.defaultBranch main

  # --- Install dolt ------------------------------------------------------------
  if command -v dolt &>/dev/null; then
    echo ">>> dolt already installed ($(dolt version))"
  else
    echo ">>> Installing dolt"
    sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
  fi

  # Configure dolt identity
  echo ">>> Configuring dolt identity"
  dolt config --global --add user.name "$GIT_NAME" 2>/dev/null || true
  dolt config --global --add user.email "$GIT_EMAIL" 2>/dev/null || true

  # --- Install beads from source ------------------------------------------------
  BEADS_SRC="$HOME/src/beads"
  if command -v bd &>/dev/null; then
    echo ">>> beads already installed"
  else
    echo ">>> Installing beads from source"
    mkdir -p "$HOME/src"
    git clone https://github.com/steveyegge/beads.git "$BEADS_SRC"
    (cd "$BEADS_SRC" && go build -o "$HOME/go/bin/bd" ./cmd/bd)
  fi

  # --- Install gastown from source ---------------------------------------------
  GASTOWN_SRC="$HOME/src/gastown"
  if command -v gt &>/dev/null; then
    echo ">>> gastown already installed"
  else
    echo ">>> Installing gastown from source"
    mkdir -p "$HOME/src"
    git clone https://github.com/steveyegge/gastown.git "$GASTOWN_SRC"
    sed -i 's/json:"last_heartbeat"/json:"timestamp"/' "$GASTOWN_SRC/internal/web/fetcher.go"
    (cd "$GASTOWN_SRC" && go build -o "$HOME/go/bin/gt" ./cmd/gt)
  fi

  # --- Install Gas Town HQ ----------------------------------------------------
  if [[ -d "$HOME/gt/mayor" ]]; then
    echo ">>> Gas Town HQ already exists at ~/gt"
  else
    echo ">>> Installing Gas Town HQ"
    gt install "$HOME/gt" --shell
  fi

  # --- Enable Gas Town ---------------------------------------------------------
  echo ">>> Enabling Gas Town"
  (cd "$HOME/gt" && gt enable 2>&1) || echo ">>> gt enable had issues (may be OK)"

  # --- Initialize git repo for HQ ----------------------------------------------
  echo ">>> Initializing HQ git repo"
  (cd "$HOME/gt" && gt git-init 2>&1) || echo ">>> gt git-init had issues"

  # --- Prime identity anchor ----------------------------------------------------
  echo ">>> Priming CLAUDE.md identity anchor"
  (cd "$HOME/gt" && gt prime 2>&1) || echo ">>> gt prime had issues"

  # --- Start services ----------------------------------------------------------
  echo ">>> Starting Gas Town services"
  (cd "$HOME/gt" && gt up 2>&1) || echo ">>> gt up had issues"

  echo ">>> Waiting for services to stabilize..."
  sleep 3

  # --- systemd services --------------------------------------------------------
  echo ">>> Setting up Gas Town dashboard service"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/gastown-dashboard.service" << EOF
[Unit]
Description=Gas Town Dashboard
After=network.target

[Service]
Type=simple
ExecStart=$HOME/go/bin/gt dashboard --port 8080
WorkingDirectory=$HOME/gt
Restart=on-failure
RestartSec=5s
Environment=PATH=$HOME/.local/bin:$HOME/go/bin:/usr/local/bin:/usr/local/go/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now gastown-dashboard
  sudo loginctl enable-linger "$USER"

  echo ">>> Setting up Gas Town daemon service"
  (cd "$HOME/gt" && gt daemon enable-supervisor)
  DAEMON_UNIT="$HOME/.local/share/systemd/user/gastown-daemon.service"
  if [[ -f "$DAEMON_UNIT" ]] && ! grep -q '^Environment=.*PATH=' "$DAEMON_UNIT"; then
    sed -i '/^\[Service\]/a Environment="PATH='"$HOME"'/.local/bin:'"$HOME"'/go/bin:/usr/local/bin:/usr/local/go/bin:/usr/bin:/bin"' "$DAEMON_UNIT"
    systemctl --user daemon-reload
    systemctl --user restart gastown-daemon
  fi

  # --- Final verification ------------------------------------------------------
  echo ""
  echo ">>> Running final health check..."
  DOCTOR_EXIT=0
  (cd "$HOME/gt" && gt doctor 2>&1) || DOCTOR_EXIT=$?

  echo ""
  if [[ $DOCTOR_EXIT -eq 0 ]]; then
    echo "============================================="
    echo "  Gas Town setup complete! All checks pass."
    echo "============================================="
  else
    echo "============================================="
    echo "  Gas Town setup complete (with warnings)."
    echo "  Run 'cd ~/gt && gt doctor -v' for details."
    echo "============================================="
  fi
  echo ""
  echo "Next steps: (dashboard running at http://localhost:8080)"
  echo "  1. Add a project rig:         gt rig add <name> <git-url>"
  echo "  2. Check health:              gt doctor"
  echo "  3. Enter Mayor's office:      gt mayor attach"
  echo ""
  echo "Quick start:"
  echo "  gt rig add <name> <git-url>"
  echo "  gt mayor attach"
  echo ""
  echo "Run: source ~/.bashrc && cd ~/gt"
  echo ""
fi
