#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# BizCode Integration Platform — Interactive Installer
# ============================================================

BOLD="\033[1m"
BLUE="\033[0;34m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

header() { echo -e "\n${BLUE}${BOLD}$1${NC}"; }
info()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

ask() {
    local var=$1 prompt=$2 default=$3
    if [ -n "$default" ]; then
        read -rp "$(echo -e "${BOLD}$prompt${NC} [$default]: ")" input
        eval "$var=\"${input:-$default}\""
    else
        while true; do
            read -rp "$(echo -e "${BOLD}$prompt${NC}: ")" input
            [ -n "$input" ] && break
            echo -e "${RED}  This field is required.${NC}"
        done
        eval "$var=\"$input\""
    fi
}

ask_yn() {
    local var=$1 prompt=$2 default=$3
    while true; do
        read -rp "$(echo -e "${BOLD}$prompt${NC} [${default}]: ")" input
        input="${input:-$default}"
        case "$input" in
            [Yy]*) eval "$var=true"; return ;;
            [Nn]*) eval "$var=false"; return ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

ask_password() {
    local var=$1 prompt=$2 default=$3
    read -rsp "$(echo -e "${BOLD}$prompt${NC} [$default]: ")" input
    echo
    eval "$var=\"${input:-$default}\""
}

# Check if a port is available
check_port() {
    local port=$1
    if (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
        return 1  # port is in use
    else
        return 0  # port is free
    fi
}

# ── Banner ──
echo -e "${BLUE}${BOLD}"
cat << 'BANNER'

  ____  _     ____          _
 | __ )(_)___/ ___|___   __| | ___
 |  _ \| |_  / |   / _ \ / _` |/ _ \
 | |_) | |/ /| |__| (_) | (_| |  __/
 |____/|_/___|\____\___/ \__,_|\___|

  Integration Platform Installer

BANNER
echo -e "${NC}"

# ── Install Docker if missing ──
install_docker() {
    header "Installing Docker..."

    # Detect distro
    if [ ! -f /etc/os-release ]; then
        error "Cannot detect OS. Only Ubuntu and Debian are supported."
    fi
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ;;
        *) error "Unsupported distro: $ID. Only Ubuntu and Debian are supported." ;;
    esac
    info "Detected: $PRETTY_NAME"

    # Check root/sudo
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
        command -v sudo >/dev/null 2>&1 || error "sudo is required to install Docker. Run as root or install sudo."
    else
        SUDO=""
    fi

    # Install prerequisites
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Add Docker GPG key
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} \
      ${VERSION_CODENAME} stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    info "Docker installed"

    # Post-install: enable and start
    $SUDO systemctl enable docker.service >/dev/null 2>&1
    $SUDO systemctl enable containerd.service >/dev/null 2>&1
    $SUDO systemctl start docker.service
    info "Docker service enabled and started"

    # Post-install: non-root user
    if [ -n "${SUDO_USER:-}" ]; then
        DOCKER_USER="$SUDO_USER"
    elif [ "$(id -u)" -ne 0 ]; then
        DOCKER_USER="$(whoami)"
    else
        DOCKER_USER=""
    fi
    if [ -n "$DOCKER_USER" ]; then
        $SUDO groupadd -f docker
        $SUDO usermod -aG docker "$DOCKER_USER"
        info "User '$DOCKER_USER' added to docker group (re-login required for non-sudo usage)"
    fi

    # Post-install: log rotation
    if [ ! -f /etc/docker/daemon.json ]; then
        $SUDO mkdir -p /etc/docker
        $SUDO tee /etc/docker/daemon.json > /dev/null << 'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMON
        $SUDO systemctl restart docker.service
        info "Log rotation configured (json-file, 10m x 3)"
    else
        warn "/etc/docker/daemon.json already exists — skipping log config"
    fi
}

# ── Prerequisites ──
header "Checking prerequisites..."
if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed."
    ask_yn INSTALL_DOCKER "Install Docker automatically?" "y"
    if [ "$INSTALL_DOCKER" = "true" ]; then
        install_docker
    else
        error "Docker is required. Install manually: https://docs.docker.com/engine/install/"
    fi
fi
docker compose version >/dev/null 2>&1 || error "Docker Compose v2 is not available. Reinstall Docker with compose plugin."

DOCKER_VERSION=$(docker --version | sed -n 's/.*version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
info "Docker ${DOCKER_VERSION:-unknown}"
info "Docker Compose $(docker compose version --short 2>/dev/null)"

# ── Deployment mode ──
header "Deployment mode"
echo "  1) dev  — direct port access (1880-1889), no SSL, for development/testing"
echo "  2) prod — Nginx Proxy Manager with SSL, domain-based routing"
echo ""
ask MODE "Choose mode (1=dev, 2=prod)" "1"
case "$MODE" in
    1|dev)  MODE="dev" ;;
    2|prod) MODE="prod" ;;
    *) error "Invalid mode" ;;
esac
info "Mode: $MODE"

# ── ACR Credentials ──
header "Azure Container Registry credentials"
echo "  These are provided by BizCode with your license."
ask ACR_USERNAME "ACR Username" ""
ask_password ACR_PASSWORD "ACR Password" ""

echo ""
echo -e "  Logging in to ACR..."
echo "$ACR_PASSWORD" | docker login bizcode.azurecr.io -u "$ACR_USERNAME" --password-stdin >/dev/null 2>&1 \
    || error "ACR login failed. Please check your credentials."
info "ACR login successful"

# ── Node-RED Admin ──
header "Node-RED admin credentials"
ask NR_ADMIN_USER "Admin username" "admin"
ask_password NR_ADMIN_PASS "Admin password" "bizcode2025!"

# ── Instances ──
header "BIP instances"
ask BIP_COUNT "How many instances? (1-10)" "10"
[[ "$BIP_COUNT" =~ ^[0-9]+$ ]] && [ "$BIP_COUNT" -ge 1 ] && [ "$BIP_COUNT" -le 10 ] || error "Must be between 1 and 10"
info "$BIP_COUNT instances (bip-00 to bip-$(printf '%02d' $((BIP_COUNT - 1))))"

# ── Infrastructure services ──
header "Infrastructure services"
ask_yn ENABLE_REDIS    "Enable Redis?          (cache, pub/sub)" "y"
ask_yn ENABLE_RABBITMQ "Enable RabbitMQ?       (message queue)" "y"
ask_yn ENABLE_POSTGRES "Enable PostgreSQL?     (database)" "y"
ask_yn ENABLE_CUPS     "Enable CUPS?           (print server)" "y"

REDIS_PASSWORD="bizcode-redis-$(openssl rand -hex 4)"
RABBITMQ_USER="bizcode"
RABBITMQ_PASS="bizcode-rmq-$(openssl rand -hex 4)"
POSTGRES_USER="bizcode"
POSTGRES_PASS="bizcode-pg-$(openssl rand -hex 4)"
POSTGRES_DB="bizcode"
CUPS_ADMIN_PASS="bizcode-cups-$(openssl rand -hex 4)"

# ── Prod-specific ──
BASE_DOMAIN=""
LETSENCRYPT_EMAIL=""
NPM_DB_PASSWORD="bizcode-npm-$(openssl rand -hex 4)"

if [ "$MODE" = "prod" ]; then
    header "Production settings"
    ask BASE_DOMAIN "Base domain (e.g. integrations.klient.pl)" ""
    ask LETSENCRYPT_EMAIL "Email for Let's Encrypt" ""
fi

# ── Extra hosts ──
header "Extra hosts (SAP server resolution)"
echo "  Add hostname:IP pairs for SAP servers accessible via NetBIOS."
echo "  Leave empty to skip, or enter comma-separated pairs."
echo "  Example: sapserver:192.168.1.100,sapdb:192.168.1.101"
read -rp "$(echo -e "${BOLD}Extra hosts${NC} [none]: ")" EXTRA_HOSTS
EXTRA_HOSTS="${EXTRA_HOSTS:-}"
if [ -n "$EXTRA_HOSTS" ]; then
    info "Extra hosts: $EXTRA_HOSTS"
else
    info "No extra hosts configured"
fi

# ── Check port availability ──
header "Checking port availability..."
PORTS_IN_USE=()

if [ "$MODE" = "dev" ]; then
    for i in $(seq 0 $((BIP_COUNT - 1))); do
        port=$((1880 + i))
        if ! check_port $port; then
            PORTS_IN_USE+=("$port (bip-$(printf '%02d' $i))")
        fi
    done
fi

if [ "$MODE" = "prod" ]; then
    for port in 80 443 81; do
        if ! check_port $port; then
            PORTS_IN_USE+=("$port (Nginx Proxy Manager)")
        fi
    done
fi

if [ "$ENABLE_REDIS" = "true" ] && ! check_port 6379; then
    PORTS_IN_USE+=("6379 (Redis)")
fi
if [ "$ENABLE_RABBITMQ" = "true" ]; then
    ! check_port 5672 && PORTS_IN_USE+=("5672 (RabbitMQ)")
    ! check_port 15672 && PORTS_IN_USE+=("15672 (RabbitMQ Management)")
fi
if [ "$ENABLE_POSTGRES" = "true" ] && ! check_port 5432; then
    PORTS_IN_USE+=("5432 (PostgreSQL)")
fi
if [ "$ENABLE_CUPS" = "true" ] && ! check_port 631; then
    PORTS_IN_USE+=("631 (CUPS)")
fi

if [ ${#PORTS_IN_USE[@]} -gt 0 ]; then
    warn "The following ports are already in use:"
    for p in "${PORTS_IN_USE[@]}"; do
        echo -e "    ${RED}$p${NC}"
    done
    echo ""
    echo "  Options:"
    echo "    1) Stop the conflicting services and re-run ./install.sh"
    echo "    2) Continue anyway (containers using these ports will fail to start)"
    echo "    3) Abort installation"
    echo ""
    ask PORT_ACTION "Choose (1/2/3)" "3"
    case "$PORT_ACTION" in
        1) error "Please stop the conflicting services and re-run ./install.sh" ;;
        2) warn "Continuing with port conflicts — some containers may not start" ;;
        3) error "Installation aborted" ;;
        *) error "Invalid choice" ;;
    esac
else
    info "All required ports are available"
fi

# ── Generate .env ──
header "Generating configuration..."

cat > .env << ENVFILE
# Generated by install.sh on $(date -Iseconds)
# BizCode Integration Platform

ACR_USERNAME=${ACR_USERNAME}
ACR_PASSWORD=${ACR_PASSWORD}

MODE=${MODE}

NR_ADMIN_USER=${NR_ADMIN_USER}
NR_ADMIN_PASS=${NR_ADMIN_PASS}

BIP_INSTANCE_COUNT=${BIP_COUNT}

ENABLE_REDIS=${ENABLE_REDIS}
ENABLE_RABBITMQ=${ENABLE_RABBITMQ}
ENABLE_POSTGRES=${ENABLE_POSTGRES}
ENABLE_CUPS=${ENABLE_CUPS}

REDIS_PASSWORD=${REDIS_PASSWORD}

RABBITMQ_USER=${RABBITMQ_USER}
RABBITMQ_PASS=${RABBITMQ_PASS}

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASS=${POSTGRES_PASS}
POSTGRES_DB=${POSTGRES_DB}

CUPS_ADMIN_PASS=${CUPS_ADMIN_PASS}

BASE_DOMAIN=${BASE_DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
NPM_DB_PASSWORD=${NPM_DB_PASSWORD}

EXTRA_HOSTS=${EXTRA_HOSTS}
ENVFILE

info ".env generated"

# ── Generate docker-compose.override.yml for instance count and extra_hosts ──
header "Generating docker-compose.override.yml..."

cat > docker-compose.override.yml << 'HEADER'
# Auto-generated by install.sh — instance and extra_hosts overrides
services:
HEADER

# Build extra_hosts YAML block
EXTRA_HOSTS_YAML=""
if [ -n "$EXTRA_HOSTS" ]; then
    EXTRA_HOSTS_YAML="    extra_hosts:"
    IFS=',' read -ra PAIRS <<< "$EXTRA_HOSTS"
    for pair in "${PAIRS[@]}"; do
        host=$(echo "$pair" | cut -d: -f1 | xargs)
        ip=$(echo "$pair" | cut -d: -f2 | xargs)
        EXTRA_HOSTS_YAML="${EXTRA_HOSTS_YAML}
      - \"${host}:${ip}\""
    done
fi

for i in $(seq 0 9); do
    idx=$(printf '%02d' $i)
    if [ $i -lt "$BIP_COUNT" ]; then
        # Active instance
        if [ -n "$EXTRA_HOSTS_YAML" ]; then
            cat >> docker-compose.override.yml << EOF
  bip-${idx}:
${EXTRA_HOSTS_YAML}
EOF
        fi
    else
        # Disabled instance — scale to 0
        cat >> docker-compose.override.yml << EOF
  bip-${idx}:
    deploy:
      replicas: 0
EOF
    fi
done

info "docker-compose.override.yml generated (${BIP_COUNT} active instances)"

# ── Build compose profiles ──
PROFILES=""
[ "$ENABLE_REDIS" = "true" ] && PROFILES="$PROFILES --profile redis"
[ "$ENABLE_RABBITMQ" = "true" ] && PROFILES="$PROFILES --profile rabbitmq"
[ "$ENABLE_POSTGRES" = "true" ] && PROFILES="$PROFILES --profile postgres"
[ "$ENABLE_CUPS" = "true" ] && PROFILES="$PROFILES --profile cups"

# Save profiles for future use
echo "$PROFILES" > .profiles
info "Compose profiles: ${PROFILES:-none}"

# ── Pull images ──
header "Pulling images..."
COMPOSE_CMD="docker compose"
if [ "$MODE" = "prod" ]; then
    COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
fi

$COMPOSE_CMD $PROFILES pull 2>&1 | tail -5
info "Images pulled"

# ── Start ──
header "Starting BizCode Integration Platform..."
if ! $COMPOSE_CMD $PROFILES up -d 2>&1; then
    echo ""
    warn "Some containers may have failed to start. Check status with: ./ctl.sh status"
fi

# ── Verify ──
header "Verifying services..."
sleep 3
FAILED=0
RUNNING=0
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if [ "$state" = "running" ]; then
        info "$name is running"
        RUNNING=$((RUNNING + 1))
    else
        warn "$name is $state"
        FAILED=$((FAILED + 1))
    fi
done < <($COMPOSE_CMD $PROFILES ps --format '{{.Name}} {{.State}}' 2>/dev/null)

echo ""
if [ "$FAILED" -gt 0 ]; then
    warn "$RUNNING running, $FAILED failed. Check: ./ctl.sh logs <service-name>"
else
    info "All $RUNNING services running"
fi

# ── Auto-configure NPM proxy hosts (prod mode) ──
if [ "$MODE" = "prod" ]; then
    header "Configuring Nginx Proxy Manager..."

    # Wait for NPM API to be ready
    NPM_READY=false
    for i in $(seq 1 30); do
        if curl -sf http://localhost:81/api/ >/dev/null 2>&1; then
            NPM_READY=true
            break
        fi
        sleep 2
    done

    if [ "$NPM_READY" = "true" ]; then
        # Login with default credentials (first run)
        NPM_TOKEN=$(curl -sf http://localhost:81/api/tokens \
            -H "Content-Type: application/json" \
            -d '{"identity":"admin@example.com","secret":"changeme"}' \
            | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')

        if [ -n "$NPM_TOKEN" ]; then
            info "NPM API authenticated"

            NPM_CONFIGURED=0
            for i in $(seq 0 $((BIP_COUNT - 1))); do
                idx=$(printf '%02d' $i)
                RESULT=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:81/api/nginx/proxy-hosts \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $NPM_TOKEN" \
                    -d "{
                        \"domain_names\": [\"bip-${idx}.${BASE_DOMAIN}\"],
                        \"forward_scheme\": \"http\",
                        \"forward_host\": \"bip-${idx}\",
                        \"forward_port\": 1880,
                        \"block_exploits\": true,
                        \"allow_websocket_upgrade\": true,
                        \"ssl_forced\": false,
                        \"http2_support\": false,
                        \"meta\": {\"dns_challenge\": false}
                    }")
                if [ "$RESULT" = "201" ]; then
                    NPM_CONFIGURED=$((NPM_CONFIGURED + 1))
                else
                    warn "Failed to configure proxy for bip-${idx} (HTTP $RESULT)"
                fi
            done
            info "$NPM_CONFIGURED proxy hosts configured"
            echo ""
            warn "Change the NPM admin password at http://localhost:81 !"
        else
            warn "Could not authenticate with NPM API — configure proxy hosts manually"
        fi
    else
        warn "NPM API not ready after 60s — configure proxy hosts manually at http://localhost:81"
    fi
fi

# ── Summary ──
header "Installation complete!"
echo ""
echo -e "${BOLD}Access your instances:${NC}"

if [ "$MODE" = "dev" ]; then
    for i in $(seq 0 $((BIP_COUNT - 1))); do
        idx=$(printf '%02d' $i)
        port=$((1880 + i))
        echo -e "  bip-${idx}:  ${GREEN}http://localhost:${port}${NC}"
    done
else
    echo -e "  Nginx Proxy Manager:  ${GREEN}http://localhost:81${NC}"
    echo ""
    for i in $(seq 0 $((BIP_COUNT - 1))); do
        idx=$(printf '%02d' $i)
        echo -e "  bip-${idx}:  ${GREEN}https://bip-${idx}.${BASE_DOMAIN}${NC}"
    done
    echo ""
    echo -e "  ${YELLOW}Add SSL certificates in NPM for each host to enable HTTPS${NC}"
fi

echo ""
echo -e "${BOLD}Infrastructure:${NC}"
[ "$ENABLE_REDIS" = "true" ]    && echo -e "  Redis:      ${GREEN}bip-redis:6379${NC}      password: ${REDIS_PASSWORD}"
[ "$ENABLE_RABBITMQ" = "true" ] && echo -e "  RabbitMQ:   ${GREEN}bip-rabbitmq:5672${NC}   user: ${RABBITMQ_USER}  mgmt: http://localhost:15672"
[ "$ENABLE_POSTGRES" = "true" ] && echo -e "  PostgreSQL: ${GREEN}bip-postgres:5432${NC}   user: ${POSTGRES_USER}  db: ${POSTGRES_DB}"
[ "$ENABLE_CUPS" = "true" ]     && echo -e "  CUPS:       ${GREEN}http://localhost:631${NC} admin: admin/${CUPS_ADMIN_PASS}"

echo ""
echo -e "${BOLD}Node-RED login:${NC} ${NR_ADMIN_USER} / ${NR_ADMIN_PASS}"
echo ""
echo -e "${BOLD}Management:${NC}"
echo "  Start:   ./ctl.sh start"
echo "  Stop:    ./ctl.sh stop"
echo "  Status:  ./ctl.sh status"
echo "  Logs:    ./ctl.sh logs bip-00"
echo "  Update:  ./ctl.sh update"
echo ""
echo -e "${BOLD}Credentials saved in:${NC} .env"
echo -e "${YELLOW}Keep this file safe — it contains all passwords.${NC}"
echo ""
echo -e "${GREEN}${BOLD}BizCode Integration Platform is ready!${NC}"
