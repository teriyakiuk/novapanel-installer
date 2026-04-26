#!/usr/bin/env bash
set -uo pipefail
# Note: not using 'set -e' because many apt/service commands return non-zero
# on idempotent operations (already installed, already running, etc.)

# Curl-pipe-bash trick. When invoked as `curl ... | sudo bash`, stdin is
# the script bytes themselves — bash reads us from the pipe AND the
# script's interactive `read` prompts have nowhere real to read from.
# Naively doing `exec </dev/tty` would also break bash's own reading of
# the rest of the script (would try to read more lines from the now-
# disconnected pipe and hang).
#
# Bulletproof fix: detect "stdin isn't a tty AND a real tty is reachable
# AND we have curl", re-download the script to disk, then re-exec from
# the disk copy with /dev/tty wired up as stdin. After re-exec, bash
# reads the script from a regular file and `read` prompts work normally.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]] && command -v curl >/dev/null; then
    TMPSELF=$(mktemp /tmp/novapanel-install-XXXXXX.sh)
    if curl -fsSL "${LICENSE_SERVER_BOOTSTRAP:-https://license.novapanel.dev}/install.sh" -o "$TMPSELF" 2>/dev/null \
        && [[ -s "$TMPSELF" ]]; then
        chmod +x "$TMPSELF"
        # Drain whatever's left of the original curl pipe in the
        # background so curl doesn't end with 'curl: (23) Failure
        # writing output to destination' after the install is done.
        # The drain process is inherited by the exec'd bash and runs
        # silently to completion (curl finishes writing, drain exits).
        cat >/dev/null </dev/stdin &
        # We're already running as root via the outer 'sudo bash' (or
        # the user ran us as root directly). Don't sudo again — it can
        # hang on password prompts or tty re-allocation. Plain `exec
        # bash` from disk with /dev/tty wired up is enough.
        exec bash "$TMPSELF" "$@" </dev/tty
    fi
    rm -f "$TMPSELF"
    # Fall through to non-interactive mode if the re-download failed —
    # better degraded than completely stuck.
fi

# ─────────────────────────────────────────────────────────
# NovaPanel Installer (CDN edition)
# The Modern Hosting Control Panel
# https://novapanel.dev
#
# Usage:
#   Interactive:    curl -fsSL https://novapanel.dev/install.sh | sudo bash
#   Quick:          curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- --quick
#   With Pro key:   curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- --key NOVA-xxxx-...
#
# Differences from scripts/bootstrap.sh (the source-tree dev installer):
#   - No Go toolchain install (binary is pre-built and downloaded)
#   - No git clone of NovaPanel (closed-source distribution)
#   - No SPA / migration / template copy (binary contains them via go:embed)
#   - Adds license fetch (community auto-issue or provided Pro key)
#     and license-gated CDN download of the binary
# Everything else (Postgres, Redis, Caddy + WAF, MariaDB, phpMyAdmin,
# Roundcube, PHP, Node, Python, Postfix+Dovecot, vsftpd, PowerDNS,
# ClamAV, SSL prompts, full Caddyfile with welcome page) is identical
# to bootstrap.sh.
# ─────────────────────────────────────────────────────────

LICENSE_SERVER="${LICENSE_SERVER:-https://license.novapanel.dev}"
NOVA_VERSION="dev"  # overwritten by the manifest fetched from the CDN
NOVA_USER="novapanel"
NOVA_DIR="/opt/novapanel"
NOVA_LOG="/var/log/novapanel"
NOVA_DATA="/var/lib/novapanel"
NOVA_LICENSE_DIR="/etc/novapanel"
PROVIDED_KEY=""
DB_NAME="novapanel"
DB_USER="novapanel"

# Secrets — preserved across re-runs. If the panel is already
# installed, the existing .env already contains DB_PASS, JWT_SECRET,
# PDNS_PASS, PDNS_API_KEY that real services (PostgreSQL, PowerDNS,
# the Go binary) are authenticating with. Regenerating them on every
# bootstrap run would lock the panel out of its own database. New
# values are only minted when no existing config is found.
EXISTING_ENV="${NOVA_DIR}/config/.env"
# Default to empty so the `-z` checks below don't hit `set -u` on a
# fresh VPS where the .env block doesn't exist yet.
DB_PASS=""
JWT_SECRET=""
PDNS_PASS=""
PDNS_API_KEY=""
if [ -f "$EXISTING_ENV" ]; then
    DB_PASS=$(grep -E '^DB_PASS=' "$EXISTING_ENV" | cut -d= -f2- | tr -d '"' || echo "")
    JWT_SECRET=$(grep -E '^JWT_SECRET=' "$EXISTING_ENV" | cut -d= -f2- | tr -d '"' || echo "")
    PDNS_PASS=$(grep -E '^PDNS_PASS=' "$EXISTING_ENV" | cut -d= -f2- | tr -d '"' || echo "")
    PDNS_API_KEY=$(grep -E '^PDNS_API_KEY=' "$EXISTING_ENV" | cut -d= -f2- | tr -d '"' || echo "")
fi
# Mint any secret that's still empty — first install, or a partial
# .env left behind by a previous failed run.
[ -z "$DB_PASS" ]      && DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
[ -z "$JWT_SECRET" ]   && JWT_SECRET=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 64)
[ -z "$PDNS_PASS" ]    && PDNS_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
[ -z "$PDNS_API_KEY" ] && PDNS_API_KEY=$(openssl rand -hex 24)

# Defaults
ADMIN_EMAIL="admin@novapanel.local"
ADMIN_USER="admin"
ADMIN_PASS=""
HOSTNAME_SET=""
INSTALL_PHP="yes"
INSTALL_NODEJS="yes"
INSTALL_PYTHON="yes"
INSTALL_DNS="yes"
INSTALL_MAIL="yes"
INSTALL_FTP="yes"
INSTALL_CLAMAV="yes"
SETUP_SSL="no"
SSL_DOMAIN=""
QUICK_MODE="no"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INSTALL_LOG="/tmp/novapanel-install.log"
> "$INSTALL_LOG"

log()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }
info() { echo -e "  ${DIM}$1${NC}"; }

# Silent step execution with spinner
SPIN_PID=""
start_spinner() {
    local msg="$1"
    (
        chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                printf "\r  ${CYAN}${chars:$i:1}${NC} ${msg}" >&2
                sleep 0.1
            done
        done
    ) &
    SPIN_PID=$!
}

stop_spinner() {
    local msg="$1"
    local status="${2:-ok}"
    if [[ -n "$SPIN_PID" ]]; then
        kill $SPIN_PID 2>/dev/null
        wait $SPIN_PID 2>/dev/null || true
        SPIN_PID=""
    fi
    if [[ "$status" == "ok" ]]; then
        printf "\r  ${GREEN}✓${NC} ${msg}%*s\n" $((60 - ${#msg})) ""
    else
        printf "\r  ${YELLOW}⚠${NC} ${msg}%*s\n" $((60 - ${#msg})) ""
    fi
}

# Run a command silently, log output to file
run() {
    echo "── $(date '+%H:%M:%S') ── $*" >> "$INSTALL_LOG"
    "$@" >> "$INSTALL_LOG" 2>&1
    return $?
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local bar_len=30
    local filled=$((pct * bar_len / 100))
    local empty=$((bar_len - filled))
    local bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')
    echo ""
    echo -e "  ${DIM}[${bar}] ${pct}%${NC}   ${BOLD}$1${NC}"
}

# ── Parse Arguments ─────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)       QUICK_MODE="yes"; shift ;;
        --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-user)  ADMIN_USER="$2"; shift 2 ;;
        --admin-pass)  ADMIN_PASS="$2"; shift 2 ;;
        --hostname)    HOSTNAME_SET="$2"; shift 2 ;;
        --ssl-domain)  SETUP_SSL="yes"; SSL_DOMAIN="$2"; shift 2 ;;
        --key)         PROVIDED_KEY="$2"; shift 2 ;;
        --license-server) LICENSE_SERVER="$2"; shift 2 ;;
        --no-php)      INSTALL_PHP="no"; shift ;;
        --no-nodejs)   INSTALL_NODEJS="no"; shift ;;
        --no-python)   INSTALL_PYTHON="no"; shift ;;
        --no-dns)      INSTALL_DNS="no"; shift ;;
        --no-mail)     INSTALL_MAIL="no"; shift ;;
        --no-ftp)      INSTALL_FTP="no"; shift ;;
        --no-clamav)   INSTALL_CLAMAV="no"; shift ;;
        --skip-waf)    SKIP_WAF="yes"; shift ;;
        --help|-h)
            echo "NovaPanel Installer v${NOVA_VERSION}"
            echo ""
            echo "Usage: bash bootstrap.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick               Non-interactive install with defaults"
            echo "  --admin-email EMAIL   Admin email address"
            echo "  --admin-user USER     Admin username"
            echo "  --admin-pass PASS     Admin password"
            echo "  --hostname HOST       Server hostname / FQDN"
            echo "  --ssl-domain DOMAIN   Enable Let's Encrypt SSL for domain"
            echo "  --no-php              Skip PHP 8.3 installation"
            echo "  --no-nodejs           Skip Node.js + pm2 installation"
            echo "  --no-python           Skip Python + Gunicorn installation"
            echo "  --no-dns              Skip PowerDNS installation"
            echo "  --no-mail             Skip Postfix + Dovecot installation"
            echo "  --no-ftp              Skip vsftpd installation"
            echo "  --no-clamav           Skip ClamAV installation"
            echo "  -h, --help            Show this help"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ── Pre-checks ──────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    err "This installer must be run as root (use sudo)"
fi

