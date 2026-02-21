#!/usr/bin/env bash
set -euo pipefail

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

  # --- Gather input -----------------------------------------------------------
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

  # Install dev packages
  PACKAGES=(build-essential git libicu-dev sqlite3 tmux)
  MISSING=()
  for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      MISSING+=("$pkg")
    fi
  done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ">>> Installing dev packages: ${MISSING[*]}"
    sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
  else
    echo ">>> Dev packages already installed"
  fi

  # Write SSH private key
  if [[ -n "$SSH_PRIVATE_KEY" ]]; then
    echo ">>> Writing SSH private key"
    mkdir -p "$HOME/.ssh"
    echo -n "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"

    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
      echo ">>> Stripping passphrase from key"
      ssh-keygen -p -f "$SSH_KEY_PATH" -P "$SSH_KEY_PASSPHRASE" -N ""
    fi
  else
    echo ">>> SSH key already exists at ${SSH_KEY_PATH}"
  fi

  # Install Go from go.dev
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

  # Add Go, ~/.local/bin, and /usr/local/bin to PATH
  # /usr/local/bin is needed because dolt installs there via its install.sh
  PATH_LINES='export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"'
  if grep -qF '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo ">>> Updating PATH in .bashrc"
    sed -i '/\/usr\/local\/go\/bin/d' "$HOME/.bashrc"
  else
    echo ">>> Adding PATH to .bashrc"
  fi
  # Remove old .local/bin-only line if present
  sed -i '/\.local\/bin.*go\/bin/d' "$HOME/.bashrc"
  echo "$PATH_LINES" >> "$HOME/.bashrc"
  export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"

  # Install Claude Code
  if command -v claude &>/dev/null; then
    echo ">>> Claude Code already installed"
  else
    echo ">>> Installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash
  fi

  # Launch Claude to force login
  echo ">>> Launching Claude to force login..."
  claude

  # Install gh CLI
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

  # Authenticate with GitHub
  if gh auth status &>/dev/null 2>&1; then
    echo ">>> Already authenticated with GitHub"
  else
    echo ">>> Authenticating with GitHub"
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
  fi

  # Configure git credential helper
  echo ">>> Configuring git to use gh"
  gh auth setup-git

  # Auto-detect git identity from GitHub profile
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
  git config --global init.defaultBranch main
  echo "    name:  $GIT_NAME"
  echo "    email: $GIT_EMAIL"

  # Install dolt
  if command -v dolt &>/dev/null; then
    echo ">>> dolt already installed ($(dolt version))"
  else
    echo ">>> Installing dolt"
    sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
  fi

  # Configure dolt identity
  echo ">>> Configuring dolt identity"
  dolt config --global --add user.name "$GIT_NAME"
  dolt config --global --add user.email "$GIT_EMAIL"

  # Install beads
  if command -v bd &>/dev/null; then
    echo ">>> beads already installed ($(bd --version))"
  else
    echo ">>> Installing beads (bd)"
    go install github.com/steveyegge/beads/cmd/bd@latest
  fi

  # HACK: gastown v0.7.0 vs beads v0.55.4 compatibility shim.
  # 1) gt passes --backend dolt, but bd removed that flag (Dolt is now the only backend).
  # 2) gt's EnsureMetadata creates .beads/metadata.json before bd init, so bd thinks
  #    it's already initialized and skips creating config.yaml. Adding --force fixes this.
  # Remove this wrapper once gastown is updated for beads v0.55+.
  echo ">>> Installing bd wrapper (gastown/beads compat shim)"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/bd" << 'WRAPPER'
#!/usr/bin/env bash
# HACK: gastown v0.7.0 / beads v0.55.4 compat shim
# - Strip --backend <value> (flag removed; Dolt is now the only backend)
# - Inject --force on init (gastown pre-creates metadata.json, causing bd to
#   think it's already initialized and skip config.yaml creation)
args=(); skip=false; is_init=false
for arg in "$@"; do
  if $skip; then skip=false; continue; fi
  if [[ "$arg" == "--backend" ]]; then skip=true; continue; fi
  [[ "$arg" == "init" ]] && is_init=true
  args+=("$arg")
done
if $is_init; then
  # Add --force unless already present
  for a in "${args[@]}"; do [[ "$a" == "--force" ]] && { is_init=false; break; }; done
  $is_init && args+=(--force)
