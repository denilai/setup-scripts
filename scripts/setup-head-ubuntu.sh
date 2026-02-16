#!/usr/bin/env bash
# Setup script for Ubuntu head VM: packages, user, SSH hardening, fail2ban.
# Run as root or with sudo. Usage:
#   ./setup-head-ubuntu.sh [path-or-url-to-public-key.pub]
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." ./setup-head-ubuntu.sh
# Pipe from net (key taken from repo by default): wget -qO- URL/scripts/setup-head-ubuntu.sh | bash

set -euo pipefail

# --- Config: key from 1st arg, or env SSH_PUBLIC_KEY, or from this repo ---
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/denilai/setup-scripts/master}"
SSH_PUBLIC_KEY_SRC="${1:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
# Default: fetch key from this repo
if [[ -z "$SSH_PUBLIC_KEY_SRC" && -z "$SSH_PUBLIC_KEY" ]]; then
  SSH_PUBLIC_KEY_SRC="${REPO_RAW_BASE}/keys/deploy.pub"
fi
if [[ -n "$SSH_PUBLIC_KEY_SRC" && -z "$SSH_PUBLIC_KEY" ]]; then
  if [[ "$SSH_PUBLIC_KEY_SRC" =~ ^https?:// ]]; then
    if command -v wget &>/dev/null; then
      SSH_PUBLIC_KEY="$(wget -qO- "$SSH_PUBLIC_KEY_SRC")"
    elif command -v curl &>/dev/null; then
      SSH_PUBLIC_KEY="$(curl -sL "$SSH_PUBLIC_KEY_SRC")"
    else
      echo "Need wget or curl to fetch key from URL." >&2
      exit 1
    fi
  else
    SSH_PUBLIC_KEY="$(cat "$SSH_PUBLIC_KEY_SRC")"
  fi
fi

# Random one-word username (natural language words, safe for useradd)
RANDOM_NAMES=(
  amber basil cedar clover dawn echo flora grant hazel iris jade kai laurel
  moss nova olive pearl quinn river sage teal umbra vera willow yarrow zephyr
)
NEW_USER="${NEW_USER:-${RANDOM_NAMES[$((RANDOM % ${#RANDOM_NAMES[@]}))]}}"

# --- Helpers ---
need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root or with sudo." >&2
    exit 1
  fi
}

is_ubuntu() {
  [[ -f /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release
}

# --- 1. System update ---
system_update() {
  echo "[*] Updating packages and upgrading system..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

# --- 2. Install packages ---
install_packages() {
  echo "[*] Installing vim, dnsutils, net-tools, iproute2 (ss)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    vim \
    dnsutils \
    net-tools \
    iproute2
}

# --- 3. EDITOR in /etc/environment ---
set_editor_env() {
  echo "[*] Setting EDITOR in /etc/environment..."
  local vim_path
  vim_path="$(command -v vim || echo /usr/bin/vim)"
  if ! grep -q '^EDITOR=' /etc/environment; then
    echo "EDITOR=\"$vim_path\"" >> /etc/environment
  else
    sed -i "s|^EDITOR=.*|EDITOR=\"$vim_path\"|" /etc/environment
  fi
  export EDITOR="$vim_path"
}

# --- 4. Sudo group NOPASSWD via sudoers.d (validated with visudo) ---
sudo_nopasswd() {
  echo "[*] Configuring %sudo NOPASSWD..."
  local f="/etc/sudoers.d/90-sudo-nopasswd"
  echo '%sudo ALL=(ALL) NOPASSWD: ALL' > "$f"
  chmod 0440 "$f"
  visudo -cf "$f" || { rm -f "$f"; exit 1; }
}

# --- 5. Create user (random name), groups docker, -m, -s /bin/bash ---
create_user() {
  if id "$NEW_USER" &>/dev/null; then
    echo "[*] User $NEW_USER already exists, skipping creation."
    return 0
  fi
  echo "[*] Creating user: $NEW_USER (groups: sudo, docker), home, shell /bin/bash..."
  # Ensure docker group exists (create if docker not installed yet)
  getent group docker >/dev/null 2>&1 || groupadd docker
  useradd -m -s /bin/bash -G sudo,docker "$NEW_USER"
}

# --- 6. Add SSH public key for new user ---
add_ssh_key() {
  if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    echo "[!] No SSH public key provided. Skip with: SSH_PUBLIC_KEY= or pass a file: $0 /path/to/key.pub" >&2
    return 0
  fi
  echo "[*] Adding SSH key for $NEW_USER..."
  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  mkdir -p "$home/.ssh"
  echo "$SSH_PUBLIC_KEY" >> "$home/.ssh/authorized_keys"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"
  chown -R "$NEW_USER:$NEW_USER" "$home/.ssh"
}

# --- 7. Lock root password ---
lock_root_password() {
  echo "[*] Locking root password (passwd -l root)..."
  passwd -l root
}

# --- 8 & 9. SSH: disable root login, enable pubkey, best practices ---
harden_sshd() {
  echo "[*] Hardening sshd (drop-in in sshd_config.d)..."
  local dir="/etc/ssh/sshd_config.d"
  local dropin="$dir/90-hardening.conf"
  mkdir -p "$dir"
  # Drop-in overrides main config; no need to edit main file
  cat > "$dropin" << 'SSHD_EOF'
# Hardening: root login off, pubkey only, limits
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding no
PermitUserEnvironment no
SSHD_EOF
  chmod 644 "$dropin"
  sshd -t && systemctl reload sshd || { echo "sshd_config invalid, check $dropin" >&2; return 1; }
}

# --- 10. Install and configure fail2ban (sshd jail) ---
setup_fail2ban() {
  echo "[*] Installing and configuring fail2ban..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban

  local local_jail="/etc/fail2ban/jail.local"
  local local_sshd="/etc/fail2ban/jail.d/sshd.local"

  mkdir -p /etc/fail2ban/jail.d
  cat > "$local_jail" << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
EOF
  cat > "$local_sshd" << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
EOF

  systemctl enable --now fail2ban
  echo "[*] fail2ban enabled (sshd jail, 3 retries, 1h ban)."
}

# --- 11. Print snippet for local ~/.ssh/config ---
print_ssh_config_snippet() {
  local hostname_ip
  hostname_ip=""
  if command -v curl &>/dev/null; then
    hostname_ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$hostname_ip" ]] && command -v wget &>/dev/null; then
    hostname_ip="$(wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$hostname_ip" ]]; then
    hostname_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP_OR_HOSTNAME")"
  fi

  local host_alias="${SSH_CONFIG_HOST:-$NEW_USER}"
  local identity="${SSH_CONFIG_IDENTITY_FILE:-~/.ssh/id_ed25519}"
  local comment="${SSH_CONFIG_COMMENT:-}"

  echo ""
  echo "--- Add to your local ~/.ssh/config ---"
  echo ""
  [[ -n "$comment" ]] && echo "# $comment"
  echo "Host $host_alias"
  echo "  User $NEW_USER"
  echo "  Port 22"
  echo "  Hostname $hostname_ip"
  echo "  IdentityFile $identity"
  echo ""
}

# --- 12. Optional: speedtest ---
run_speedtest() {
  echo "[*] Running speedtest (speedtest.artydev.ru)..."
  if command -v wget &>/dev/null; then
    wget -qO- https://speedtest.artydev.ru | bash
  elif command -v curl &>/dev/null; then
    curl -sL https://speedtest.artydev.ru | bash
  else
    echo "[!] Need wget or curl for speedtest. Skipped." >&2
  fi
}

# --- 13. Optional: vps-audit ---
run_vps_audit() {
  echo "[*] Downloading and running vps-audit..."
  local audit_script="/tmp/vps-audit.sh"
  local url="https://raw.githubusercontent.com/vernu/vps-audit/main/vps-audit.sh"
  if command -v wget &>/dev/null; then
    wget -qO "$audit_script" "$url" || { echo "[!] Failed to download vps-audit. Skipped." >&2; return 0; }
  elif command -v curl &>/dev/null; then
    curl -sL -o "$audit_script" "$url" || { echo "[!] Failed to download vps-audit. Skipped." >&2; return 0; }
  else
    echo "[!] Need wget or curl for vps-audit. Skipped." >&2
    return 0
  fi
  chmod +x "$audit_script"
  "$audit_script"
  rm -f "$audit_script"
}

# --- Main ---
main() {
  need_root
  if ! is_ubuntu; then
    echo "This script targets Ubuntu. Aborting." >&2
    exit 1
  fi

  # Avoid locking yourself out: we disable root + password auth, so key is required
  if [[ -z "${SKIP_SSH_KEY_CHECK:-}" && -z "$SSH_PUBLIC_KEY" ]]; then
    echo "WARNING: No SSH public key. After script, only key-based login for $NEW_USER will work." >&2
    echo "Pass key: $0 ~/.ssh/id_ed25519.pub  or  $0 https://raw.../keys/deploy.pub  or  SSH_PUBLIC_KEY=\"...\" $0" >&2
    echo "To run anyway: SKIP_SSH_KEY_CHECK=1 $0" >&2
    exit 1
  fi

  system_update
  install_packages
  set_editor_env
  sudo_nopasswd
  create_user
  add_ssh_key
  lock_root_password
  harden_sshd
  setup_fail2ban

  print_ssh_config_snippet

  echo "Done. New sudo+docker user: $NEW_USER"
  echo "Ensure you can log in as $NEW_USER with your SSH key before closing this session."
  echo "Override username: NEW_USER=myuser $0"

  if [[ -n "${RUN_SPEEDTEST:-}" ]]; then
    run_speedtest
  fi
  if [[ -n "${RUN_VPS_AUDIT:-}" ]]; then
    run_vps_audit
  fi
}

main "$@"