if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    err "Ubuntu 22.04/24.04 or Debian 11/12 required"
fi

# Check minimum resources
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_DISK=$(df -m / | awk 'NR==2{print $4}')
if [[ $TOTAL_MEM -lt 512 ]]; then
    warn "Low memory: ${TOTAL_MEM}MB detected (1GB+ recommended)"
fi
if [[ $TOTAL_DISK -lt 5000 ]]; then
    warn "Low disk space: $((TOTAL_DISK / 1024))GB free (10GB+ recommended)"
fi

# Detect IP
SERVER_IP=$(hostname -I | awk '{print $1}')

clear
echo ""
echo -e "${CYAN}    ╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}    ║${NC}                                                       ${CYAN}║${NC}"
echo -e "${CYAN}    ║${NC}   ${BOLD}⚡ NovaPanel${NC} v${NOVA_VERSION}                                  ${CYAN}║${NC}"
echo -e "${CYAN}    ║${NC}   ${DIM}The Modern Hosting Control Panel${NC}                    ${CYAN}║${NC}"
echo -e "${CYAN}    ║${NC}                                                       ${CYAN}║${NC}"
echo -e "${CYAN}    ╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}┌─────────────────────────────────────────────────┐${NC}"
echo -e "  ${DIM}│${NC}  OS:       $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo -e "  ${DIM}│${NC}  Server:   ${BOLD}${SERVER_IP}${NC}"
echo -e "  ${DIM}│${NC}  Memory:   $(free -h | awk '/^Mem:/{print $2}')  •  Disk: $(df -h / | awk 'NR==2{print $4}') free"
echo -e "  ${DIM}│${NC}  Kernel:   $(uname -r)"
echo -e "  ${DIM}└─────────────────────────────────────────────────┘${NC}"
echo ""

# ── Interactive Setup ───────────────────────────────

