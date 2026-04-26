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
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-}"
INSTALL_LOG="/tmp/novapanel-install.log"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
# Make every apt call wait up to 5 min for the dpkg lock instead of
# bailing immediately — defends against unattended-upgrades / cloud-init
# still running on a fresh boot.
APT_WAIT="-o DPkg::Lock::Timeout=300"

# ─────────────────────────────────────────────────────────
# Output helpers
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
fail()   { printf "  ${RED}✗${RESET} %s\n" "$*" >&2; printf "\n${RED}Install log: $INSTALL_LOG${RESET}\n" >&2; exit 1; }
info()   { printf "    %s\n" "$*"; }

# Run a command, log all output, fail loudly with context if it errors.
# Replaces the dangerous `cmd >/dev/null 2>&1 || true` pattern.
run() {
    local label="$1"; shift
    if "$@" >>"$INSTALL_LOG" 2>&1; then
        return 0
    else
        local rc=$?
        printf "  ${RED}✗${RESET} %s (exit %d)\n" "$label" $rc >&2
        printf "    Last 10 lines from $INSTALL_LOG:\n" >&2
        tail -10 "$INSTALL_LOG" | sed 's/^/    /' >&2
        exit 1
    fi
}

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

# Wait for any background apt/dpkg process to release its locks.
# Cloud-init + unattended-upgrades commonly hold these on first boot.
wait_for_dpkg() {
    local waited=0
    local max=300
    local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
    while true; do
        local held=0
        for lock in "${locks[@]}"; do
            if fuser "$lock" >/dev/null 2>&1; then
                held=1
                break
            fi
        done
        [[ $held -eq 0 ]] && return 0
        if [[ $waited -eq 0 ]]; then
            info "Waiting for cloud-init / unattended-upgrades to release apt lock..."
        fi
        sleep 2
        waited=$((waited+2))
        if [[ $waited -ge $max ]]; then
            fail "apt lock still held after ${max}s — check 'ps aux | grep apt'"
        fi
    done
}

# ─────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) PROVIDED_KEY="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --username) ADMIN_USERNAME="$2"; shift 2 ;;
        --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
        --yes|--non-interactive) NON_INTERACTIVE=1; shift ;;
        --license-server) LICENSE_SERVER="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
NovaPanel installer

Usage: install.sh [options]

  --key KEY              Activate this Pro/Developer key instead of auto-issuing
                         a Community license
  --email EMAIL          Admin email
  --username USER        Admin username (default: admin)
  --hostname HOST        Hostname for SSL setup
  --yes                  Non-interactive (use defaults for everything)
  --license-server URL   Override license server (default: https://license.novapanel.dev)
  --help                 Show this message

Environment variables: LICENSE_SERVER, NOVA_USER, NOVA_DIR, ADMIN_EMAIL, HOSTNAME_OVERRIDE
EOF
            exit 0 ;;
        *) warn "Unknown argument: $1"; shift ;;
    esac
done

# Reset install log
: > "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"

banner

# ─────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────
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

AVAIL_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
if [[ "$AVAIL_GB" -lt 3 ]]; then
    fail "Need at least 3 GB free in /opt (have ${AVAIL_GB} GB)"
fi
ok "Disk space OK (${AVAIL_GB} GB free)"

if ! curl -sfI --max-time 5 "$LICENSE_SERVER/healthz" >/dev/null 2>&1; then
    fail "Cannot reach license server at $LICENSE_SERVER"
fi
ok "License server reachable"

for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":$port "; then
        warn "Port $port already in use"
    fi
done

