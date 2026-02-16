#!/usr/bin/env bash
# Setup script for Ubuntu head VM: packages, user, SSH hardening, fail2ban.
# Run as root or with sudo. Usage:
#   ./setup-head-ubuntu.sh [path-or-url-to-public-key.pub]
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." ./setup-head-ubuntu.sh
# Pipe from net (key taken from repo by default): wget -qO- URL/scripts/setup-head-ubuntu.sh | bash

set -euo pipefail

log() { echo "[*] $*"; }
log_err() { echo "[!] $*" >&2; }
echo "[*] setup-head-ubuntu.sh started."

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
      SSH_PUBLIC_KEY="$(wget -qO- "$SSH_PUBLIC_KEY_SRC" 2>/dev/null)" || SSH_PUBLIC_KEY=""
    elif command -v curl &>/dev/null; then
      SSH_PUBLIC_KEY="$(curl -sL "$SSH_PUBLIC_KEY_SRC" 2>/dev/null)" || SSH_PUBLIC_KEY=""
    else
      log_err "Need wget or curl to fetch key from URL."
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
    log_err "Run as root or with sudo."
    exit 1
  fi
}

is_ubuntu() {
  [[ -f /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release
}

# --- 1. System update ---
system_update() {
  log "Updating packages and upgrading system..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

# --- 2. Install packages ---
install_packages() {
  log "Installing vim, dnsutils, net-tools, iproute2 (ss)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    vim \
    dnsutils \
    net-tools \
    iproute2
}

# --- 3. Disable IPv6, enable IP forwarding (routing through host) ---
setup_sysctl() {
  log "Configuring sysctl: disable IPv6, enable ip_forward..."
  local f="/etc/sysctl.d/90-head-vm.conf"
  cat > "$f" << 'EOF'
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# Allow routing through host (NAT, tunnels, etc.)
net.ipv4.ip_forward = 1
EOF
  sysctl -p "$f" 2>/dev/null || true
  log "sysctl applied (IPv6 off, ip_forward on)."
}

# --- 4. EDITOR in /etc/environment ---
set_editor_env() {
  log "Setting EDITOR in /etc/environment..."
  local vim_path
  vim_path="$(command -v vim || echo /usr/bin/vim)"
  if ! grep -q '^EDITOR=' /etc/environment; then
    echo "EDITOR=\"$vim_path\"" >> /etc/environment
  else
    sed -i "s|^EDITOR=.*|EDITOR=\"$vim_path\"|" /etc/environment
  fi
  export EDITOR="$vim_path"
}

# --- 5. Sudo group NOPASSWD via sudoers.d (validated with visudo) ---
sudo_nopasswd() {
  log "Configuring %sudo NOPASSWD..."
  local f="/etc/sudoers.d/90-sudo-nopasswd"
  mkdir -p "$(dirname "$f")"
  echo '%sudo ALL=(ALL) NOPASSWD: ALL' > "$f"
  chmod 0440 "$f"
  visudo -cf "$f" || { rm -f "$f"; exit 1; }
}

# --- 6. Create user (random name), groups docker, -m, -s /bin/bash ---
create_user() {
  if id "$NEW_USER" &>/dev/null; then
    log "User $NEW_USER already exists, skipping creation."
    return 0
  fi
  log "Creating user: $NEW_USER (groups: sudo, docker), home, shell /bin/bash..."
  # Ensure docker group exists (create if docker not installed yet)
  getent group docker >/dev/null 2>&1 || groupadd docker
  useradd -m -s /bin/bash -G sudo,docker "$NEW_USER"
}

# --- 7. Add SSH public key for new user ---
add_ssh_key() {
  if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    log_err "No SSH public key provided. Skip with: SSH_PUBLIC_KEY= or pass a file: $0 /path/to/key.pub"
    return 0
  fi
  log "Adding SSH key for $NEW_USER..."
  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  mkdir -p "$home/.ssh"
  echo "$SSH_PUBLIC_KEY" >> "$home/.ssh/authorized_keys"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"
  chown -R "$NEW_USER:$NEW_USER" "$home/.ssh"
}

# --- 8. Lock root password ---
lock_root_password() {
  log "Locking root password (passwd -l root)..."
  passwd -l root
}

# --- 9. SSH: disable root login, enable pubkey, best practices ---
harden_sshd() {
  log "Hardening sshd (drop-in in sshd_config.d)..."
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
  mkdir -p /run/sshd
  sshd -t || { log_err "sshd_config invalid, check $dropin"; return 1; }
  systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# --- 10. Install and configure fail2ban (sshd jail) ---
setup_fail2ban() {
  log "Installing and configuring fail2ban..."
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

  systemctl enable --now fail2ban 2>/dev/null || true
  log "fail2ban configured (sshd jail, 3 retries, 1h ban)."
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
  # Reject response if it looks like HTML or multi-word
  if [[ -z "$hostname_ip" || "$hostname_ip" =~ [\ \<\>] ]]; then
    hostname_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP_OR_HOSTNAME")"
  fi
  if [[ -z "$hostname_ip" || "$hostname_ip" =~ [\ \<\>] ]]; then
    hostname_ip="IP_OR_HOSTNAME"
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
  log "Running speedtest (speedtest.artydev.ru)..."
  if command -v wget &>/dev/null; then
    wget -qO- https://speedtest.artydev.ru | bash
  elif command -v curl &>/dev/null; then
    curl -sL https://speedtest.artydev.ru | bash
  else
    log_err "Need wget or curl for speedtest. Skipped."
  fi
}

# --- 13. Optional: vps-audit ---
run_vps_audit() {
  log "Downloading and running vps-audit..."
  local audit_script="/tmp/vps-audit.sh"
  local url="https://raw.githubusercontent.com/vernu/vps-audit/main/vps-audit.sh"
  if command -v wget &>/dev/null; then
    wget -qO "$audit_script" "$url" || { log_err "Failed to download vps-audit. Skipped."; return 0; }
  elif command -v curl &>/dev/null; then
    curl -sL -o "$audit_script" "$url" || { log_err "Failed to download vps-audit. Skipped."; return 0; }
  else
    log_err "Need wget or curl for vps-audit. Skipped."
    return 0
  fi
  chmod +x "$audit_script"
  "$audit_script"
  rm -f "$audit_script"
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
  log "Running speedtest (speedtest.artydev.ru)..."
  if command -v wget &>/dev/null; then
    wget -qO- https://speedtest.artydev.ru | bash
  elif command -v curl &>/dev/null; then
    curl -sL https://speedtest.artydev.ru | bash
  else
    log_err "Need wget or curl for speedtest. Skipped."
  fi
}

# --- 13. Optional: vps-audit ---
run_vps_audit() {
  log "Downloading and running vps-audit..."
  local audit_script="/tmp/vps-audit.sh"
  local url="https://raw.githubusercontent.com/vernu/vps-audit/main/vps-audit.sh"
  if command -v wget &>/dev/null; then
    wget -qO "$audit_script" "$url" || { log_err "Failed to download vps-audit. Skipped."; return 0; }
  elif command -v curl &>/dev/null; then
    curl -sL -o "$audit_script" "$url" || { log_err "Failed to download vps-audit. Skipped."; return 0; }
  else
    log_err "Need wget or curl for vps-audit. Skipped."
    return 0
  fi
  chmod +x "$audit_script"
  "$audit_script"
  rm -f "$audit_script"
}

# --- Main ---
main() {
  need_root
  log "setup-head-ubuntu.sh started."

  if ! is_ubuntu; then
    log_err "This script targets Ubuntu. Aborting."
    exit 1
  fi

  # Avoid locking yourself out: we disable root + password auth, so key is required
  if [[ -z "${SKIP_SSH_KEY_CHECK:-}" && -z "$SSH_PUBLIC_KEY" ]]; then
    log_err "No SSH public key. After script, only key-based login for $NEW_USER will work."
    log_err "Pass key: $0 ~/.ssh/id_ed25519.pub  or  $0 https://raw.../keys/deploy.pub  or  SSH_PUBLIC_KEY=\"...\" $0"
    log_err "To run anyway: SKIP_SSH_KEY_CHECK=1 $0"
    exit 1
  fi

  system_update
  install_packages
  setup_sysctl
  set_editor_env
  sudo_nopasswd
  create_user
  add_ssh_key
  lock_root_password
  harden_sshd
  setup_fail2ban

  print_ssh_config_snippet

  log "Done. New sudo+docker user: $NEW_USER"
  log "Ensure you can log in as $NEW_USER with your SSH key before closing this session."
  echo "Override username: NEW_USER=myuser $0"

  if [[ -n "${RUN_SPEEDTEST:-}" ]]; then
    run_speedtest
  fi
  if [[ -n "${RUN_VPS_AUDIT:-}" ]]; then
    run_vps_audit
  fi
}

main "$@"