if [[ "$QUICK_MODE" != "yes" ]]; then
    echo -e "  ${BOLD}${BLUE}STEP 1 of 4${NC} ${BOLD}— Admin Account${NC}"
    echo -e "  ${DIM}Configure the administrator account for the panel${NC}"
    echo ""

    # Admin email
    read -p "  📧 Admin email [$ADMIN_EMAIL]: " input
    [[ -n "$input" ]] && ADMIN_EMAIL="$input"

    # Admin username
    read -p "  👤 Admin username [$ADMIN_USER]: " input
    [[ -n "$input" ]] && ADMIN_USER="$input"

    # Admin password
    if [[ -z "$ADMIN_PASS" ]]; then
        while true; do
            echo ""
            read -sp "  🔑 Admin password (min 8 chars): " ADMIN_PASS
            echo ""
            if [[ ${#ADMIN_PASS} -ge 8 ]]; then
                read -sp "  🔑 Confirm password: " ADMIN_PASS_CONFIRM
                echo ""
                if [[ "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]]; then
                    break
                else
                    warn "Passwords don't match, try again"
                fi
            else
                warn "Password must be at least 8 characters"
            fi
        done
    fi

    echo ""
    echo -e "  ${BOLD}${BLUE}STEP 2 of 4${NC} ${BOLD}— Server Settings${NC}"
    echo -e "  ${DIM}Configure your server hostname and SSL${NC}"
    echo ""

    # Hostname
    DEFAULT_HOST=$(hostname -f 2>/dev/null || hostname)
    read -p "  🌐 Server hostname [$DEFAULT_HOST]: " input
    HOSTNAME_SET="${input:-$DEFAULT_HOST}"

    # SSL
    echo ""
    echo -e "  ${DIM}SSL certificates secure your panel with HTTPS.${NC}"
    echo -e "  ${DIM}Requires a domain pointing to this server's IP (${SERVER_IP}).${NC}"
    read -p "  🔒 Setup Let's Encrypt SSL? (y/N): " input
    if [[ "${input,,}" == "y" ]]; then
        SETUP_SSL="yes"
        read -p "  🔒 Domain for SSL (e.g. panel.example.com): " SSL_DOMAIN
        if [[ -z "$SSL_DOMAIN" ]]; then
            SETUP_SSL="no"
            warn "No domain entered, skipping SSL"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}${BLUE}STEP 3 of 4${NC} ${BOLD}— Services${NC}"
    echo -e "  ${DIM}All services are installed by default. Press Enter to${NC}"
    echo -e "  ${DIM}accept all, or type ${BOLD}c${NC}${DIM} to customize.${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} PHP 8.3 + Composer       ${GREEN}✓${NC} Postfix + Dovecot (Email)"
    echo -e "  ${GREEN}✓${NC} Node.js 20 + pm2         ${GREEN}✓${NC} vsftpd (FTP Server)"
    echo -e "  ${GREEN}✓${NC} Python 3 + Gunicorn      ${GREEN}✓${NC} PowerDNS (DNS Server)"
    echo -e "  ${GREEN}✓${NC} ClamAV (Virus Scanner)"
    echo ""
    read -p "  Install all services? (Y/c to customize): " input
    if [[ "${input,,}" == "c" ]]; then
        echo ""
        echo -e "  ${DIM}Press Enter to keep, type 'n' to skip:${NC}"
        echo ""
        read -p "    PHP 8.3 + Composer           [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_PHP="no"
        read -p "    Node.js 20 + pm2             [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_NODEJS="no"
        read -p "    Python 3 + Gunicorn          [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_PYTHON="no"
        read -p "    Postfix + Dovecot (Email)    [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_MAIL="no"
        read -p "    vsftpd (FTP Server)          [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_FTP="no"
        read -p "    PowerDNS (DNS Server)        [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_DNS="no"
        read -p "    ClamAV (Virus Scanner)       [Y]: " input
        [[ "${input,,}" == "n" ]] && INSTALL_CLAMAV="no"
    fi

    # ── Confirmation ───────────────────────────────

    echo ""
    echo -e "  ${BOLD}${BLUE}STEP 4 of 4${NC} ${BOLD}— Review & Install${NC}"
    echo ""
    echo -e "  ${CYAN}╭─────────────────────────────────────────────────╮${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}Installation Summary${NC}                             ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}                                                 ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  Admin:       ${GREEN}$ADMIN_EMAIL${NC}"
    echo -e "  ${CYAN}│${NC}  Username:    ${GREEN}$ADMIN_USER${NC}"
    echo -e "  ${CYAN}│${NC}  Hostname:    ${GREEN}${HOSTNAME_SET}${NC}"
    echo -e "  ${CYAN}│${NC}  SSL:         $([ "$SETUP_SSL" == "yes" ] && echo "${GREEN}${SSL_DOMAIN}${NC}" || echo "${DIM}No${NC}")"
    echo -e "  ${CYAN}│${NC}                                                 ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}Core:${NC}  PostgreSQL 16 • Redis • Caddy • Fail2Ban  ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}Build:${NC} Go 1.23 • Node.js (build tools)           ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}                                                 ${CYAN}│${NC}"
    svc_icon() { [ "$1" == "yes" ] && echo -e "${GREEN}✓${NC}" || echo -e "${DIM}✗${NC}"; }
    echo -e "  ${CYAN}│${NC}  $(svc_icon $INSTALL_PHP) PHP    $(svc_icon $INSTALL_NODEJS) Node    $(svc_icon $INSTALL_PYTHON) Python   $(svc_icon $INSTALL_MAIL) Mail     ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  $(svc_icon $INSTALL_FTP) FTP    $(svc_icon $INSTALL_DNS) DNS     $(svc_icon $INSTALL_CLAMAV) ClamAV                ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}                                                 ${CYAN}│${NC}"
    echo -e "  ${CYAN}╰─────────────────────────────────────────────────╯${NC}"
    echo ""
    read -p "  Proceed with installation? (Y/n): " input
    [[ "${input,,}" == "n" ]] && echo "  Cancelled." && exit 0
else
    [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="NovaPanel@$(date +%Y)"
    [[ -z "$HOSTNAME_SET" ]] && HOSTNAME_SET=$(hostname -f 2>/dev/null || hostname)
fi

echo ""
SECONDS=0
TOTAL_STEPS=0
CURRENT_STEP=0

# Count total steps (system update, deps, go, pg, redis, caddy, mariadb, phpmyadmin, roundcube, setup, build, db, config, security, start = 15 base)
TOTAL_STEPS=15
[[ "$INSTALL_NODEJS" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_PHP" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_PYTHON" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_DNS" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_CLAMAV" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_MAIL" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$INSTALL_FTP" == "yes" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

echo -e "  ${DIM}Full log: ${INSTALL_LOG}${NC}"

# ── 1. System Update ────────────────────────────────

step "System update"
start_spinner "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
# Ubuntu 24.04 ships needrestart which otherwise opens an interactive
# whiptail prompt after every package install ("Which services should
# be restarted?") and blocks an automated install indefinitely.
# Mode 'a' = automatic, restart whatever needs restarting without asking.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Fresh Ubuntu VPSes fire apt-daily + unattended-upgrades on first boot,
# which races our own apt-get and makes every install fail with
# "Could not get lock /var/lib/dpkg/lock-frontend". Stop + mask those
# timers for the duration of the install so we own the dpkg lock.
run systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
run systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Wait out any apt process that's already mid-flight (e.g. fired
# before we could mask the timers). Polls up to 5 minutes then gives
# up — an installer that waits forever is worse than one that fails
# loudly with a clear message.
wait_for_apt_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge 300 ]; then
            echo -e "${RED}Another apt/dpkg process has held the lock for 5+ minutes.${NC}" >&2
            echo -e "${YELLOW}Run 'ps aux | grep -iE \"apt|dpkg\"' to find it, then kill or wait.${NC}" >&2
            return 1
        fi
        if [ $waited -eq 0 ]; then
            echo "  Waiting for background apt/dpkg to release the lock..." >> "$INSTALL_LOG"
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}
wait_for_apt_lock || exit 1

run apt-get update -qq || true
run apt-get upgrade -y -qq || true
stop_spinner "System packages updated"

# ── 2. Base Dependencies ────────────────────────────

step "Base dependencies"
start_spinner "Installing curl, git, ufw, fail2ban, build tools..."
run apt-get install -y -qq \
    curl wget gnupg2 software-properties-common \
    ca-certificates lsb-release apt-transport-https \
    unzip git jq htop net-tools ufw fail2ban \
    apparmor apparmor-utils python3 python3-pip \
    acl sudo build-essential || true
run apt-get install -y -qq python3-bcrypt || pip3 install bcrypt >> "$INSTALL_LOG" 2>&1 || true
stop_spinner "Base dependencies installed"

# ── 3. Go toolchain — SKIPPED ──────────────────────
# CDN-edition installer downloads a pre-built binary; no Go needed
# on customer servers. (bootstrap.sh installs Go for source builds.)

# ── 4. PostgreSQL 16 ───────────────────────────────

step "PostgreSQL 16"
start_spinner "Installing PostgreSQL 16..."
if ! command -v psql &>/dev/null; then
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget -q -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg 2>/dev/null
    run apt-get update -qq
    run apt-get install -y -qq postgresql-16 postgresql-client-16
fi
# Hard check: bail loudly if apt didn't actually install psql. Without
# this, the bootstrap used to march on, write a broken .env, fail the
# migration step, and leave the admin with a half-installed panel and
# a confusing "Migration failed on 001_initial.sql" error that was
# really "PostgreSQL never got installed".
if ! command -v psql >/dev/null 2>&1; then
    stop_spinner "PostgreSQL install failed — psql not found" fail
    echo -e "${RED}PostgreSQL 16 did not install cleanly. Check $INSTALL_LOG.${NC}" >&2
    echo -e "${YELLOW}Common causes: apt.postgresql.org unreachable, held packages, broken dpkg state.${NC}" >&2
    exit 1
fi
if ! id postgres >/dev/null 2>&1; then
    stop_spinner "PostgreSQL install failed — postgres user missing" fail
    echo -e "${RED}postgres system user not created. Rerun:${NC}" >&2
    echo "  apt-get install --reinstall postgresql-16" >&2
    exit 1
fi
# Idempotent user + db setup. Previously these ran unconditionally
# with `|| true`, which silently hid "password differs" errors on a
# re-run — the user existed with the old password, the script
# assumed success, and the panel couldn't connect on the next boot.
# Now: create only if missing, and always sync the password to
# match whatever's in .env (which we've already preserved above).
run sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    run sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
run sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
run sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    run sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
run sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
stop_spinner "PostgreSQL 16 configured"

# ── 5. Redis ───────────────────────────────────────

step "Redis"
start_spinner "Installing Redis..."
if ! command -v redis-server &>/dev/null; then
    run apt-get install -y -qq redis-server
fi
sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null || true
run systemctl restart redis-server
run systemctl enable redis-server
stop_spinner "Redis configured"

# ── 6. Caddy Web Server ───────────────────────────

step "Caddy web server (with Coraza WAF module)"
start_spinner "Installing Caddy..."
# Install the apt package first — we only want the systemd unit, caddy user,
# /etc/caddy directory and ancillary files it ships. The actual binary is
# replaced below with one that bundles the coraza-caddy plugin so NovaPanel's
# WAF feature actually filters traffic.
if ! dpkg -s caddy &>/dev/null; then
    run apt-get install -y -qq debian-keyring debian-archive-keyring || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >> "$INSTALL_LOG" 2>&1
    run apt-get update -qq
    run apt-get install -y -qq caddy
fi

# Swap the stock binary for a Caddy build that includes Coraza. Caddy's own
# build service produces reproducible binaries with selected modules.
CADDY_ARCH=$(dpkg --print-architecture)
case "$CADDY_ARCH" in
    amd64) CADDY_DL_ARCH="amd64" ;;
    arm64) CADDY_DL_ARCH="arm64" ;;
    armhf) CADDY_DL_ARCH="armv7" ;;
    *)     CADDY_DL_ARCH="amd64" ;;
esac

CADDY_BUILD_URL="https://caddyserver.com/api/download?os=linux&arch=${CADDY_DL_ARCH}&p=github.com%2Fcorazawaf%2Fcoraza-caddy%2Fv2"
CADDY_GOT=""

# First try: Caddy's hosted build service. Capped at 90s so a slow
# on-demand build on caddyserver.com doesn't hang the installer —
# the xcaddy local fallback is reliable, so bail fast and let it
# take over if the API is dragging. Skipped entirely if --skip-waf
# was passed, in which case stock Caddy is used.
if [ "${SKIP_WAF:-no}" != "yes" ] && curl -fsSL --max-time 90 --connect-timeout 10 "$CADDY_BUILD_URL" -o /tmp/caddy-waf 2>>"$INSTALL_LOG"; then
    chmod +x /tmp/caddy-waf
    # coraza-caddy registers its module as http.handlers.waf (not "coraza_waf"),
    # so grep for either form plus the plain word "coraza" to be robust.
    if /tmp/caddy-waf list-modules 2>/dev/null | grep -Eqi "coraza|http\.handlers\.waf"; then
        CADDY_GOT="/tmp/caddy-waf"
    else
        /tmp/caddy-waf list-modules 2>&1 | head -50 >> "$INSTALL_LOG" || true
        rm -f /tmp/caddy-waf
    fi
fi

# Fallback: build locally with xcaddy. Go is already installed for the panel.
# Each subcommand is capped by `timeout` so a stuck module fetch on a slow
# VPS doesn't block the whole install forever. Stock Caddy is a perfectly
# fine fallback — WAF just won't be available until the admin rebuilds it
# from the Settings page later.
if [ -z "$CADDY_GOT" ] && [ "${SKIP_WAF:-no}" != "yes" ] && command -v go >/dev/null 2>&1; then
    echo "INFO: Caddy build service unavailable, building locally with xcaddy" >> "$INSTALL_LOG"
    export GOBIN=/usr/local/bin
    export GOPATH=/tmp/gopath-xcaddy
    mkdir -p "$GOPATH"
    if timeout 180 go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >>"$INSTALL_LOG" 2>&1 && \
       timeout 480 /usr/local/bin/xcaddy build \
           --with github.com/corazawaf/coraza-caddy/v2 \
           --output /tmp/caddy-waf >>"$INSTALL_LOG" 2>&1; then
        chmod +x /tmp/caddy-waf
        if /tmp/caddy-waf list-modules 2>/dev/null | grep -Eqi "coraza|http\.handlers\.waf"; then
            CADDY_GOT="/tmp/caddy-waf"
        fi
    else
        echo "WARN: xcaddy build failed or timed out, continuing with stock Caddy" >> "$INSTALL_LOG"
    fi
    rm -rf "$GOPATH"
fi

if [ -n "$CADDY_GOT" ]; then
    mv "$CADDY_GOT" /usr/bin/caddy
    setcap 'cap_net_bind_service=+ep' /usr/bin/caddy 2>/dev/null || true
    apt-mark hold caddy >/dev/null 2>&1 || true
else
    echo "INFO: using stock Caddy (no Coraza WAF). Can be rebuilt later from admin panel." >> "$INSTALL_LOG"
fi

run systemctl enable caddy
stop_spinner "Caddy installed"

# ── MariaDB (Customer Databases) ───────────────────
# IMPORTANT: install MariaDB BEFORE the optional services (Postfix,
# Dovecot, OpenDKIM, etc). Installing it after the mail stack
# triggers a known interaction where deb-systemd-invoke fails
# silently in mariadb's post-install hook ("Could not execute
# systemctl: at /usr/bin/deb-systemd-invoke line 148"), apt returns
# 0 anyway, and mariadb is left installed but never started.
# Reproducible only with the cumulative state from earlier installs;
# manual `apt-get install mariadb-server` from a fresh shell works
# fine. Putting it here ensures only Postgres + Redis + Caddy have
# touched systemd state when mariadb's hook runs.

step "MariaDB"
start_spinner "Installing MariaDB..."
if ! command -v mysql &>/dev/null; then
    INSTALL_OK=0
    for attempt in 1 2 3; do
        if apt-get install -y mariadb-server mariadb-client >> "$INSTALL_LOG" 2>&1; then
            INSTALL_OK=1
            break
        fi
        echo "── retry $attempt: apt-get install mariadb-server" >> "$INSTALL_LOG"
        sleep 5
    done
    if [[ $INSTALL_OK -eq 0 ]]; then
        stop_spinner "MariaDB apt install failed after 3 retries — see $INSTALL_LOG" fail
        exit 1
    fi
    if ! dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
        stop_spinner "MariaDB apt-get returned 0 but mariadb-server is not installed — see $INSTALL_LOG" fail
        exit 1
    fi
    systemctl daemon-reload >> "$INSTALL_LOG" 2>&1
    systemctl enable mariadb >> "$INSTALL_LOG" 2>&1
    if [[ ! -d /var/lib/mysql/mysql ]]; then
        echo "── initializing mariadb data dir" >> "$INSTALL_LOG"
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql >> "$INSTALL_LOG" 2>&1 || \
            mysql_install_db --user=mysql --datadir=/var/lib/mysql >> "$INSTALL_LOG" 2>&1 || true
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        systemctl start mariadb >> "$INSTALL_LOG" 2>&1 || true
        sleep 2
        systemctl is-active --quiet mariadb && break
    done
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;" >> "$INSTALL_LOG" 2>&1 || true
fi
if ! command -v mysql >/dev/null 2>&1; then
    stop_spinner "MariaDB install failed — mysql client not found" fail
    exit 1
fi
if ! systemctl is-active --quiet mariadb; then
    stop_spinner "MariaDB install failed — service did not start" fail
    echo -e "${RED}Check: systemctl status mariadb${NC}" >&2
    exit 1
fi
stop_spinner "MariaDB installed (customer databases)"

# ── Optional: Node.js ──────────────────────────────

if [[ "$INSTALL_NODEJS" == "yes" ]]; then
    step "Node.js 20 + pm2"
    start_spinner "Installing Node.js..."
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - >> "$INSTALL_LOG" 2>&1
        run apt-get install -y -qq nodejs
    fi
    if ! command -v pm2 &>/dev/null; then
        run npm install -g pm2
    fi
    stop_spinner "Node.js $(node -v 2>/dev/null || echo '20') + pm2"
fi

# ── Optional: PHP 8.3 ─────────────────────────────

if [[ "$INSTALL_PHP" == "yes" ]]; then
    step "PHP 8.3"
    start_spinner "Installing PHP 8.3 + extensions..."
    if ! command -v php8.3 &>/dev/null; then
        run add-apt-repository -y ppa:ondrej/php || true
        run apt-get update -qq
        run apt-get install -y -qq \
            php8.3-fpm php8.3-cli php8.3-common \
            php8.3-mysql php8.3-pgsql php8.3-sqlite3 \
            php8.3-curl php8.3-gd php8.3-mbstring \
            php8.3-xml php8.3-zip php8.3-bcmath \
            php8.3-intl php8.3-readline php8.3-opcache \
            php8.3-redis php8.3-imagick || true
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' /etc/php/8.3/fpm/php.ini 2>/dev/null || true
        sed -i 's/^post_max_size.*/post_max_size = 64M/' /etc/php/8.3/fpm/php.ini 2>/dev/null || true
        sed -i 's/^memory_limit.*/memory_limit = 256M/' /etc/php/8.3/fpm/php.ini 2>/dev/null || true
        run systemctl enable php8.3-fpm
        run systemctl restart php8.3-fpm
    fi
    if ! command -v composer &>/dev/null; then
        curl -sS https://getcomposer.org/installer 2>/dev/null | php -- --install-dir=/usr/local/bin --filename=composer >> "$INSTALL_LOG" 2>&1 || true
    fi
    stop_spinner "PHP $(php -v 2>/dev/null | head -1 | awk '{print $2}' || echo '8.3') + Composer"
fi

# ── Optional: Python + Gunicorn ────────────────────

if [[ "$INSTALL_PYTHON" == "yes" ]]; then
    step "Python + Gunicorn"
    start_spinner "Installing Python tools..."
    run pip3 install gunicorn || true
    if ! command -v wp &>/dev/null; then
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar >> "$INSTALL_LOG" 2>&1 || true
        chmod +x wp-cli.phar 2>/dev/null && mv wp-cli.phar /usr/local/bin/wp 2>/dev/null || true
    fi
    stop_spinner "Python 3 + Gunicorn + WP-CLI"
fi

# ── Optional: PowerDNS ─────────────────────────────

if [[ "$INSTALL_DNS" == "yes" ]]; then
    step "PowerDNS"
    start_spinner "Installing PowerDNS..."
    if ! command -v pdns_server &>/dev/null; then
        run systemctl stop systemd-resolved || true
        run systemctl disable systemd-resolved || true
        if [[ -L /etc/resolv.conf ]]; then
            rm -f /etc/resolv.conf
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
        fi
        run apt-get install -y -qq pdns-server pdns-backend-pgsql || true
        # Ensure config directories exist
        mkdir -p /etc/powerdns/pdns.d 2>/dev/null || true
        rm -f /etc/powerdns/pdns.d/bind.conf 2>/dev/null || true
        rm -f /etc/powerdns/named.conf 2>/dev/null || true
        # Remove default configs that conflict
        rm -f /etc/powerdns/pdns.d/gdnsd.conf 2>/dev/null || true
        run sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='pdns'" | grep -q 1 || \
            run sudo -u postgres psql -c "CREATE USER pdns WITH PASSWORD '${PDNS_PASS}';"
        run sudo -u postgres psql -c "ALTER USER pdns WITH PASSWORD '${PDNS_PASS}';"
        run sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='pdns'" | grep -q 1 || \
            run sudo -u postgres psql -c "CREATE DATABASE pdns OWNER pdns;"
        cat > /etc/powerdns/pdns.d/gpgsql.conf 2>/dev/null << PDNSEOF
launch=gpgsql
gpgsql-host=127.0.0.1
gpgsql-dbname=pdns
gpgsql-user=pdns
gpgsql-password=${PDNS_PASS}
gpgsql-dnssec=yes
PDNSEOF
        # Contains the PowerDNS DB password — lock it down so only
        # root + pdns (via the group it's usually in) can read.
        chown root:pdns /etc/powerdns/pdns.d/gpgsql.conf 2>/dev/null || chmod 0600 /etc/powerdns/pdns.d/gpgsql.conf
        chmod 0640 /etc/powerdns/pdns.d/gpgsql.conf 2>/dev/null || true
        # Find and apply schema (location varies by distro)
        PDNS_SCHEMA=$(find /usr/share/doc/pdns-backend-pgsql* -name "schema.pgsql.sql" 2>/dev/null | head -1)
        if [[ -n "$PDNS_SCHEMA" ]]; then
            PGPASSWORD="${PDNS_PASS}" psql -U pdns -h localhost -d pdns < "$PDNS_SCHEMA" >> "$INSTALL_LOG" 2>&1 || true
        fi
        cat > /etc/powerdns/pdns.d/api.conf 2>/dev/null << APIEOF
api=yes
api-key=${PDNS_API_KEY}
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.1
APIEOF
        run systemctl enable pdns || true
        run systemctl restart pdns || true
    fi
    if systemctl is-active --quiet pdns 2>/dev/null; then
        stop_spinner "PowerDNS installed"
    else
        stop_spinner "PowerDNS installed (needs restart)" "warn"
    fi
fi

# ── Optional: ClamAV ──────────────────────────────

if [[ "$INSTALL_CLAMAV" == "yes" ]]; then
    step "ClamAV"
    start_spinner "Installing ClamAV virus scanner..."
    if ! command -v clamscan &>/dev/null; then
        run apt-get install -y -qq clamav clamav-daemon || true
        run systemctl stop clamav-freshclam || true
        run freshclam || true
        run systemctl enable clamav-freshclam || true
        run systemctl start clamav-freshclam || true
    fi
    # clamav-daemon (the scanner that NovaPanel's virus-scan feature
    # calls) is a separate unit from freshclam. It refuses to start
    # until freshclam has at least one signature DB on disk, so enable
    # it unconditionally and let systemd bring it up once ready.
    run systemctl enable clamav-daemon 2>/dev/null || true
    run systemctl start clamav-daemon 2>/dev/null || true
    stop_spinner "ClamAV installed"
fi

# ── Optional: Postfix + Dovecot (Email) ────────────

if [[ "$INSTALL_MAIL" == "yes" ]]; then
    step "Email (Postfix + Dovecot)"
    start_spinner "Installing email services..."
    if ! command -v postfix &>/dev/null; then
        debconf-set-selections <<< "postfix postfix/mailname string ${HOSTNAME_SET}"
        debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
        run apt-get install -y -qq postfix dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd || true
        # Ensure directories exist (packages may not create them on all distros)
        mkdir -p /etc/postfix /etc/dovecot/conf.d 2>/dev/null || true
        postconf -e "virtual_mailbox_domains = /etc/postfix/virtual_domains" 2>/dev/null || true
        postconf -e "virtual_mailbox_base = /var/mail/vhosts" 2>/dev/null || true
        postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox" 2>/dev/null || true
        postconf -e "virtual_uid_maps = static:5000" 2>/dev/null || true
        postconf -e "virtual_gid_maps = static:5000" 2>/dev/null || true
        postconf -e "smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem" 2>/dev/null || true
        postconf -e "smtpd_tls_key_file = /etc/ssl/private/ssl-cert-snakeoil.key" 2>/dev/null || true
        postconf -e "smtpd_tls_security_level = may" 2>/dev/null || true
        postconf -e "myhostname = ${HOSTNAME_SET}" 2>/dev/null || true
        groupadd -g 5000 vmail 2>/dev/null || true
        useradd -g vmail -u 5000 -d /var/mail/vhosts -s /usr/sbin/nologin vmail 2>/dev/null || true
        mkdir -p /var/mail/vhosts
        chown -R vmail:vmail /var/mail/vhosts
        touch /etc/postfix/vmailbox /etc/postfix/virtual_domains 2>/dev/null || true
        postmap /etc/postfix/vmailbox >> "$INSTALL_LOG" 2>&1 || true
        # Dovecot main config for virtual users
        cat > /etc/dovecot/conf.d/10-auth-nova.conf 2>/dev/null << 'DOVEOF'
# Disable default auth mechanisms
!include_try /etc/dovecot/conf.d/auth-system.conf.ext

# NovaPanel virtual user auth
disable_plaintext_auth = no
auth_mechanisms = plain login

passdb {
  driver = passwd-file
  args = scheme=BLF-CRYPT username_format=%u /etc/dovecot/users
}

userdb {
  driver = static
  args = uid=5000 gid=5000 home=/var/mail/vhosts/%d/%n
}
DOVEOF

        # Mail location config
        cat > /etc/dovecot/conf.d/10-mail-nova.conf 2>/dev/null << 'DOVMAILEOF'
mail_location = maildir:/var/mail/vhosts/%d/%n/Maildir
namespace inbox {
  inbox = yes
}
mail_privileged_group = vmail
DOVMAILEOF

        # SSL config for Dovecot
        cat > /etc/dovecot/conf.d/10-ssl-nova.conf 2>/dev/null << 'DOVSSLEOF'
ssl = yes
ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem
ssl_key = </etc/ssl/private/ssl-cert-snakeoil.key
DOVSSLEOF

        # Disable default auth includes that conflict
        sed -i 's/^!include auth-system/#!include auth-system/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true

        # Postfix SMTP auth via Dovecot
        postconf -e "smtpd_sasl_type = dovecot" 2>/dev/null || true
        postconf -e "smtpd_sasl_path = private/auth" 2>/dev/null || true
        postconf -e "smtpd_sasl_auth_enable = yes" 2>/dev/null || true

        # Dovecot auth socket for Postfix
        cat > /etc/dovecot/conf.d/10-master-nova.conf 2>/dev/null << 'DOVMASTEREOF'
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}
DOVMASTEREOF

        touch /etc/dovecot/users 2>/dev/null || true
        chown root:dovecot /etc/dovecot/users >> "$INSTALL_LOG" 2>&1 || true
        chmod 640 /etc/dovecot/users 2>/dev/null || true
        run systemctl enable postfix dovecot || true
        run systemctl restart postfix dovecot || true
    fi
    stop_spinner "Postfix + Dovecot installed"

    # ── OpenDKIM + OpenDMARC (email auth) ──────────────
    # Required for deliverability — unsigned outgoing mail goes straight
    # to spam on Gmail/Outlook. The admin-panel Mail Config page lets
    # operators enable/rotate keys later; this just installs the
    # packages + base config so the daemons exist and listen on a milter
    # socket Postfix can use.
    start_spinner "Installing OpenDKIM + OpenDMARC..."
    if ! command -v opendkim >/dev/null 2>&1; then
        run apt-get install -y -qq opendkim opendkim-tools opendmarc || true
        mkdir -p /etc/opendkim/keys /etc/opendmarc
        chown -R opendkim:opendkim /etc/opendkim 2>/dev/null || true
        chmod 750 /etc/opendkim/keys 2>/dev/null || true

        # Base OpenDKIM config — listens on a local unix socket that
        # Postfix talks to as a milter. KeyTable/SigningTable are
        # populated per-domain by the admin panel when a customer
        # enables DKIM signing.
        cat > /etc/opendkim.conf << 'DKIMEOF'
