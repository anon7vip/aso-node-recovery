#!/usr/bin/env bash
# ASO Node Recovery - Smart Auto-Installer
# Auto-detects environment, generates secrets, and installs everything needed.
# Only prompts for credentials that cannot be auto-generated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

NON_INTERACTIVE=false
SKIP_DOCKER_INSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive|-n) NON_INTERACTIVE=true ;;
        --skip-docker-install) SKIP_DOCKER_INSTALL=true ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ "$NON_INTERACTIVE" == true ]]; then
    export DEBIAN_FRONTEND=noninteractive
fi

# ============================================================
# Step 1: Detect OS and environment
# ============================================================
log "Detecting system environment..."

OS_NAME="unknown"
OS_VERSION=""
ARCHITECTURE="$(uname -m)"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
fi

log "  OS: ${PRETTY_NAME:-$OS_NAME $OS_VERSION}"
log "  Architecture: $ARCHITECTURE"

# Check if running as root or have sudo
HAS_SUDO=false
if [[ $(id -u) -eq 0 ]]; then
    SUDO=""
else
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
        HAS_SUDO=true
    else
        error "Not running as root and sudo not found. Please run with sudo or as root."
        exit 1
    fi
fi

# ============================================================
# Step 2: Check hardware requirements
# ============================================================
log "Checking hardware requirements..."

MIN_RAM_MB=2048
MIN_CPU=1
MIN_DISK_GB=10

# Check RAM
if command -v free &>/dev/null; then
    TOTAL_RAM_KB=$(free -k | awk '/^Mem:/ {print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
    if [[ $TOTAL_RAM_MB -ge $MIN_RAM_MB ]]; then
        ok "RAM: ${TOTAL_RAM_MB} MB (minimum: ${MIN_RAM_MB} MB)"
    else
        warn "RAM: ${TOTAL_RAM_MB} MB is below recommended minimum of ${MIN_RAM_MB} MB"
    fi
fi

# Check CPU
CPU_CORES=$(nproc 2>/dev/null || echo 1)
if [[ $CPU_CORES -ge $MIN_CPU ]]; then
    ok "CPU: ${CPU_CORES} core(s) (minimum: ${MIN_CPU})"
else
    warn "CPU: ${CPU_CORES} core(s) is below recommended minimum of ${MIN_CPU}"
fi

# Check disk space
DISK_AVAILABLE_KB=$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
DISK_AVAILABLE_GB=$((DISK_AVAILABLE_KB / 1024 / 1024))
if [[ $DISK_AVAILABLE_GB -ge $MIN_DISK_GB ]]; then
    ok "Disk: ${DISK_AVAILABLE_GB} GB available (minimum: ${MIN_DISK_GB} GB)"
else
    warn "Disk: ${DISK_AVAILABLE_GB} GB is below recommended minimum of ${MIN_DISK_GB} GB"
fi

# ============================================================
# Step 3: Install Docker if not present
# ============================================================
if [[ "$SKIP_DOCKER_INSTALL" == false ]]; then
    log "Checking for Docker..."

    if ! command -v docker &>/dev/null; then
        log "Docker not found. Installing..."

        case "$OS_NAME" in
            ubuntu|debian)
                # Remove conflicting packages
                $SUDO apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

                # Install prerequisites
                $SUDO apt-get update -qq
                $SUDO apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null

                # Add Docker GPG key and repository
                INSTALL_DIR="/usr/share/keyrings"
                $SUDO mkdir -p "$INSTALL_DIR"
                curl -fsSL https://download.docker.com/linux/${OS_NAME}/gpg | $SUDO gpg --dearmor -o "$INSTALL_DIR/docker.gpg" >/dev/null

                echo "deb [arch=$(dpkg --print-architecture) signed-by=$INSTALL_DIR/docker.gpg] https://download.docker.com/linux/${OS_NAME} $(lsb_release -cs) stable" \
                    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

                # Install Docker
                $SUDO apt-get update -qq
                $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null

                # Start and enable Docker
                $SUDO systemctl start docker
                $SUDO systemctl enable docker
                ;;
            *)
                warn "Auto-install of Docker not supported on $OS_NAME."
                warn "Please install Docker manually from https://docs.docker.com/get-docker/"
                exit 1
                ;;
        esac

        ok "Docker installed successfully"
    else
        ok "Docker already installed: $(docker --version)"
    fi

    # Check Docker Compose plugin
    if ! docker compose version &>/dev/null; then
        error "Docker Compose plugin not found. Please install it."
        exit 1
    fi
    ok "Docker Compose: $(docker compose version | grep -oP 'v?[\d.]+' | head -1)"

    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        warn "Starting Docker daemon..."
        $SUDO systemctl start docker 2>/dev/null || true
        sleep 3
        if ! docker info &>/dev/null; then
            error "Cannot connect to Docker daemon. Is it running?"
            exit 1
        fi
    fi
    ok "Docker daemon is running"
