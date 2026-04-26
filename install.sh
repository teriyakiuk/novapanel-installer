#!/usr/bin/env bash
#
# NovaPanel Installer
# https://novapanel.dev
#
# One-line install on a fresh Ubuntu 24.04 server:
#
#   curl -fsSL https://novapanel.dev/install.sh | sudo bash
#
# Or with a Pro license key from the start:
#
#   curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- --key NOVA-xxxx-...
#
# The installer sets up the system, fetches a Community license bound to
# this server's fingerprint, downloads the NovaPanel binary from the
# license-gated CDN, and starts the panel. Customers can upgrade to Pro
# from the admin UI later (Config -> License).
#
set -uo pipefail

# ─────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────
LICENSE_SERVER="${LICENSE_SERVER:-https://license.novapanel.dev}"
NOVA_USER="${NOVA_USER:-novapanel}"
NOVA_DIR="${NOVA_DIR:-/opt/novapanel}"
NOVA_DATA="${NOVA_DATA:-/var/lib/novapanel}"
NOVA_LOG="${NOVA_LOG:-/var/log/novapanel}"
NOVA_LICENSE_DIR="${NOVA_LICENSE_DIR:-/etc/novapanel}"
PROVIDED_KEY=""
NON_INTERACTIVE=0
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-}"

# ─────────────────────────────────────────────────────────
# Output helpers (ANSI colors fall back to plain text in non-TTY)
# ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
    BLUE=$'\033[34m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