Syslog                  yes
UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1M
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
PidFile                 /var/run/opendkim/opendkim.pid
OversignHeaders         From
TrustAnchorFile         /usr/share/dns/root.key
UserID                  opendkim
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
DKIMEOF
        touch /etc/opendkim/KeyTable /etc/opendkim/SigningTable
        cat > /etc/opendkim/TrustedHosts << 'TRUSTEOF'
127.0.0.1
localhost
::1
TRUSTEOF
        mkdir -p /var/spool/postfix/opendkim
        chown opendkim:postfix /var/spool/postfix/opendkim 2>/dev/null || true
        chmod 750 /var/spool/postfix/opendkim 2>/dev/null || true

        # Base OpenDMARC config
        cat > /etc/opendmarc.conf << 'DMARCEOF'
AuthservID              HOSTNAME
PidFile                 /var/run/opendmarc/opendmarc.pid
RejectFailures          false
Syslog                  true
TrustedAuthservIDs      HOSTNAME
UserID                  opendmarc:opendmarc
UMask                   0002
Socket                  local:/var/spool/postfix/opendmarc/opendmarc.sock
DMARCEOF
        mkdir -p /var/spool/postfix/opendmarc
        chown opendmarc:postfix /var/spool/postfix/opendmarc 2>/dev/null || true
        chmod 750 /var/spool/postfix/opendmarc 2>/dev/null || true

        # Hook milters into Postfix so every outgoing mail passes
        # through DKIM+DMARC. Two sockets chained via smtpd_milters.
        postconf -e "milter_default_action = accept" 2>/dev/null || true
        postconf -e "milter_protocol = 6" 2>/dev/null || true
        postconf -e "smtpd_milters = unix:opendkim/opendkim.sock, unix:opendmarc/opendmarc.sock" 2>/dev/null || true
        postconf -e "non_smtpd_milters = unix:opendkim/opendkim.sock, unix:opendmarc/opendmarc.sock" 2>/dev/null || true

        run systemctl enable opendkim opendmarc 2>/dev/null || true
        run systemctl restart opendkim opendmarc 2>/dev/null || true
        run systemctl reload postfix 2>/dev/null || true
    fi
    stop_spinner "OpenDKIM + OpenDMARC installed"

    # ── SpamAssassin (inbound spam filtering) ──────────
    start_spinner "Installing SpamAssassin..."
    if ! command -v spamassassin >/dev/null 2>&1; then
        run apt-get install -y -qq spamassassin spamc || true
        sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/spamassassin 2>/dev/null || true
        run systemctl enable spamassassin 2>/dev/null || true
        run systemctl restart spamassassin 2>/dev/null || true
    fi
    stop_spinner "SpamAssassin installed"