# ─────────────────────────────────────────────────────────
# Interactive setup (skipped with --yes)
# ─────────────────────────────────────────────────────────
DEFAULT_HOST=$(hostname --fqdn 2>/dev/null || hostname)
[[ -z "$HOSTNAME_OVERRIDE" ]] && HOSTNAME_OVERRIDE="$DEFAULT_HOST"
[[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${HOSTNAME_OVERRIDE#*.}"

# When run as `curl ... | sudo bash`, stdin is the script body so prompts
# can't read from the user. Reattach to the controlling tty when one is
# available so the prompts work even via the one-liner pipe.
if [[ "$NON_INTERACTIVE" -eq 0 ]] && [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi

if [[ "$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
    step "Configuration"

    read -rp "  ${BOLD}📧 Admin email${RESET} [$ADMIN_EMAIL]: " v
    [[ -n "$v" ]] && ADMIN_EMAIL="$v"

    read -rp "  ${BOLD}👤 Admin username${RESET} [$ADMIN_USERNAME]: " v
    [[ -n "$v" ]] && ADMIN_USERNAME="$v"

    read -rp "  ${BOLD}🌐 Server hostname${RESET} [$HOSTNAME_OVERRIDE]: " v
    [[ -n "$v" ]] && HOSTNAME_OVERRIDE="$v"

    while true; do
        read -rsp "  ${BOLD}🔑 Admin password${RESET} (min 8 chars, leave blank to auto-generate): " ADMIN_PASSWORD
        echo
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)
            info "Auto-generated password: ${BOLD}${ADMIN_PASSWORD}${RESET}"
            info "(printed again at end of install — save it somewhere safe)"
            break
        fi
        if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
            warn "Password must be at least 8 characters"
            continue
        fi
        read -rsp "  ${BOLD}🔑 Confirm password${RESET}: " ADMIN_PASSWORD_CONFIRM
        echo
        if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
            break
        fi
        warn "Passwords don't match. Try again."
    done

    cat <<EOF

  ${BOLD}Review:${RESET}
    Admin email:   $ADMIN_EMAIL
    Admin user:    $ADMIN_USERNAME
    Hostname:      $HOSTNAME_OVERRIDE
    License:       $([ -n "$PROVIDED_KEY" ] && echo "Pro key provided" || echo "Auto-issue Community")

EOF
    read -rp "  ${BOLD}Proceed with installation? (Y/n): ${RESET}" yn
    if [[ "$yn" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
else
    # Non-interactive: auto-generate a password
    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)
fi

# ─────────────────────────────────────────────────────────
# Wait for boot-time apt processes
# ─────────────────────────────────────────────────────────
step "Waiting for system to settle"
wait_for_dpkg
ok "apt locks free"

# ─────────────────────────────────────────────────────────
# System update + base deps
# ─────────────────────────────────────────────────────────
step "Installing base dependencies"
run "apt-get update" apt-get $APT_WAIT update -qq
run "apt-get install base packages" apt-get $APT_WAIT install -y -qq \
    curl wget gnupg ca-certificates lsb-release apt-transport-https \
    debian-keyring debian-archive-keyring software-properties-common \
    sudo cron jq openssl ufw fail2ban
ok "Base packages installed"

# ─────────────────────────────────────────────────────────
# PostgreSQL 16
# ─────────────────────────────────────────────────────────
step "Installing PostgreSQL 16"
if ! command -v psql >/dev/null 2>&1; then
    run "install postgresql" apt-get $APT_WAIT install -y -qq postgresql postgresql-contrib
fi
systemctl daemon-reload
run "enable postgresql" systemctl enable postgresql
run "start postgresql" systemctl start postgresql
ok "PostgreSQL installed + running"

# Create panel database + user
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=')
sudo -u postgres psql >>"$INSTALL_LOG" 2>&1 <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'novapanel') THEN
        CREATE USER novapanel WITH PASSWORD '$DB_PASS';
    ELSE
        ALTER USER novapanel WITH PASSWORD '$DB_PASS';
    END IF;
END
\$\$;
EOF
sudo -u postgres psql >>"$INSTALL_LOG" 2>&1 -tc "SELECT 1 FROM pg_database WHERE datname = 'novapanel'" | grep -q 1 \
    || sudo -u postgres createdb -O novapanel novapanel >>"$INSTALL_LOG" 2>&1
sudo -u postgres psql >>"$INSTALL_LOG" 2>&1 -c "GRANT ALL PRIVILEGES ON DATABASE novapanel TO novapanel;"
ok "Database 'novapanel' ready"

# ─────────────────────────────────────────────────────────
# Redis
# ─────────────────────────────────────────────────────────
step "Installing Redis"
if ! command -v redis-cli >/dev/null 2>&1; then
    run "install redis" apt-get $APT_WAIT install -y -qq redis-server
fi
systemctl daemon-reload
run "enable redis-server" systemctl enable redis-server
run "start redis-server" systemctl start redis-server
ok "Redis installed + running"

# ─────────────────────────────────────────────────────────
# Caddy
# ─────────────────────────────────────────────────────────
step "Installing Caddy"
if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    run "apt-get update (caddy)" apt-get $APT_WAIT update -qq
    run "install caddy" apt-get $APT_WAIT install -y -qq caddy
fi
ok "Caddy installed"

# ─────────────────────────────────────────────────────────
# MariaDB
# ─────────────────────────────────────────────────────────
step "Installing MariaDB"
if ! command -v mysql >/dev/null 2>&1; then
    run "install mariadb" apt-get $APT_WAIT install -y -qq mariadb-server mariadb-client
fi
systemctl daemon-reload
run "enable mariadb" systemctl enable mariadb
# Race-tolerant start: systemd may report 'activating' briefly
for i in 1 2 3 4 5; do
    systemctl start mariadb >>"$INSTALL_LOG" 2>&1 || true
    sleep 2
    systemctl is-active --quiet mariadb && break
done
if ! systemctl is-active --quiet mariadb; then
    fail "MariaDB failed to start. Check: systemctl status mariadb"
fi
ok "MariaDB installed + running"

# ─────────────────────────────────────────────────────────
# PHP 8.3
# ─────────────────────────────────────────────────────────
step "Installing PHP 8.3"
if ! command -v php8.3 >/dev/null 2>&1; then
    add-apt-repository -y ppa:ondrej/php >>"$INSTALL_LOG" 2>&1 || true
    run "apt-get update (php)" apt-get $APT_WAIT update -qq
    run "install php8.3" apt-get $APT_WAIT install -y -qq \
        php8.3 php8.3-fpm php8.3-cli \
        php8.3-mysql php8.3-pgsql php8.3-mbstring php8.3-xml \
        php8.3-curl php8.3-zip php8.3-gd php8.3-intl php8.3-bcmath \
        composer
fi
systemctl daemon-reload
run "enable php8.3-fpm" systemctl enable php8.3-fpm
run "start php8.3-fpm" systemctl start php8.3-fpm
ok "PHP 8.3 installed + running"

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

MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)
PRIMARY_MAC=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo$|^docker|^br-|^veth|^virbr|^tun|^tap/ && $3 ~ /MULTICAST/ {print $2; exit}' | xargs -I{} cat /sys/class/net/{}/address 2>/dev/null | head -1)
[[ -z "$PRIMARY_MAC" ]] && PRIMARY_MAC=$(ip -o link show 2>/dev/null | awk '$2 !~ /lo:/ {gsub(":", "", $2); print $17; exit}')
HOSTNAME_FOR_FP=$(hostname)
FINGERPRINT=$(printf 'novapanel:v1\nmachine-id:%s\nmac:%s\nhost:%s\n' "$MACHINE_ID" "$PRIMARY_MAC" "$HOSTNAME_FOR_FP" | sha256sum | awk '{print $1}')
info "Fingerprint: ${FINGERPRINT:0:16}…"

PUBLIC_IPV4=$(curl -s -4 --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
PUBLIC_IPV6=$(curl -s -6 --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")

if [[ -n "$PROVIDED_KEY" ]]; then
    info "Activating provided license key"
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/activate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg lk "$PROVIDED_KEY" --arg fp "$FINGERPRINT" \
            --arg hn "$HOSTNAME_OVERRIDE" --arg pv "installer" \
            --arg v4 "$PUBLIC_IPV4" --arg v6 "$PUBLIC_IPV6" \
            '{license_key:$lk, fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')") \
        || fail "License activation failed (key invalid or server error)"
    LICENSE_KEY="$PROVIDED_KEY"
else
    info "Requesting Community license"
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/community-license" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg fp "$FINGERPRINT" --arg hn "$HOSTNAME_OVERRIDE" \
            --arg pv "installer" \
            --arg v4 "$PUBLIC_IPV4" --arg v6 "$PUBLIC_IPV6" \
            '{fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')") \
        || fail "Community license issuance failed"
    LICENSE_KEY=$(echo "$LIC_RESP" | jq -r .license_key)
fi

LICENSE_TOKEN=$(echo "$LIC_RESP" | jq -r .token)
LICENSE_TIER=$(echo "$LIC_RESP" | jq -r .tier)
LICENSE_EXPIRES=$(echo "$LIC_RESP" | jq -r .expires_at)

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

MANIFEST=$(curl -sf "$LICENSE_SERVER/api/v1/version/latest") \
    || fail "Couldn't fetch version manifest"
EXPECTED_SHA=$(echo "$MANIFEST" | jq -r .sha256)
LATEST_VERSION=$(echo "$MANIFEST" | jq -r .version)
EXPECTED_SIZE=$(echo "$MANIFEST" | jq -r .size_bytes)
info "Latest version: $LATEST_VERSION"

curl -fL -H "Authorization: Bearer $LICENSE_TOKEN" \
    "$LICENSE_SERVER/api/v1/download/latest" \
    -o "$NOVA_DIR/bin/novapanel.new" \
    || fail "Binary download failed"

ACTUAL_SIZE=$(stat -c%s "$NOVA_DIR/bin/novapanel.new")
[[ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]] && fail "Binary size mismatch (got $ACTUAL_SIZE, expected $EXPECTED_SIZE)"

ACTUAL_SHA=$(sha256sum "$NOVA_DIR/bin/novapanel.new" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    rm -f "$NOVA_DIR/bin/novapanel.new"
    fail "Binary SHA-256 mismatch — refusing to install"
fi
ok "Downloaded + verified ($ACTUAL_SIZE bytes)"

mv "$NOVA_DIR/bin/novapanel.new" "$NOVA_DIR/bin/novapanel"
chmod +x "$NOVA_DIR/bin/novapanel"
chown "$NOVA_USER:$NOVA_USER" "$NOVA_DIR/bin/novapanel"

# ─────────────────────────────────────────────────────────
# .env
# ─────────────────────────────────────────────────────────
step "Writing panel configuration"
JWT_SECRET=$(openssl rand -hex 32)
cat > "$NOVA_DIR/config/.env" <<EOF
NOVA_ENV=production
NOVA_LOG_LEVEL=info
NOVA_DB_HOST=127.0.0.1
NOVA_DB_PORT=5432
NOVA_DB_NAME=novapanel
NOVA_DB_USER=novapanel
NOVA_DB_PASSWORD=$DB_PASS
NOVA_DB_SSLMODE=disable
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
# Pre-create initial admin user in DB
# ─────────────────────────────────────────────────────────
step "Preparing admin credentials"
ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASSWORD', PASSWORD_BCRYPT, ['cost' => 12]);")
ok "Password hashed"

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

cat > /etc/sudoers.d/novapanel <<EOF
$NOVA_USER ALL=(root) NOPASSWD: /usr/bin/systemd-run, /usr/bin/systemctl restart novapanel, /usr/bin/systemctl restart caddy
EOF
chmod 440 /etc/sudoers.d/novapanel

systemctl daemon-reload
run "enable novapanel" systemctl enable novapanel
ok "systemd unit installed"

# ─────────────────────────────────────────────────────────
# Firewall
# ─────────────────────────────────────────────────────────
step "Configuring firewall"
ufw default deny incoming >>"$INSTALL_LOG" 2>&1
ufw default allow outgoing >>"$INSTALL_LOG" 2>&1
ufw allow 22/tcp >>"$INSTALL_LOG" 2>&1
ufw allow 80/tcp >>"$INSTALL_LOG" 2>&1
ufw allow 443/tcp >>"$INSTALL_LOG" 2>&1
ufw allow 2083/tcp >>"$INSTALL_LOG" 2>&1
ufw allow 2087/tcp >>"$INSTALL_LOG" 2>&1
ufw --force enable >>"$INSTALL_LOG" 2>&1
ok "Firewall configured (22, 80, 443, 2083, 2087)"

# ─────────────────────────────────────────────────────────
# Caddy reverse proxy with auto Let's Encrypt for the chosen hostname.
# If DNS isn't pointed yet the cert won't issue immediately — Caddy
# will keep retrying. The :80 listener still serves so the operator
# can hit the panel via http://IP for the initial setup.
# ─────────────────────────────────────────────────────────
step "Configuring Caddy reverse proxy"
cat > /etc/caddy/Caddyfile <<EOF
{
    email $ADMIN_EMAIL
}

# Admin panel — auto-TLS for the chosen hostname
$HOSTNAME_OVERRIDE:2087 {
    reverse_proxy 127.0.0.1:2087
}

# Customer panel — auto-TLS for the chosen hostname
$HOSTNAME_OVERRIDE:2083 {
    reverse_proxy 127.0.0.1:2083
}

# Plain-HTTP fallback so http://IP works during initial DNS propagation
:80 {
    reverse_proxy 127.0.0.1:2087
}
EOF
systemctl reload caddy >>"$INSTALL_LOG" 2>&1 || systemctl restart caddy >>"$INSTALL_LOG" 2>&1
ok "Caddy configured (HTTPS on $HOSTNAME_OVERRIDE, HTTP fallback on IP)"

# ─────────────────────────────────────────────────────────
# Start the panel
# ─────────────────────────────────────────────────────────
step "Starting NovaPanel"
systemctl start novapanel
sleep 3

if systemctl is-active --quiet novapanel; then
    ok "NovaPanel is running"
else
    warn "Service did not start. Last log lines:"
    journalctl -u novapanel -n 20 --no-pager | sed 's/^/    /'
    fail "Panel failed to start"
fi

# ─────────────────────────────────────────────────────────
# Apply admin credentials (after migrations have run + seeded
# the default admin@novapanel.local user with the canonical
# password hash). Wait until the users table exists so we don't
# race the migration runner.
# ─────────────────────────────────────────────────────────
step "Setting admin credentials"
APPLIED=0
for i in $(seq 1 30); do
    EXISTS=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U novapanel -d novapanel -tAc \
        "SELECT to_regclass('public.users')" 2>/dev/null || true)
    if [[ "$EXISTS" == "users" ]]; then
        # Replace the seeded admin row with the operator's chosen email +
        # username + password. Updates the canonical seed row identified
        # by username 'admin' (the row migration 001 inserts).
        PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U novapanel -d novapanel >>"$INSTALL_LOG" 2>&1 <<EOF
UPDATE users
   SET email = '$ADMIN_EMAIL',
       username = '$ADMIN_USERNAME',
       password_hash = '$ADMIN_HASH',
       is_active = true,
       updated_at = now()
 WHERE username IN ('admin', '$ADMIN_USERNAME')
    OR email = 'admin@novapanel.local'
 RETURNING id;
EOF
        if [[ $? -eq 0 ]]; then
            APPLIED=1
            break
        fi
    fi
    sleep 1
done
if [[ $APPLIED -eq 1 ]]; then
    ok "Admin credentials applied"
else
    warn "Couldn't apply admin credentials — falling back to default seed"
    warn "Login with: admin@novapanel.local / NovaPanel@2024 — change immediately"
    ADMIN_EMAIL="admin@novapanel.local"
    ADMIN_USERNAME="admin"
    ADMIN_PASSWORD="NovaPanel@2024"
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

  ${BOLD}Admin login:${RESET}
    Email:    $ADMIN_EMAIL
    Username: $ADMIN_USERNAME
    Password: ${BOLD}$ADMIN_PASSWORD${RESET}

  ${YELLOW}SAVE THE PASSWORD ABOVE — it's not stored anywhere recoverable.${RESET}

  ${BOLD}License tier:${RESET}   $LICENSE_TIER
  ${BOLD}License key:${RESET}    $LICENSE_KEY

  ${BOLD}Next steps:${RESET}
    1. Open the admin panel in your browser
    2. Log in with the credentials above
    3. To upgrade to Pro, paste your key in admin → Config → License

  ${BOLD}Install log:${RESET}    $INSTALL_LOG
  ${BOLD}Service logs:${RESET}   journalctl -u novapanel -f

EOF
