# ASO Node Recovery

**Automatic VPS node recovery and replacement system.** When a 3X-UI proxy node becomes unreachable from Iran, ASO automatically provisions a replacement VPS, verifies it's reachable from Iran, deploys 3X-UI on it, and swaps it into your panel — all without manual intervention.

## How It Works

```
Node goes down → Check-Host confirms (from Iran) → ASO creates new VPS → 
Wait for SSH ready → Deploy 3X-UI → Verify from Iran → Update Master panel → Old VPS deleted
```

**Key invariant:** The old VPS is only deleted after the replacement passes all verification steps:
1. Provider provisioning complete
2. Reachable from outside Iran
3. Reachable from **inside Iran** (critical!)
4. SSH ready and accessible
5. 3X-UI installed and configured
6. Node API verified
7. Master panel updated
8. Final health check passed

## Features

- 🚀 **Automatic replacement** — No permanent spare VPS needed; creates on-demand
- 🇮🇷 **Iran reachability verification** — Uses Check-Host.net nodes inside Iran
- 🔒 **Safety-first design** — DRY_RUN mode, multiple kill switches, emergency stop
- 💬 **Telegram control plane** — Manage everything from a Telegram bot
- 📊 **Monitoring** — Continuous health checks with configurable thresholds
- 🔄 **Multi-provider** — Supports Hetzner and Linode
- 🛡️ **Hardened Docker deployment** — Security-focused production setup
- 💾 **Backup/restore** — PostgreSQL backup tooling

## Quick Installation

The smart installer auto-detects your system, installs Docker if needed, generates secure random passwords, and only asks for credentials it can't generate on its own.

```bash
# Clone the repository
git clone https://github.com/anon7vip/aso-node-recovery.git
cd aso-node-recovery

# Run the installer (interactive)
sudo ./install.sh

# Or non-interactive (auto-generates everything, skips prompts)
sudo ./install.sh --non-interactive
```

**What the installer does automatically:**
- Detects your OS and architecture
- Checks hardware requirements (2GB+ RAM, 1+ CPU, 10GB+ disk)
- Installs Docker & Compose if missing (Ubuntu/Debian)
- Generates secure PostgreSQL password
- Generates Telegram callback secret
- Creates `.env` with safe defaults
- Builds Docker images
- Starts PostgreSQL and runs database migrations
- Starts the API service and verifies health

**What it will ask you for (optional, can skip):**
- Telegram Bot Token (for bot control)
- Your Telegram User ID (for authorization)
- Master 3X-UI Base URL and credentials
- Hetzner/Linode API tokens

All other configuration values are auto-detected or use safe defaults.

### Manual Installation (Docker)

If you prefer manual setup:

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your configuration
nano .env

# Start PostgreSQL
docker compose up -d postgres

# Wait for DB, then run migrations
docker compose exec -T postgres pg_isready -U aso && \
docker compose run --rm api alembic upgrade head

# Start services
docker compose up -d api worker
```

## Configuration

All configuration is done through the `.env` file. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `ASO_DRY_RUN` | `true` | Safety mode — no real VPS changes |
| `ASO_TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot token for control plane |
| `ASO_MASTER_3XUI_BASE_URL` | *(empty)* | Your 3X-UI panel URL |
| `ASO_HETZNER_API_TOKEN` | *(empty)* | Hetzner Cloud API token |
| `ASO_LINODE_API_TOKEN` | *(empty)* | Linode API token |
| `ASO_CHECK_HOST_COUNTRY_CODE` | `ir` | Country code for reachability checks |
| `ASO_FAILURE_THRESHOLD` | `3` | Failed checks before declaring node down |
| `ASO_SSH_VERIFY_HOST_KEY` | `false` | SSH host key verification (off for ephemeral VPS) |

**Safety guards (keep disabled until ready):**
- `ASO_DRY_RUN=true` — Change to `false` only when you want real VPS operations
- `ASO_ALLOW_REAL_INFRASTRUCTURE_MUTATION=false` — Must be true for real changes
- `ASO_ALLOW_OLD_VPS_DELETION=false` — Independent guard for deleting old VPS

## Operational Commands

The `asoctl` script provides convenient management commands:

```bash
./asoctl status          # Check service status
./asoctl logs            # View application logs
./asoctl restart         # Restart all services
./asoctl stop            # Stop all services
./asoctl backup          # Create database backup
./asoctl restore         # Restore from backup
./asoctl setup           # Interactive onboarding wizard
```

## Telegram Bot Control

Once configured with a bot token, control ASO via Telegram:

- `/start` — Main menu
- `/nodes` — List all nodes and their status
- `/providers` — Manage VPS providers
- `/health` — Check system health
- `/force <id>` — Force repair a specific node
- `/pause` / `/resume` — Pause/resume monitoring

Each node can be set to:
- **AUTO REPAIR** — Automatically replace when down
- **MONITOR ONLY** — Alert but don't replace
- **DISABLED** — No monitoring

## Upgrade

```bash
git pull --ff-only
./asoctl upgrade
```

The upgrade process:
1. Creates a backup of the database
2. Rebuilds Docker images
3. Runs database migrations
4. Restarts services
5. Verifies health

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│ Check-Host  │────▶│ Monitoring   │────▶│ Replacement │
│ (Iran nodes)│     │ Worker       │     │ Orchestrator│
└─────────────┘     └──────────────┘     └─────────────┘
                                               │
┌─────────────┐     ┌──────────────┐          ▼
│ Telegram    │◀────│ Control Plane│     ┌─────────────┐
│ Bot         │     │ (FastAPI)    │◀────│ PostgreSQL  │
└─────────────┘     └──────────────┘     └─────────────┘
                                               │
                    ┌──────────────────────────▼──────────────────────┐
                    │              Provider Adapters                  │
                    │        (Hetzner Cloud / Linode API)             │
                    └──────────────────────────┬──────────────────────┘
                                               │
                    ┌──────────────────────────▼──────────────────────┐
                    │           SSH Deployment Pipeline               │
                    │   OS detect → Bootstrap → Install 3X-UI → Verify│
                    └─────────────────────────────────────────────────┘
```

## Safety Model

ASO follows defense-in-depth with multiple independent safety layers:

1. **DRY_RUN mode** — Default; simulates all operations without making changes
2. **Real mutation guard** — Independent flag that must be explicitly enabled
3. **Old VPS deletion guard** — Separate flag and confirmation phrase required
4. **Emergency stop** — `ASO_REPLACEMENT_EMERGENCY_STOP=true` halts all replacement activity
5. **Capacity guards** — Limits on concurrent replacements and temporary servers
6. **Lease system** — Prevents duplicate operations during crashes

## Development

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
cp .env.example .env

# Run tests
pytest

# Lint and format
ruff check .
ruff format --check .

# Run API in development mode
uvicorn app.main:app --reload
```

## Requirements

- Docker Engine + Compose plugin
- Ubuntu/Debian (recommended) or any Linux with Docker
- 2GB+ RAM, 1+ CPU, 10GB+ disk space
- Outbound HTTPS access for provider APIs and Telegram

## Documentation

- [Quick Installation Guide](docs/QUICK_INSTALL.md)
- [Operational Onboarding](docs/ONBOARDING.md)
- [Production Deployment](docs/PRODUCTION.md)
- [Telegram Control](docs/TELEGRAM.md)
- [Replacement Workflow](docs/REPLACEMENT.md)
- [Backup & Restore](docs/BACKUP_RESTORE.md)
- [Security Controls](docs/SECURITY.md)
- [Force Repair](docs/FORCE_REPAIR.md)

## License

See the repository for license information.