fi

# ── Optional: vsftpd (FTP) ─────────────────────────

if [[ "$INSTALL_FTP" == "yes" ]]; then
    step "FTP (vsftpd)"
    start_spinner "Installing FTP server..."
    if ! command -v vsftpd &>/dev/null; then
        run apt-get install -y -qq vsftpd db-util || true
        cat > /etc/vsftpd.conf << 'FTPEOF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
guest_enable=YES
guest_username=ftp
virtual_use_local_privs=YES
user_sub_token=$USER
local_root=/srv/sites/$USER
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000
user_config_dir=/etc/vsftpd/user_conf
pam_service_name=vsftpd.virtual
ssl_enable=NO
FTPEOF
        mkdir -p /etc/vsftpd/user_conf
        # Create empty virtual users file and build initial Berkeley DB
        touch /etc/vsftpd/virtual_users.txt
        db_load -T -t hash -f /etc/vsftpd/virtual_users.txt /etc/vsftpd/virtual_users.db >> "$INSTALL_LOG" 2>&1 || true

        # Ensure ftp system user exists (guest_username)
        id ftp &>/dev/null || useradd -r -d /srv/sites -s /usr/sbin/nologin ftp 2>/dev/null || true

        cat > /etc/pam.d/vsftpd.virtual << 'PAMEOF'
auth required pam_userdb.so db=/etc/vsftpd/virtual_users
account required pam_userdb.so db=/etc/vsftpd/virtual_users
PAMEOF
        run systemctl enable vsftpd || true
        run systemctl restart vsftpd || true
    fi
    stop_spinner "vsftpd installed"
fi

# ── phpMyAdmin ─────────────────────────────────────

step "phpMyAdmin"
start_spinner "Installing phpMyAdmin..."
if [[ ! -d /opt/novapanel/web/phpmyadmin ]]; then
    PMA_VERSION="5.2.1"
    run wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz" -O /tmp/phpmyadmin.tar.gz || true
    if [[ -f /tmp/phpmyadmin.tar.gz ]]; then
        mkdir -p /opt/novapanel/web/phpmyadmin
        tar -xzf /tmp/phpmyadmin.tar.gz -C /opt/novapanel/web/phpmyadmin --strip-components=1 >> "$INSTALL_LOG" 2>&1
        rm -f /tmp/phpmyadmin.tar.gz
        PMA_SECRET=$(openssl rand -hex 16)
        cat > /opt/novapanel/web/phpmyadmin/config.inc.php << PMAEOF
<?php
\$cfg['blowfish_secret'] = '${PMA_SECRET}';
\$cfg['Servers'][1]['auth_type'] = 'cookie';
\$cfg['Servers'][1]['host'] = 'localhost';
\$cfg['Servers'][1]['compress'] = false;
\$cfg['Servers'][1]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['TempDir'] = '/tmp';
PMAEOF
    fi
fi
stop_spinner "phpMyAdmin installed"

# ── Roundcube ──────────────────────────────────────

step "Roundcube Webmail"
start_spinner "Installing Roundcube..."
if [[ ! -d /opt/novapanel/web/roundcube ]]; then
    RC_VERSION="1.6.9"
    run wget -q "https://github.com/roundcube/roundcubemail/releases/download/${RC_VERSION}/roundcubemail-${RC_VERSION}-complete.tar.gz" -O /tmp/roundcube.tar.gz || true
    if [[ -f /tmp/roundcube.tar.gz ]]; then
        mkdir -p /opt/novapanel/web/roundcube
        tar -xzf /tmp/roundcube.tar.gz -C /opt/novapanel/web/roundcube --strip-components=1 >> "$INSTALL_LOG" 2>&1
        rm -f /tmp/roundcube.tar.gz

        # Create Roundcube database
        run sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='roundcube'" | grep -q 1 || \
            run sudo -u postgres psql -c "CREATE USER roundcube WITH PASSWORD '${DB_PASS}';"
        run sudo -u postgres psql -c "ALTER USER roundcube WITH PASSWORD '${DB_PASS}';"
        run sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='roundcube'" | grep -q 1 || \
            run sudo -u postgres psql -c "CREATE DATABASE roundcube OWNER roundcube;"
        PGPASSWORD="${DB_PASS}" psql -U roundcube -h localhost -d roundcube < /opt/novapanel/web/roundcube/SQL/postgres.initial.sql >> "$INSTALL_LOG" 2>&1 || true

        # Roundcube config
        RC_DES_KEY=$(openssl rand -hex 12)
        cat > /opt/novapanel/web/roundcube/config/config.inc.php << RCEOF