fi

# ============================================================
# Step 4: Generate secrets and create .env
# ============================================================
log "Generating configuration..."

# Copy .env.example if .env doesn't exist
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        log "Created .env from template"
    else
        error ".env.example not found. Cannot create configuration."
        exit 1
    fi
fi

# Generate PostgreSQL password (auto-generated, not prompted)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
ok "Generated PostgreSQL password"

# Generate Telegram callback secret (auto-generated, not prompted)
TELEGRAM_CALLBACK_SECRET=$(openssl rand -hex 32)
ok "Generated Telegram callback secret"

# Construct database URL
ASO_DATABASE_URL="postgresql+asyncpg://aso:${POSTGRES_PASSWORD}@postgres:5432/aso"

# Update .env with generated values
if command -v sed &>/dev/null; then
    # Replace POSTGRES_PASSWORD placeholder or add it
    if grep -q "^POSTGRES_PASSWORD=" "$ENV_FILE"; then
        sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" "$ENV_FILE"
    else
        echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" >> "$ENV_FILE"
    fi

    # Replace ASO_DATABASE_URL
    if grep -q "^ASO_DATABASE_URL=" "$ENV_FILE"; then
        sed -i "s|^ASO_DATABASE_URL=.*|ASO_DATABASE_URL=${ASO_DATABASE_URL}|" "$ENV_FILE"
    else
        echo "ASO_DATABASE_URL=${ASO_DATABASE_URL}" >> "$ENV_FILE"
    fi

    # Replace TELEGRAM_CALLBACK_SECRET
    if grep -q "^ASO_TELEGRAM_CALLBACK_SECRET=" "$ENV_FILE"; then
        sed -i "s|^ASO_TELEGRAM_CALLBACK_SECRET=.*|ASO_TELEGRAM_CALLBACK_SECRET=${TELEGRAM_CALLBACK_SECRET}|" "$ENV_FILE"
    else
        echo "ASO_TELEGRAM_CALLBACK_SECRET=${TELEGRAM_CALLBACK_SECRET}" >> "$ENV_FILE"
    fi
fi

# ============================================================
# Step 5: Prompt for required credentials (only what's needed)
# ============================================================
log "Checking for required configuration..."

NEEDS_INPUT=false

# Check if Telegram bot token is set
if ! grep -q "^ASO_TELEGRAM_BOT_TOKEN=.+" "$ENV_FILE" 2>/dev/null; then
    if [[ "$NON_INTERACTIVE" == false ]]; then
        NEEDS_INPUT=true
        log "Telegram Bot Token not configured. (Press Enter to skip)"
        read -r -p "  Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
            sed -i "s|^ASO_TELEGRAM_BOT_TOKEN=.*|ASO_TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}|" "$ENV_FILE"
            ok "Telegram Bot Token configured"

            # Prompt for authorized user IDs if token provided
            read -r -p "  Your Telegram User ID (for authorization): " TELEGRAM_USER_ID
            if [[ -n "$TELEGRAM_USER_ID" ]]; then
                sed -i "s|^ASO_TELEGRAM_AUTHORIZED_USER_IDS=.*|ASO_TELEGRAM_AUTHORIZED_USER_IDS=[${TELEGRAM_USER_ID}]|" "$ENV_FILE"
                ok "Telegram user ID authorized"
            fi
        else
            warn "Skipping Telegram configuration (can be added later)"
        fi
    else
        warn "Telegram Bot Token not set. Skipping (non-interactive mode)."
    fi
fi