fi
exec "$HOME/go/bin/bd" "${args[@]}"
WRAPPER
  chmod +x "$HOME/.local/bin/bd"

  # Install gastown and patch before starting any services
  if command -v gt &>/dev/null; then
    echo ">>> gastown already installed ($(gt --version))"
  else
    echo ">>> Installing gastown (gt)"
    go install github.com/steveyegge/gastown/cmd/gt@latest
  fi

  # HACK: gastown v0.7.0 dashboard heartbeat bug.
  # FetchHealth reads the heartbeat JSON field as "last_heartbeat", but the Deacon
  # writes it as "timestamp" (internal/deacon/heartbeat.go). This causes the
  # dashboard to always show "no timestamp". Patch the source and rebuild.
  # Remove this once gastown fixes the json tag in internal/web/fetcher.go.
  GT_MOD_DIR="$HOME/go/pkg/mod/github.com/steveyegge/gastown@v0.7.0"
  if [[ -d "$GT_MOD_DIR" ]]; then
    FETCHER="$GT_MOD_DIR/internal/web/fetcher.go"
    if grep -q 'json:"last_heartbeat"' "$FETCHER" 2>/dev/null; then
      echo ">>> Patching gastown v0.7.0 heartbeat json tag (HACK)"
      chmod -R u+w "$GT_MOD_DIR"
      sed -i 's/json:"last_heartbeat"/json:"timestamp"/' "$FETCHER"
      (cd "$GT_MOD_DIR" && go install ./cmd/gt)
    fi
  fi

  # HACK: gastown v0.7.0 polecat session naming bug.
  # SpawnPolecatForSling doesn't call session.InitRegistry(), so PrefixFor()
  # returns "gt" (default) for all rigs. Sessions get named gt-<name> instead
  # of <rig-prefix>-<name>. The witness can't find the session and nukes the
  # worktree while the polecat is still running.
  # Remove this once gastown initializes the prefix registry in sling/spawn.
  if [[ -d "$GT_MOD_DIR" ]]; then
    SPAWN_FILE="$GT_MOD_DIR/internal/cmd/polecat_spawn.go"
    if [[ -f "$SPAWN_FILE" ]] && ! grep -q 'session.InitRegistry' "$SPAWN_FILE" 2>/dev/null; then
      echo ">>> Patching gastown v0.7.0 polecat session naming (HACK)"
      chmod -R u+w "$GT_MOD_DIR"
      # Add session import
      sed -i '/"github.com\/steveyegge\/gastown\/internal\/tmux"/i\\t"github.com/steveyegge/gastown/internal/session"' "$SPAWN_FILE"
      # Add InitRegistry call after townRoot is resolved
      sed -i '/\/\/ Load rig config/i\\t// HACK: gastown v0.7.0 session naming bug.\n\t// Without InitRegistry, PrefixFor() returns "gt" for all rigs,\n\t// causing sessions to be named gt-<name> instead of <prefix>-<name>.\n\t// The witness then can'\''t find the session and nukes the worktree.\n\t_ = session.InitRegistry(townRoot)\n' "$SPAWN_FILE"
      (cd "$GT_MOD_DIR" && go install ./cmd/gt)
    fi
  fi

  # HACK: beads v0.55.4 ephemeral transaction routing bug.
  # doltTransaction.CreateIssue and AddDependency write directly to Dolt SQL,
  # bypassing the ephemeral SQLite routing that DoltStore.CreateIssue uses.
  # This causes `gt sling` to fail when instantiating mol-polecat-work: wisps
  # created via RunInTransaction go to Dolt, but SearchIssues routes "-wisp-"
  # IDs to the empty SQLite ephemeral store → "not found".
  #
  # CreateIssue routing must go AFTER the ID generation block (lines 67-92),
  # not at the top of the function. Otherwise ephemeral issues get routed to
  # SQLite with empty IDs (the Dolt tx generates IDs, SQLite store does not).
  #
  # AddDependency routing goes at the top (no ID generation needed there).
  #
  # Additionally, the ephemeral store uses plain INSERT which fails on retry
  # after partial formula failure. Patched to INSERT OR REPLACE for idempotency.
  #
  # Remove all of this once beads fixes doltTransaction ephemeral routing.
  BD_MOD_DIR="$HOME/go/pkg/mod/github.com/steveyegge/beads@v0.55.4"
  if [[ -d "$BD_MOD_DIR" ]]; then
    TX_FILE="$BD_MOD_DIR/internal/storage/dolt/transaction.go"
    if [[ -f "$TX_FILE" ]] && ! grep -q 'ephemeralStore' "$TX_FILE" 2>/dev/null; then
      echo ">>> Patching beads v0.55.4 ephemeral transaction routing (HACK)"
      chmod -R u+w "$BD_MOD_DIR"

      # Patch CreateIssue: add ephemeral routing BEFORE insertIssueTx
      # (AFTER ID generation so the wisp gets a proper i0-wisp-xxx ID)
      sed -i '/return insertIssueTx(ctx, t.tx, issue)/i\
\t// HACK: route ephemeral issues to SQLite (after ID generation)\
\tif issue.Ephemeral \&\& t.store.EphemeralStore() != nil {\
\t\treturn t.store.EphemeralStore().CreateIssue(ctx, issue, actor)\
\t}' "$TX_FILE"

      # Patch AddDependency: add ephemeral routing before the existing body
      sed -i '/^func (t \*doltTransaction) AddDependency(ctx context.Context, dep \*types.Dependency, actor string) error {$/a\
\t// HACK: route ephemeral deps to SQLite (mirrors DoltStore.AddDependency)\
\tif IsEphemeralID(dep.IssueID) \&\& t.store.EphemeralStore() != nil {\
\t\treturn t.store.EphemeralStore().AddDependency(ctx, dep, actor)\
\t}' "$TX_FILE"

      # Rebuild beads with the patch
      (cd "$BD_MOD_DIR" && go install ./cmd/bd)
    fi

    # HACK: beads v0.55.4 ephemeral insertIssue uses plain INSERT which fails
    # with UNIQUE constraint when sling retries after partial formula failure.
    # Wisps are transient — INSERT OR REPLACE is correct idempotent behavior.
    EPH_ISSUES="$BD_MOD_DIR/internal/storage/ephemeral/issues.go"
    if [[ -f "$EPH_ISSUES" ]] && ! grep -q 'INSERT OR REPLACE INTO issues' "$EPH_ISSUES" 2>/dev/null; then
      echo ">>> Patching beads v0.55.4 ephemeral INSERT → INSERT OR REPLACE (HACK)"
      chmod -R u+w "$BD_MOD_DIR"
      sed -i "s/\`INSERT INTO issues (/\`INSERT OR REPLACE INTO issues (/" "$EPH_ISSUES"
      (cd "$BD_MOD_DIR" && go install ./cmd/bd)
    fi
  fi

  # Install Gas Town HQ
  if [[ -d "$HOME/gt/mayor" ]]; then
    echo ">>> Gas Town HQ already exists at ~/gt"
  else
    echo ">>> Installing Gas Town HQ"
    gt install "$HOME/gt" --git
  fi

  # Dashboard systemd service
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
  # Allow user services to run without active login session
  sudo loginctl enable-linger "$USER"

  # Daemon systemd service (writes heartbeats, pokes agents)
  # enable-supervisor generates gastown-daemon.service and starts it via
  # systemctl --user enable --now.
  echo ">>> Setting up Gas Town daemon service"
  (cd "$HOME/gt" && gt daemon enable-supervisor)
  # The generated service lacks PATH; patch it and restart.
  DAEMON_UNIT="$HOME/.local/share/systemd/user/gastown-daemon.service"
  if [[ -f "$DAEMON_UNIT" ]] && ! grep -q '^Environment=.*PATH=' "$DAEMON_UNIT"; then
    sed -i '/^\[Service\]/a Environment="PATH='"$HOME"'/.local/bin:'"$HOME"'/go/bin:/usr/local/bin:/usr/local/go/bin:/usr/bin:/bin"' "$DAEMON_UNIT"
    systemctl --user daemon-reload
    systemctl --user restart gastown-daemon
  fi

  echo ""
  echo ">>> User setup complete!"
  echo ">>> Run 'source ~/.bashrc' or start a new shell to pick up PATH changes."
  echo ">>> Dashboard running at http://localhost:8080"
fi