<?php
\$config['db_dsnw'] = 'pgsql://roundcube:${DB_PASS}@localhost/roundcube';
\$config['imap_host'] = 'localhost';
\$config['imap_port'] = 143;
\$config['smtp_host'] = 'localhost';
\$config['smtp_port'] = 25;
\$config['smtp_user'] = '';
\$config['smtp_pass'] = '';
\$config['support_url'] = '';
\$config['product_name'] = 'NovaPanel Webmail';
\$config['des_key'] = '${RC_DES_KEY}';
\$config['plugins'] = array('archive', 'zipdownload');
\$config['skin'] = 'elastic';
\$config['language'] = 'en_US';
RCEOF
    fi
fi
stop_spinner "Roundcube Webmail installed"

# ── System User & Directories ──────────────────────

step "NovaPanel setup"
start_spinner "Creating system user and directories..."
if ! id "${NOVA_USER}" &>/dev/null; then
    run useradd -r -m -s /bin/bash -d /home/${NOVA_USER} ${NOVA_USER}
fi
loginctl enable-linger ${NOVA_USER} 2>/dev/null || true

mkdir -p ${NOVA_DIR}/{bin,config,web/admin,web/customer,migrations,templates,scripts}
mkdir -p ${NOVA_LOG}
mkdir -p ${NOVA_DATA}/{sites,backups,ssl,tmp}
mkdir -p /srv/sites
mkdir -p /srv/sites/.deploy-keys
mkdir -p /etc/caddy/sites
mkdir -p /var/log/caddy
mkdir -p /opt/novapanel/web/default

# License file lives in /etc/novapanel/license.json — owned by the panel
# user so it can be auto-fetched/refreshed by the running binary.
mkdir -p /etc/novapanel
chown ${NOVA_USER}:${NOVA_USER} /etc/novapanel
chmod 750 /etc/novapanel