step()   { printf "\n${CYAN}${BOLD}==>${RESET}${BOLD} %s${RESET}\n" "$*"; }
ok()     { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()   { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
fail()   { printf "  ${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
info()   { printf "    %s\n" "$*"; }

banner() {
    cat <<EOF
${BLUE}${BOLD}
   ╔═══════════════════════════════════════════════════════╗
   ║                                                       ║
   ║   ⚡ NovaPanel Installer                               ║
   ║   The Modern Hosting Control Panel                    ║
   ║                                                       ║
   ╚═══════════════════════════════════════════════════════╝
${RESET}
EOF
}

# ─────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) PROVIDED_KEY="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
        --yes|--non-interactive) NON_INTERACTIVE=1; shift ;;
        --license-server) LICENSE_SERVER="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
NovaPanel installer

Usage: install.sh [options]

  --key KEY              Activate this Pro/Developer key instead of auto-issuing
                         a Community license
  --email EMAIL          Admin email (defaults to admin@<hostname>)
  --hostname HOST        Override autodetected hostname for SSL setup
  --yes                  Non-interactive (use defaults for everything)
  --license-server URL   Override license server (default: https://license.novapanel.dev)
  --help                 Show this message

Environment variables: LICENSE_SERVER, NOVA_USER, NOVA_DIR, ADMIN_EMAIL, HOSTNAME_OVERRIDE
EOF
            exit 0 ;;
        *) warn "Unknown argument: $1"; shift ;;
    esac
done

# ─────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────
banner

step "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    fail "This installer must run as root. Try: sudo bash install.sh"
fi

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot detect OS — /etc/os-release missing"
fi
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    fail "Only Ubuntu is supported (found: $ID). Debian + RHEL support coming later."
fi
MAJOR_VER=$(echo "$VERSION_ID" | cut -d. -f1)
if [[ "$MAJOR_VER" -lt 24 ]]; then
    fail "Ubuntu 24.04+ required (found: $VERSION_ID)"
fi
ok "Ubuntu $VERSION_ID detected"

# Disk space — need ~3 GB for everything
AVAIL_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
if [[ "$AVAIL_GB" -lt 3 ]]; then
    fail "Need at least 3 GB free in /opt (have ${AVAIL_GB} GB)"
fi
ok "Disk space OK (${AVAIL_GB} GB free)"

# Network — license server must be reachable
if ! curl -sfI --max-time 5 "$LICENSE_SERVER/healthz" >/dev/null 2>&1; then
    fail "Cannot reach license server at $LICENSE_SERVER"
fi
ok "License server reachable"

# Ports 80/443 must be free (Caddy will bind these)
for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":$port "; then
        warn "Port $port is in use — installer may conflict with existing services"
    fi
done

# Hostname for SSL
if [[ -z "$HOSTNAME_OVERRIDE" ]]; then
    HOSTNAME_OVERRIDE=$(hostname --fqdn 2>/dev/null || hostname)
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
    ADMIN_EMAIL="admin@$HOSTNAME_OVERRIDE"
fi
ok "Hostname: $HOSTNAME_OVERRIDE"
ok "Admin email: $ADMIN_EMAIL"

# Confirm install if interactive
if [[ "$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
    echo
    read -rp "${BOLD}Proceed with NovaPanel installation? (y/N): ${RESET}" yn
    if [[ ! "$yn" =~ ^[Yy] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ─────────────────────────────────────────────────────────
# System update + base deps
# ─────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

step "Updating apt + installing base dependencies"
apt-get update -qq
apt-get install -y -qq \
    curl wget gnupg ca-certificates lsb-release apt-transport-https \
    debian-keyring debian-archive-keyring \
    sudo cron jq openssl ufw fail2ban \
    >/dev/null
ok "Base packages installed"

# ─────────────────────────────────────────────────────────
# PostgreSQL 16 (panel's own database)
# ─────────────────────────────────────────────────────────
step "Installing PostgreSQL 16"
if ! command -v psql >/dev/null 2>&1; then
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null
    systemctl enable postgresql >/dev/null
    systemctl start postgresql
    ok "PostgreSQL installed"
else
    ok "PostgreSQL already installed"
fi

# Create panel database + user
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=')
sudo -u postgres psql >/dev/null 2>&1 <<EOF || true
CREATE USER novapanel WITH PASSWORD '$DB_PASS';
CREATE DATABASE novapanel OWNER novapanel;
GRANT ALL PRIVILEGES ON DATABASE novapanel TO novapanel;
EOF
ok "Database 'novapanel' ready"

# ─────────────────────────────────────────────────────────
# Redis
# ─────────────────────────────────────────────────────────
step "Installing Redis"
if ! command -v redis-cli >/dev/null 2>&1; then
    apt-get install -y -qq redis-server >/dev/null
    systemctl enable redis-server >/dev/null
    systemctl start redis-server
    ok "Redis installed"
else
    ok "Redis already installed"
fi

# ─────────────────────────────────────────────────────────
# Caddy (TLS + reverse proxy)
# ─────────────────────────────────────────────────────────
step "Installing Caddy"
if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
    ok "Caddy installed"
else
    ok "Caddy already installed"
fi

# ─────────────────────────────────────────────────────────
# MariaDB (customer databases)
# ─────────────────────────────────────────────────────────
step "Installing MariaDB"
if ! command -v mysql >/dev/null 2>&1; then
    apt-get install -y -qq mariadb-server mariadb-client >/dev/null
    systemctl daemon-reload
    systemctl enable mariadb >/dev/null
    # Race-tolerant start: systemd may report 'activating' briefly
    for i in 1 2 3 4 5; do
        systemctl start mariadb 2>/dev/null
        sleep 2
        systemctl is-active --quiet mariadb && break
    done
    if ! systemctl is-active --quiet mariadb; then
        fail "MariaDB failed to start. Check: systemctl status mariadb"
    fi
    ok "MariaDB installed"
else
    ok "MariaDB already installed"
fi

# ─────────────────────────────────────────────────────────
# PHP 8.3 + FPM
# ─────────────────────────────────────────────────────────
step "Installing PHP 8.3"
if ! command -v php8.3 >/dev/null 2>&1; then
    apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
    apt-get update -qq
    apt-get install -y -qq \
        php8.3 php8.3-fpm php8.3-cli \
        php8.3-mysql php8.3-pgsql php8.3-mbstring php8.3-xml \
        php8.3-curl php8.3-zip php8.3-gd php8.3-intl php8.3-bcmath \
        composer \
        >/dev/null
    systemctl enable php8.3-fpm >/dev/null
    systemctl start php8.3-fpm
    ok "PHP 8.3 installed"
else
    ok "PHP 8.3 already installed"
fi

# ─────────────────────────────────────────────────────────
# Panel user + filesystem
# ─────────────────────────────────────────────────────────
step "Setting up panel user and directories"
if ! id "$NOVA_USER" >/dev/null 2>&1; then
    useradd -r -m -s /bin/bash -d "/home/$NOVA_USER" "$NOVA_USER"
    ok "Created user $NOVA_USER"
else
    ok "User $NOVA_USER already exists"
fi

mkdir -p "$NOVA_DIR/bin" "$NOVA_DIR/config"
mkdir -p "$NOVA_DATA"/{sites,backups,tmp}
mkdir -p "$NOVA_LOG"
mkdir -p "$NOVA_LICENSE_DIR"
mkdir -p /srv/sites /etc/caddy/sites /var/log/caddy
chown "$NOVA_USER:$NOVA_USER" "$NOVA_DIR" "$NOVA_DATA" "$NOVA_LOG" "$NOVA_LICENSE_DIR"
chmod 750 "$NOVA_LICENSE_DIR"
ok "Directories created"

# ─────────────────────────────────────────────────────────
# Get the license — Community auto-issuance OR provided Pro key
# ─────────────────────────────────────────────────────────
step "Provisioning license"

# Stable machine fingerprint — must match what the panel computes at runtime.
# Hash: machine-id + primary MAC + hostname.
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)
PRIMARY_MAC=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo$|^docker|^br-|^veth|^virbr|^tun|^tap/ && $3 ~ /MULTICAST/ {print $2; exit}' | xargs -I{} cat /sys/class/net/{}/address 2>/dev/null | head -1)
[[ -z "$PRIMARY_MAC" ]] && PRIMARY_MAC=$(ip -o link show 2>/dev/null | awk '$2 !~ /lo:/ {gsub(":", "", $2); print $17; exit}')
HOSTNAME_FOR_FP=$(hostname)
FINGERPRINT=$(printf 'novapanel:v1\nmachine-id:%s\nmac:%s\nhost:%s\n' "$MACHINE_ID" "$PRIMARY_MAC" "$HOSTNAME_FOR_FP" | sha256sum | awk '{print $1}')
info "Fingerprint: ${FINGERPRINT:0:16}…"

# Detect public IPs (best-effort, sent to the license server for the dashboard)
PUBLIC_IPV4=$(curl -s -4 --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
PUBLIC_IPV6=$(curl -s -6 --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")

if [[ -n "$PROVIDED_KEY" ]]; then
    info "Activating provided license key"
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/activate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg lk "$PROVIDED_KEY" \
            --arg fp "$FINGERPRINT" \
            --arg hn "$HOSTNAME_OVERRIDE" \
            --arg pv "installer" \
            --arg v4 "$PUBLIC_IPV4" \
            --arg v6 "$PUBLIC_IPV6" \
            '{license_key:$lk, fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')") \
        || fail "License activation failed (key invalid or server error)"
    LICENSE_KEY="$PROVIDED_KEY"
else
    info "Requesting Community license"
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/community-license" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg fp "$FINGERPRINT" \
            --arg hn "$HOSTNAME_OVERRIDE" \
            --arg pv "installer" \
            --arg v4 "$PUBLIC_IPV4" \
            --arg v6 "$PUBLIC_IPV6" \
            '{fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')") \
        || fail "Community license issuance failed"
    LICENSE_KEY=$(echo "$LIC_RESP" | jq -r .license_key)
fi

LICENSE_TOKEN=$(echo "$LIC_RESP" | jq -r .token)
LICENSE_TIER=$(echo "$LIC_RESP" | jq -r .tier)
LICENSE_EXPIRES=$(echo "$LIC_RESP" | jq -r .expires_at)

# Write license file in the format the panel's license.Manager expects
cat > "$NOVA_LICENSE_DIR/license.json" <<EOF
{
  "license_key": "$LICENSE_KEY",
  "token": "$LICENSE_TOKEN",
  "fingerprint": "$FINGERPRINT",
  "tier": "$LICENSE_TIER",
  "issued_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "expires_at": "$LICENSE_EXPIRES"
}
EOF
chown "$NOVA_USER:$NOVA_USER" "$NOVA_LICENSE_DIR/license.json"
chmod 640 "$NOVA_LICENSE_DIR/license.json"
ok "$LICENSE_TIER license activated ($LICENSE_KEY)"

# ─────────────────────────────────────────────────────────
# Download the binary from the license-gated CDN
# ─────────────────────────────────────────────────────────
step "Downloading NovaPanel binary"

# Get version manifest first (for the SHA-256 to verify against)
MANIFEST=$(curl -sf "$LICENSE_SERVER/api/v1/version/latest") \
    || fail "Couldn't fetch version manifest"
EXPECTED_SHA=$(echo "$MANIFEST" | jq -r .sha256)
LATEST_VERSION=$(echo "$MANIFEST" | jq -r .version)
EXPECTED_SIZE=$(echo "$MANIFEST" | jq -r .size_bytes)
info "Latest version: $LATEST_VERSION (sha256: ${EXPECTED_SHA:0:12}…)"

# Download with the license JWT
curl -fL -H "Authorization: Bearer $LICENSE_TOKEN" \
    "$LICENSE_SERVER/api/v1/download/latest" \
    -o "$NOVA_DIR/bin/novapanel.new" \
    || fail "Binary download failed (license server denied or network error)"

# Verify size
ACTUAL_SIZE=$(stat -c%s "$NOVA_DIR/bin/novapanel.new")
if [[ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]]; then
    fail "Binary size mismatch (got $ACTUAL_SIZE, expected $EXPECTED_SIZE)"
fi

# Verify SHA-256
ACTUAL_SHA=$(sha256sum "$NOVA_DIR/bin/novapanel.new" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    rm -f "$NOVA_DIR/bin/novapanel.new"
    fail "Binary SHA-256 mismatch — refusing to install (got $ACTUAL_SHA, expected $EXPECTED_SHA)"
fi
ok "Downloaded + verified ($ACTUAL_SIZE bytes)"

mv "$NOVA_DIR/bin/novapanel.new" "$NOVA_DIR/bin/novapanel"
chmod +x "$NOVA_DIR/bin/novapanel"
chown "$NOVA_USER:$NOVA_USER" "$NOVA_DIR/bin/novapanel"

# ─────────────────────────────────────────────────────────
# .env file
# ─────────────────────────────────────────────────────────
step "Writing panel configuration"
JWT_SECRET=$(openssl rand -hex 32)
cat > "$NOVA_DIR/config/.env" <<EOF
NOVA_ENV=production
NOVA_DB_HOST=127.0.0.1
NOVA_DB_PORT=5432
NOVA_DB_NAME=novapanel
NOVA_DB_USER=novapanel
NOVA_DB_PASS=$DB_PASS
NOVA_REDIS_URL=redis://localhost:6379/0
NOVA_JWT_SECRET=$JWT_SECRET
NOVA_ADMIN_PORT=2087
NOVA_CUSTOMER_PORT=2083
NOVA_CADDY_API=http://localhost:2019
NOVA_LICENSE_SERVER=$LICENSE_SERVER
NOVA_ACME_EMAIL=$ADMIN_EMAIL
EOF
chown root:"$NOVA_USER" "$NOVA_DIR/config/.env"
chmod 640 "$NOVA_DIR/config/.env"
ok "Configuration written"

# ─────────────────────────────────────────────────────────
# systemd unit
# ─────────────────────────────────────────────────────────
step "Installing systemd unit"
cat > /etc/systemd/system/novapanel.service <<EOF
[Unit]
Description=NovaPanel Hosting Control Panel
Documentation=https://novapanel.dev
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=$NOVA_USER
Group=$NOVA_USER
WorkingDirectory=$NOVA_DIR
EnvironmentFile=$NOVA_DIR/config/.env
ExecStart=$NOVA_DIR/bin/novapanel
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$NOVA_DATA $NOVA_LOG $NOVA_LICENSE_DIR /srv/sites /etc/caddy/sites /var/log/caddy
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# sudoers entry so the panel can run systemd-run for self-updates
cat > /etc/sudoers.d/novapanel <<EOF
$NOVA_USER ALL=(root) NOPASSWD: /usr/bin/systemd-run, /usr/bin/systemctl restart novapanel, /usr/bin/systemctl restart caddy
EOF
chmod 440 /etc/sudoers.d/novapanel

systemctl daemon-reload
systemctl enable novapanel >/dev/null
ok "systemd unit installed"

# ─────────────────────────────────────────────────────────
# Firewall
# ─────────────────────────────────────────────────────────
step "Configuring firewall"
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow 2083/tcp >/dev/null 2>&1   # customer panel
ufw allow 2087/tcp >/dev/null 2>&1   # admin panel
ufw --force enable >/dev/null 2>&1 || true
ok "Firewall configured (22, 80, 443, 2083, 2087)"

# ─────────────────────────────────────────────────────────
# Start the panel
# ─────────────────────────────────────────────────────────
step "Starting NovaPanel"
systemctl start novapanel
sleep 3

if systemctl is-active --quiet novapanel; then
    ok "NovaPanel is running"
else
    warn "Service did not start cleanly. Check: journalctl -u novapanel -n 50"
fi

# ─────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────
PUBLIC_IP="${PUBLIC_IPV4:-${PUBLIC_IPV6:-$HOSTNAME_OVERRIDE}}"
cat <<EOF

${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
${GREEN}${BOLD}  ✓ NovaPanel installation complete${RESET}
${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}

  ${BOLD}Admin panel:${RESET}    https://${PUBLIC_IP}:2087
  ${BOLD}Customer panel:${RESET} https://${PUBLIC_IP}:2083

  ${BOLD}License tier:${RESET}   $LICENSE_TIER
  ${BOLD}License key:${RESET}    $LICENSE_KEY
  ${BOLD}Fingerprint:${RESET}    ${FINGERPRINT:0:16}…

  ${YELLOW}Next steps:${RESET}
    1. Open the admin panel in your browser
    2. Log in (initial admin credentials are printed in the panel logs:
       journalctl -u novapanel | grep "initial admin")
    3. Set up your domain in admin -> Server -> Hostname for proper SSL
    4. To upgrade to Pro, paste your key in admin -> Config -> License

  ${BOLD}Support:${RESET}        https://novapanel.dev/support
  ${BOLD}Documentation:${RESET}  https://novapanel.dev/docs

EOF