# Check if Master 3X-UI is configured
if ! grep -q "^ASO_MASTER_3XUI_BASE_URL=.+" "$ENV_FILE" 2>/dev/null; then
    if [[ "$NON_INTERACTIVE" == false ]]; then
        NEEDS_INPUT=true
        log "Master 3X-UI Base URL not configured. (Press Enter to skip)"
        read -r -p "  Master 3X-UI Base URL (e.g., https://panel.example.com/QAZ): " MASTER_URL
        if [[ -n "$MASTER_URL" ]]; then
            sed -i "s|^ASO_MASTER_3XUI_BASE_URL=.*|ASO_MASTER_3XUI_BASE_URL=${MASTER_URL}|" "$ENV_FILE"
            ok "Master 3X-UI URL configured"

            read -r -p "  Master 3X-UI API Token (or press Enter for username/password): " MASTER_TOKEN
            if [[ -n "$MASTER_TOKEN" ]]; then
                sed -i "s|^ASO_MASTER_3XUI_API_TOKEN=.*|ASO_MASTER_3XUI_API_TOKEN=${MASTER_TOKEN}|" "$ENV_FILE"
                ok "Master 3X-UI API Token configured"
            else
                read -r -p "  Master 3X-UI Username: " MASTER_USER
                read -r -s -p "  Master 3X-UI Password: " MASTER_PASS
                echo ""
                sed -i "s|^ASO_MASTER_3XUI_USERNAME=.*|ASO_MASTER_3XUI_USERNAME=${MASTER_USER}|" "$ENV_FILE"
                sed -i "s|^ASO_MASTER_3XUI_PASSWORD=.*|ASO_MASTER_3XUI_PASSWORD=${MASTER_PASS}|" "$ENV_FILE"
                ok "Master 3X-UI credentials configured"
            fi
        else
            warn "Skipping Master 3X-UI configuration (can be added later)"
        fi
    else
        warn "Master 3X-UI not configured. Skipping (non-interactive mode)."
    fi
fi

# Check for provider tokens (optional, only prompt if neither is set)
HAS_HETZNER=false
HAS_LINODE=false
grep -q "^ASO_HETZNER_API_TOKEN=.+" "$ENV_FILE" 2>/dev/null && HAS_HETZNER=true
grep -q "^ASO_LINODE_API_TOKEN=.+" "$ENV_FILE" 2>/dev/null && HAS_LINODE=true

if [[ "$HAS_HETZNER" == false && "$HAS_LINODE" == false && "$NON_INTERACTIVE" == false ]]; then
    NEEDS_INPUT=true
    log "No VPS provider tokens configured. (Press Enter to skip)"
    read -r -p "  Hetzner API Token: " HETZNER_TOKEN
    if [[ -n "$HETZNER_TOKEN" ]]; then
        sed -i "s|^ASO_HETZNER_API_TOKEN=.*|ASO_HETZNER_API_TOKEN=${HETZNER_TOKEN}|" "$ENV_FILE"
        ok "Hetzner API Token configured"
    fi

    read -r -p "  Linode API Token: " LINODE_TOKEN
    if [[ -n "$LINODE_TOKEN" ]]; then
        sed -i "s|^ASO_LINODE_API_TOKEN=.*|ASO_LINODE_API_TOKEN=${LINODE_TOKEN}|" "$ENV_FILE"
        ok "Linode API Token configured"
    fi
fi

# Set file permissions on .env (secure)
chmod 600 "$ENV_FILE"
ok ".env secured (permissions 600)"

# ============================================================
# Step 6: Build and start services
# ============================================================
log "Building Docker images..."
cd "$SCRIPT_DIR"
docker compose -f docker-compose.yml build --quiet-pull

log "Starting PostgreSQL..."
docker compose -f docker-compose.yml up -d postgres

# Wait for PostgreSQL to be ready
log "Waiting for PostgreSQL to be ready..."
MAX_WAIT=120
WAITED=0
until docker compose -f docker-compose.yml exec -T postgres pg_isready -U aso &>/dev/null; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        error "PostgreSQL did not become ready within ${MAX_WAIT}s"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
ok "PostgreSQL is ready"

log "Running database migrations..."
docker compose -f docker-compose.yml run --rm api alembic upgrade head
ok "Database migrations applied"

log "Starting API service..."
docker compose -f docker-compose.yml up -d api

# Wait for API to be healthy
log "Waiting for API to become healthy..."
MAX_WAIT=60
WAITED=0
until curl -sf http://localhost:8000/health &>/dev/null; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        error "API did not become healthy within ${MAX_WAIT}s"
        echo ""
        echo "Check logs with: docker compose -f docker-compose.yml logs api"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
ok "API is healthy at http://localhost:8000/health"

# ============================================================
# Step 7: Summary and next steps
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ASO Node Recovery installed successfully!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Quick commands:"
echo "  ./asoctl status    - Check service status"
echo "  ./asoctl logs      - View application logs"
echo "  ./asoctl restart   - Restart all services"
echo "  ./asoctl stop      - Stop all services"
echo ""
echo "Next steps:"
echo "  1. Configure Telegram bot:     ./asoctl setup telegram"
echo "  2. Configure Master 3X-UI:     ./asoctl setup master"
echo "  3. Add provider API tokens:    ./asoctl setup providers"
echo "  4. Onboard existing node:      ./asoctl setup node"
echo ""
echo "Safety notes:"
echo "  - DRY_RUN is enabled by default (no real VPS changes)"
echo "  - Enable real operations only after testing"
echo "  - See README.md for detailed configuration guide"
echo ""
echo -e "${GREEN}============================================================${NC}"