# Default welcome page for unconfigured domains
cat > /opt/novapanel/web/default/index.html << 'DEFHTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Server — NovaPanel</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0a0e1a;color:#e2e8f0;font-family:system-ui,sans-serif}
.card{background:#111827;border:1px solid #1f2b3f;border-radius:16px;padding:48px;text-align:center;max-width:520px}
h1{font-size:32px;margin-bottom:12px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
p{color:#94a3b8;font-size:15px;line-height:1.6}
.badge{display:inline-block;margin-top:24px;padding:6px 16px;border-radius:999px;font-size:12px;color:#3b82f6;border:1px solid #3b82f620;background:#3b82f610}
</style></head>
<body><div class="card">
<h1>NovaPanel</h1>
<p>This server is managed by NovaPanel.<br>The domain you're visiting hasn't been configured yet.</p>
<span class="badge">Powered by NovaPanel</span>
</div></body></html>
DEFHTML

echo 'novapanel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/novapanel
chmod 440 /etc/sudoers.d/novapanel
stop_spinner "System user configured"

# ── License + Binary Download (CDN edition) ───────────
#
# Replaces the bootstrap.sh "git clone + go build + npm build SPAs +
# copy migrations" steps. The pre-built binary on R2 already contains:
#   - admin SPA       (//go:embed in internal/webui)
#   - customer SPA    (//go:embed in internal/webui)
#   - migrations      (//go:embed in internal/migrations)
# So we only need: fingerprint -> license -> download binary -> verify.

step "Provisioning license"
mkdir -p "${NOVA_LICENSE_DIR}"

# Stable machine fingerprint — matches what the panel computes at runtime
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)
PRIMARY_MAC=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo$|^docker|^br-|^veth|^virbr|^tun|^tap/ && $3 ~ /MULTICAST/ {print $2; exit}' | xargs -I{} cat /sys/class/net/{}/address 2>/dev/null | head -1)
HOST_FOR_FP=$(hostname)
FINGERPRINT=$(printf 'novapanel:v1\nmachine-id:%s\nmac:%s\nhost:%s\n' "$MACHINE_ID" "$PRIMARY_MAC" "$HOST_FOR_FP" | sha256sum | awk '{print $1}')
info "fingerprint: ${FINGERPRINT:0:16}…"

# Public IPs (best-effort, sent to license server for the dashboard)
PUBLIC_IPV4=$(curl -s -4 --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
PUBLIC_IPV6=$(curl -s -6 --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")

# Fetch the version manifest FIRST so the activate / community-license
# call can report the actual NovaPanel version (otherwise the dashboard
# shows panel_version="installer" forever, until the panel itself does
# its first heartbeat refresh ~24 days later).
start_spinner "Fetching version manifest..."
MANIFEST=$(curl -sf "$LICENSE_SERVER/api/v1/version/latest")
if [[ -z "$MANIFEST" ]]; then
    stop_spinner "Couldn't fetch version manifest" fail
    exit 1
fi
EXPECTED_SHA=$(echo "$MANIFEST" | jq -r .sha256)
NOVA_VER=$(echo "$MANIFEST" | jq -r .version)
EXPECTED_SIZE=$(echo "$MANIFEST" | jq -r .size_bytes)
NOVA_VERSION="$NOVA_VER"
NOVA_COMMIT=$(echo "$MANIFEST" | jq -r .commit)
stop_spinner "Latest version: ${NOVA_VER}"

start_spinner "Fetching license..."
if [[ -n "$PROVIDED_KEY" ]]; then
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/activate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg lk "$PROVIDED_KEY" --arg fp "$FINGERPRINT" \
            --arg hn "${HOSTNAME_SET:-$HOST_FOR_FP}" --arg pv "$NOVA_VER" \
            --arg v4 "$PUBLIC_IPV4" --arg v6 "$PUBLIC_IPV6" \
            '{license_key:$lk, fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')")
    if [[ -z "$LIC_RESP" ]]; then
        stop_spinner "License activation failed (key invalid?)" fail
        exit 1
    fi
    LICENSE_KEY="$PROVIDED_KEY"
else
    LIC_RESP=$(curl -sf -X POST "$LICENSE_SERVER/api/v1/community-license" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg fp "$FINGERPRINT" --arg hn "${HOSTNAME_SET:-$HOST_FOR_FP}" \
            --arg pv "$NOVA_VER" --arg v4 "$PUBLIC_IPV4" --arg v6 "$PUBLIC_IPV6" \
            '{fingerprint:$fp, hostname:$hn, panel_version:$pv, public_ipv4:$v4, public_ipv6:$v6}')")
    if [[ -z "$LIC_RESP" ]]; then
        stop_spinner "Community license issuance failed" fail
        exit 1
    fi
    LICENSE_KEY=$(echo "$LIC_RESP" | jq -r .license_key)
fi
LICENSE_TOKEN=$(echo "$LIC_RESP" | jq -r .token)
LICENSE_TIER=$(echo "$LIC_RESP" | jq -r .tier)
LICENSE_EXPIRES=$(echo "$LIC_RESP" | jq -r .expires_at)
cat > "${NOVA_LICENSE_DIR}/license.json" <<EOF
{
  "license_key": "${LICENSE_KEY}",
  "token": "${LICENSE_TOKEN}",
  "fingerprint": "${FINGERPRINT}",
  "tier": "${LICENSE_TIER}",
  "issued_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "expires_at": "${LICENSE_EXPIRES}"
}
EOF
chmod 640 "${NOVA_LICENSE_DIR}/license.json"
stop_spinner "License: ${LICENSE_TIER} (${LICENSE_KEY})"

step "Downloading NovaPanel binary"

start_spinner "Downloading binary..."
mkdir -p "${NOVA_DIR}/bin"
if ! curl -fL -H "Authorization: Bearer $LICENSE_TOKEN" \
    "$LICENSE_SERVER/api/v1/download/latest" \
    -o "${NOVA_DIR}/bin/novapanel" \
    >> "$INSTALL_LOG" 2>&1; then
    stop_spinner "Binary download failed" fail
    exit 1
fi
ACTUAL_SIZE=$(stat -c%s "${NOVA_DIR}/bin/novapanel")
ACTUAL_SHA=$(sha256sum "${NOVA_DIR}/bin/novapanel" | awk '{print $1}')
if [[ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]] || [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    stop_spinner "Binary verification failed (size or sha256 mismatch)" fail
    rm -f "${NOVA_DIR}/bin/novapanel"
    exit 1
fi
chmod +x "${NOVA_DIR}/bin/novapanel"
echo "${NOVA_VER}" > "${NOVA_DIR}/VERSION"
echo "${NOVA_COMMIT}" > "${NOVA_DIR}/COMMIT"
stop_spinner "Downloaded + verified (${ACTUAL_SIZE} bytes, sha256=${EXPECTED_SHA:0:12}…)"

# systemd unit: try a hosted copy first, fall back to writing inline
# below if it's not on R2 yet (the /etc/systemd/system/novapanel.service
# block in the Configuration step further down will overwrite either way).

# ── Database Migration ─────────────────────────────
# CDN edition: migrations run inside the panel binary at startup
# (internal/migrations is //go:embed-ed and applied by
# database.ApplyMigrationsFromFS). Admin user creation is deferred
# until after the panel is started — see the post-start block below.
step "Database"
start_spinner "Hashing admin password..."
ADMIN_HASH=$(echo -n "${ADMIN_PASS}" | python3 -c "import sys,bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt(12)).decode())" 2>/dev/null || echo "")
if [[ -z "$ADMIN_HASH" ]]; then
    stop_spinner "bcrypt hashing failed (python3 + python3-bcrypt missing?)" fail
    apt-get install -y -qq python3-bcrypt >> "$INSTALL_LOG" 2>&1
    ADMIN_HASH=$(echo -n "${ADMIN_PASS}" | python3 -c "import sys,bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt(12)).decode())" 2>/dev/null || echo "")
fi
stop_spinner "Admin password hashed (will be applied after first start)"

# ── Configuration ──────────────────────────────────

step "Configuration"
start_spinner "Writing config files..."

# .env
cat > ${NOVA_DIR}/config/.env << ENVEOF
NOVA_ENV=production
NOVA_LOG_LEVEL=info
NOVA_CUSTOMER_PORT=8083
NOVA_ADMIN_PORT=8087
NOVA_DB_HOST=localhost
NOVA_DB_PORT=5432
NOVA_DB_NAME=${DB_NAME}
NOVA_DB_USER=${DB_USER}
NOVA_DB_PASSWORD=${DB_PASS}
NOVA_DB_SSLMODE=disable
NOVA_DB_MAX_CONNS=25
NOVA_DB_MIN_CONNS=5
NOVA_REDIS_URL=redis://localhost:6379/0
NOVA_JWT_SECRET=${JWT_SECRET}
NOVA_JWT_ACCESS_TTL=15m
NOVA_JWT_REFRESH_TTL=7d
NOVA_CORS_ORIGINS=http://${SERVER_IP}:2083,http://${SERVER_IP}:2087,http://${HOSTNAME_SET}:2083,http://${HOSTNAME_SET}:2087$([ "$SETUP_SSL" == "yes" ] && echo ",https://${SSL_DOMAIN},https://${SSL_DOMAIN}:2083,https://${SSL_DOMAIN}:2087")
NOVA_RATE_LIMIT=60
NOVA_TRUSTED_PROXIES=127.0.0.1
NOVA_LICENSE_KEY=
NOVA_LICENSE_SERVER=https://license.novapanel.dev
NOVA_CADDY_API=http://localhost:2019
NOVA_POWERDNS_API=http://localhost:8081
NOVA_POWERDNS_KEY=${PDNS_API_KEY}
NOVA_ACME_EMAIL=${ADMIN_EMAIL}
ENVEOF
chmod 600 ${NOVA_DIR}/config/.env
chown ${NOVA_USER}:${NOVA_USER} ${NOVA_DIR}/config/.env
ln -sf ${NOVA_DIR}/config/.env ${NOVA_DIR}/.env

# Caddy main config
if [[ "$SETUP_SSL" == "yes" && -n "$SSL_DOMAIN" ]]; then
    cat > /etc/caddy/Caddyfile << CADDYEOF
{
    order coraza_waf first
    admin localhost:2019
    email ${ADMIN_EMAIL}
}

# Panel hostname — HTTPS on all ports
${SSL_DOMAIN} {
    reverse_proxy localhost:8083 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
}

${SSL_DOMAIN}:2083 {
    reverse_proxy localhost:8083 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

${SSL_DOMAIN}:2087 {
    reverse_proxy localhost:8087 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

${SSL_DOMAIN}:8888 {
    root * /opt/novapanel/web/phpmyadmin
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

${SSL_DOMAIN}:8889 {
    root * /opt/novapanel/web/roundcube
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

# IP access — HTTP on all service ports
http://:2083 {
    reverse_proxy localhost:8083 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

http://:2087 {
    reverse_proxy localhost:8087 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

http://:8888 {
    root * /opt/novapanel/web/phpmyadmin
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

http://:8889 {
    root * /opt/novapanel/web/roundcube
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

# Default welcome page (port 80 only)
http://:80 {
    root * /opt/novapanel/web/default
    file_server
    encode gzip
}

import /etc/caddy/sites/*.caddy
CADDYEOF
else
    cat > /etc/caddy/Caddyfile << 'CADDYEOF'
{
    order coraza_waf first
    admin localhost:2019
}

http://:2083 {
    reverse_proxy localhost:8083 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

http://:2087 {
    reverse_proxy localhost:8087 {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}

http://:8888 {
    root * /opt/novapanel/web/phpmyadmin
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

http://:8889 {
    root * /opt/novapanel/web/roundcube
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}

http://:80 {
    root * /opt/novapanel/web/default
    file_server
    encode gzip
}

import /etc/caddy/sites/*.caddy
CADDYEOF
fi

rm -f /etc/caddy/sites/phpmyadmin.caddy /etc/caddy/sites/roundcube.caddy 2>/dev/null || true

# Open ports for phpMyAdmin and Roundcube
ufw allow 8888/tcp >> "$INSTALL_LOG" 2>&1 || true
ufw allow 8889/tcp >> "$INSTALL_LOG" 2>&1 || true

# Systemd service — written inline since CDN-edition has no source tree
cat > /etc/systemd/system/novapanel.service <<'SVCEOF'
[Unit]
Description=NovaPanel Hosting Control Panel
Documentation=https://novapanel.dev
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target redis-server.service
Requires=postgresql.service

[Service]
Type=simple
User=novapanel
Group=novapanel
WorkingDirectory=/opt/novapanel
EnvironmentFile=/opt/novapanel/config/.env
ExecStart=/opt/novapanel/bin/novapanel
Restart=always
RestartSec=5
TimeoutStartSec=120
SyslogIdentifier=novapanel

NoNewPrivileges=false
PrivateTmp=yes
ProtectSystem=true
ProtectHome=read-only
ReadWritePaths=/srv /var/log/novapanel /var/lib/novapanel /var/spool/cron /etc/novapanel -/etc/caddy -/etc/php -/etc/postfix -/etc/dovecot -/etc/powerdns -/etc/vsftpd -/etc/opendkim -/etc/opendmarc -/etc/fail2ban
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=no
RestrictRealtime=yes
LockPersonality=yes

LimitNOFILE=65535
MemoryMax=2G
CPUQuota=200%
TasksMax=2048

[Install]
WantedBy=multi-user.target
SVCEOF
chown novapanel:novapanel "${NOVA_LICENSE_DIR}/license.json" 2>/dev/null || true

# Permissions
chown -R ${NOVA_USER}:${NOVA_USER} ${NOVA_DIR}
chown -R ${NOVA_USER}:${NOVA_USER} ${NOVA_LOG}
chown -R ${NOVA_USER}:${NOVA_USER} ${NOVA_DATA}
chown -R ${NOVA_USER}:${NOVA_USER} /srv/sites
chown ${NOVA_USER}:${NOVA_USER} /etc/caddy/sites
chown caddy:caddy /var/log/caddy
chmod 755 /var/log/caddy ${NOVA_DATA}/tmp

stop_spinner "Configuration written"

# ── Firewall + Security ────────────────────────────

step "Security"
start_spinner "Configuring firewall, Fail2Ban, kernel..."
# ufw rule order matters when the firewall is already active — we
# add every allow rule FIRST, then set the default deny, then enable.
# Otherwise "ufw default deny incoming" applies before 22/tcp is
# allowed and a remote installer loses its own SSH session.
ufw allow 22/tcp    >> "$INSTALL_LOG" 2>&1 || true
ufw allow 80/tcp    >> "$INSTALL_LOG" 2>&1 || true
ufw allow 443/tcp   >> "$INSTALL_LOG" 2>&1 || true
ufw allow 2083/tcp  >> "$INSTALL_LOG" 2>&1 || true
ufw allow 2087/tcp  >> "$INSTALL_LOG" 2>&1 || true
[[ "$INSTALL_MAIL" == "yes" ]] && {
    ufw allow 25/tcp  >> "$INSTALL_LOG" 2>&1 || true
    ufw allow 587/tcp >> "$INSTALL_LOG" 2>&1 || true
    ufw allow 993/tcp >> "$INSTALL_LOG" 2>&1 || true
    ufw allow 995/tcp >> "$INSTALL_LOG" 2>&1 || true
}
[[ "$INSTALL_FTP" == "yes" ]] && {
    ufw allow 21/tcp >> "$INSTALL_LOG" 2>&1 || true
    ufw allow 30000:31000/tcp >> "$INSTALL_LOG" 2>&1 || true
}
[[ "$INSTALL_DNS" == "yes" ]] && {
    ufw allow 53/tcp >> "$INSTALL_LOG" 2>&1 || true
    ufw allow 53/udp >> "$INSTALL_LOG" 2>&1 || true
}
ufw default deny incoming >> "$INSTALL_LOG" 2>&1 || true
ufw default allow outgoing >> "$INSTALL_LOG" 2>&1 || true
ufw --force enable >> "$INSTALL_LOG" 2>&1 || true

# Log rotation — without this /var/log/caddy can grow gigabytes on
# a busy host. daily + rotate 14 keeps two weeks.
cp "${NOVA_DIR}/scripts/logrotate.novapanel" /etc/logrotate.d/novapanel 2>/dev/null || \
    cp ${NOVA_DIR}/scripts/logrotate.novapanel /etc/logrotate.d/novapanel 2>/dev/null || true
chmod 0644 /etc/logrotate.d/novapanel 2>/dev/null || true

mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d 2>/dev/null || true
cat > /etc/fail2ban/jail.d/novapanel.conf 2>/dev/null << 'F2BEOF'
[novapanel-auth]
enabled = true
port = 2083,2087
filter = novapanel-auth
logpath = /var/log/novapanel/panel.log
maxretry = 5
bantime = 12h
findtime = 300
F2BEOF
cat > /etc/fail2ban/filter.d/novapanel-auth.conf 2>/dev/null << 'F2BFILTER'
[Definition]
failregex = .*"status":401.*"ip":"<HOST>".*
ignoreregex =
F2BFILTER
run systemctl restart fail2ban || true

cat > /etc/sysctl.d/99-novapanel.conf << 'SYSEOF'
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 2097152
vm.swappiness = 10
SYSEOF
sysctl -p /etc/sysctl.d/99-novapanel.conf >> "$INSTALL_LOG" 2>&1 || true

# MOTD — CDN edition has no source tree; skip the motd script copy.
# The panel admin can install a custom MOTD later via the file manager.
chmod -x /etc/update-motd.d/* 2>/dev/null || true
sed -i 's/^#\?PrintMotd.*/PrintMotd no/' /etc/ssh/sshd_config 2>/dev/null || true
echo "" > /etc/motd 2>/dev/null || true
systemctl reload sshd >> "$INSTALL_LOG" 2>&1 || systemctl reload ssh >> "$INSTALL_LOG" 2>&1 || true

stop_spinner "Firewall + Fail2Ban + MOTD configured"

# ── Start Services ─────────────────────────────────

step "Starting NovaPanel"
start_spinner "Starting services..."
# Restore the apt-daily timers we masked at the start of the install
# so security updates resume in the background.
run systemctl unmask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true

run systemctl daemon-reload
run systemctl enable novapanel
run systemctl restart caddy
run systemctl start novapanel

sleep 3

if systemctl is-active --quiet novapanel; then
    STATUS="${GREEN}● Running${NC}"
else
    STATUS="${RED}● Failed${NC} — check: ${DIM}journalctl -u novapanel -n 50${NC}"
fi
stop_spinner "NovaPanel started"

# ── Apply admin credentials post-start ─────────────
# Migrations run on the first panel startup. Wait for the users table
# to exist, then INSERT/UPDATE the admin row with operator's chosen
# email + username + bcrypt-hashed password.
if [[ -n "$ADMIN_HASH" ]]; then
    start_spinner "Applying admin credentials..."
    APPLIED=0
    LAST_ERR=""
    # 90 retries × 1s = 90s wall-clock max. Migrations themselves take
    # ~1-2s on a normal VPS but we leave generous headroom for slow disks
    # / first-boot cloud-init contention. Also re-check the panel is
    # actually running on each iteration so we exit quickly if the
    # service crashed instead of waiting the full 90s.
    for i in $(seq 1 90); do
        if ! systemctl is-active --quiet novapanel; then
            LAST_ERR="novapanel service not running (check: journalctl -u novapanel)"
            break
        fi
        EXISTS=$(PGPASSWORD="${DB_PASS}" psql -h localhost -U ${DB_USER} -d ${DB_NAME} -tAc "SELECT to_regclass('public.users')" 2>>"$INSTALL_LOG" || true)
        if [[ "$EXISTS" == "users" ]]; then
            if PGPASSWORD="${DB_PASS}" psql -v ON_ERROR_STOP=1 -h localhost -U ${DB_USER} -d ${DB_NAME} >> "$INSTALL_LOG" 2>&1 <<EOF
INSERT INTO users (email, username, password_hash, role)
VALUES ('${ADMIN_EMAIL}', '${ADMIN_USER}', '${ADMIN_HASH}', 'admin')
ON CONFLICT (username) DO UPDATE SET
    email = EXCLUDED.email,
    password_hash = EXCLUDED.password_hash,
    is_active = true,
    updated_at = NOW();
EOF
            then
                APPLIED=1
            else
                LAST_ERR="INSERT/UPDATE failed — see $INSTALL_LOG"
            fi
            break
        fi
        sleep 1
    done
    if [[ $APPLIED -eq 1 ]]; then
        stop_spinner "Admin credentials applied (login: $ADMIN_USER / your chosen password)"
    else
        stop_spinner "Couldn't apply admin credentials: $LAST_ERR — falling back to default seed" fail
        echo -e "  ${YELLOW}Default credentials: admin@novapanel.local / NovaPanel@2024${NC}" >&2
        echo -e "  ${YELLOW}Change immediately after first login.${NC}" >&2
        ADMIN_EMAIL="admin@novapanel.local"
        ADMIN_USER="admin"
        ADMIN_PASS="NovaPanel@2024"
    fi
fi

# Cleanup
rm -rf /tmp/gopath 2>/dev/null || true

DURATION=$SECONDS

# Service health check — lists every service the installer actually
# enables, so the admin gets an honest snapshot at the end. Each entry
# is gated by whether the relevant --no-* flag was used OR whether the
# service unit exists on disk (for core services installed via deps of
# others like php-fpm, mariadb, clamav).
svc_status() {
    # Allow the caller to pass socket-activated units or timers
    # explicitly — default to .service otherwise.
    local unit="$1"
    case "$unit" in
        *.service|*.socket|*.timer|*.target|*.mount) : ;;
        *) unit="${unit}.service" ;;
    esac
    if systemctl list-unit-files --quiet "$unit" 2>/dev/null | grep -q "^${unit}"; then
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            echo -e "    ${GREEN}●${NC} $1"
        else
            echo -e "    ${RED}●${NC} $1"
        fi
    fi
}

echo ""
echo -e "  ${BOLD}Service Status:${NC}"
svc_status novapanel
svc_status caddy
svc_status postgresql
svc_status redis-server
svc_status mariadb
svc_status fail2ban
[[ "$INSTALL_PHP"    == "yes" ]] && svc_status php8.3-fpm
[[ "$INSTALL_MAIL"   == "yes" ]] && { svc_status postfix; svc_status dovecot; svc_status opendkim; svc_status opendmarc; svc_status spamassassin; }
[[ "$INSTALL_FTP"    == "yes" ]] && svc_status vsftpd
[[ "$INSTALL_DNS"    == "yes" ]] && svc_status pdns
[[ "$INSTALL_CLAMAV" == "yes" ]] && { svc_status clamav-daemon; svc_status clamav-freshclam; }

# ── Done ───────────────────────────────────────────

PANEL_URL="http://${SERVER_IP}"

echo ""
echo ""
echo -e "${GREEN}    ╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}    ║${NC}                                                       ${GREEN}║${NC}"
echo -e "${GREEN}    ║${NC}   ${GREEN}${BOLD}✓ NovaPanel installed successfully!${NC}                  ${GREEN}║${NC}"
echo -e "${GREEN}    ║${NC}                                                       ${GREEN}║${NC}"
echo -e "${GREEN}    ╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Status:${NC}        ${STATUS}"
echo -e "  ${BOLD}Installed in:${NC}  ${GREEN}$((DURATION / 60))m $((DURATION % 60))s${NC}"
echo ""
echo -e "  ${CYAN}╭─────────────────────────────────────────────────────╮${NC}"
echo -e "  ${CYAN}│${NC}  ${BOLD}Panel Access${NC}                                        ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}                                                     ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  Customer Panel   ${BOLD}${PANEL_URL}:2083${NC}"
echo -e "  ${CYAN}│${NC}  Admin Panel      ${BOLD}${PANEL_URL}:2087${NC}"
echo -e "  ${CYAN}│${NC}  phpMyAdmin       ${BOLD}${PANEL_URL}:8888${NC}"
echo -e "  ${CYAN}│${NC}  Roundcube Mail   ${BOLD}${PANEL_URL}:8889${NC}"
if [[ "$SETUP_SSL" == "yes" && -n "$SSL_DOMAIN" ]]; then
echo -e "  ${CYAN}│${NC}  HTTPS Access     ${BOLD}https://${SSL_DOMAIN}${NC} (auto-cert)"
fi
echo -e "  ${CYAN}│${NC}                                                     ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${BOLD}Login Credentials${NC}                                   ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  Email:     ${GREEN}${ADMIN_EMAIL}${NC}"
echo -e "  ${CYAN}│${NC}  Password:  ${GREEN}${ADMIN_PASS}${NC}"
echo -e "  ${CYAN}│${NC}                                                     ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  ${BOLD}Database${NC}                                             ${CYAN}│${NC}"
echo -e "  ${CYAN}│${NC}  Host: localhost  DB: ${DB_NAME}  User: ${DB_USER}"
echo -e "  ${CYAN}│${NC}  Password:  ${YELLOW}${DB_PASS}${NC}"
echo -e "  ${CYAN}╰─────────────────────────────────────────────────────╯${NC}"
echo ""
echo -e "  ${BOLD}Useful Commands:${NC}"
echo -e "    ${DIM}systemctl status novapanel${NC}        Service status"
echo -e "    ${DIM}journalctl -u novapanel -f${NC}        Live logs"
echo -e "    ${DIM}nova status${NC}                       Panel status"
echo -e "    ${DIM}nova-update${NC}                       Update to latest"
echo ""

# Save credentials to file
cat > /root/.novapanel-credentials << CREDEOF
NovaPanel Installation Credentials
===================================
Installed: $(date)
Version:   ${NOVA_VERSION}

Customer Panel: ${PANEL_URL}:2083
Admin Panel:    ${PANEL_URL}:2087

Admin Email:    ${ADMIN_EMAIL}
Admin User:     ${ADMIN_USER}
Admin Password: ${ADMIN_PASS}

Database:
  Host:     localhost
  Name:     ${DB_NAME}
  User:     ${DB_USER}
  Password: ${DB_PASS}

JWT Secret:     ${JWT_SECRET}
PowerDNS Key:   ${PDNS_API_KEY}

Config File:    ${NOVA_DIR}/config/.env
Service File:   /etc/systemd/system/novapanel.service
CREDEOF
chmod 600 /root/.novapanel-credentials

echo -e "  ${YELLOW}${BOLD}⚠  Credentials saved to /root/.novapanel-credentials${NC}"
echo -e "  ${YELLOW}${BOLD}⚠  Keep this file safe and delete when no longer needed!${NC}"
echo ""
