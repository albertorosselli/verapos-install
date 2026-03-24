#!/usr/bin/env bash
# install.sh — VeraPOS one-command store-backend installer
#
# Usage:
#   curl -s https://install.verapos.co | sudo bash
#   STORE_ID=mi-tienda curl -s https://install.verapos.co | sudo bash
#
# Env overrides (set before piping):
#   STORE_ID      — unique store slug (default: hostname)
#   VERAPOS_DIR   — install path      (default: /opt/verapos)
#   REPO_URL      — git remote        (default: GitHub)
#
# Idempotent: safe to re-run. Existing .env and data volumes are preserved.
# Supports: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12.

set -euo pipefail
IFS=$'\n\t'

# ── Tunables ──────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/albertorosselli/verapos-v1.git}"
VERAPOS_DIR="${VERAPOS_DIR:-/opt/verapos}"
STORE_ID="${STORE_ID:-$(hostname -s)}"
COMPOSE_FILE="deploy/local/docker-compose.yml"
ENV_FILE="deploy/local/.env"
HEALTH_URL="http://localhost:4000/health"
HEALTH_TIMEOUT=135   # seconds
HEALTH_INTERVAL=3    # seconds between polls
LOG_FILE="/tmp/verapos-install-$(date +%Y%m%d-%H%M%S).log"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[VeraPOS]${RESET} $*"; }
success() { echo -e "${GREEN}[VeraPOS]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[VeraPOS]${RESET} $*"; }
die()     { echo -e "${RED}[VeraPOS] ERROR:${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"
command -v curl &>/dev/null || die "curl is required. Install with: apt-get install -y curl"
command -v git  &>/dev/null || die "git is required. Install with: apt-get install -y git"

# Keep track of the real user (sudo caller) for group membership
REAL_USER="${SUDO_USER:-${USER}}"

# ── Step 1 — Docker ───────────────────────────────────────────────────────────
install_docker() {
  step "Docker"
  if command -v docker &>/dev/null; then
    info "Already installed: $(docker --version)"
    return
  fi
  info "Installing Docker via get.docker.com …"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  success "Docker installed."
}

# ── Step 2 — Docker group (no re-login needed) ────────────────────────────────
# Adds the real user to the docker group and builds a DOCKER_RUN wrapper that
# uses 'sg docker' so group membership is active in this session without
# requiring the user to log out. Falls back to 'sudo docker' if sg is missing.
DOCKER_RUN=""   # set by ensure_docker_group; used as: $DOCKER_RUN "docker ..."

ensure_docker_group() {
  step "Docker group"
  getent group docker &>/dev/null || groupadd docker

  if id -nG "$REAL_USER" | grep -qw docker; then
    info "$REAL_USER is already in the docker group."
  else
    usermod -aG docker "$REAL_USER"
    info "Added $REAL_USER to docker group (effective this session via sg)."
  fi

  # Choose runtime wrapper for this script session
  if command -v sg &>/dev/null; then
    DOCKER_RUN="sg docker -c"
  else
    DOCKER_RUN="sudo -u $REAL_USER"
  fi
}

# ── Step 3 — Docker Compose ───────────────────────────────────────────────────
COMPOSE=""   # set by find_compose_cmd

find_compose_cmd() {
  step "Docker Compose"

  # Prefer the plugin ('docker compose', ships with Engine 20.10+)
  if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
    info "Using Compose plugin: $(docker compose version --short 2>/dev/null || docker compose version)"
    return
  fi

  # Fallback 1: standalone docker-compose v1 (pre-installed on Ubuntu 20.04)
  if command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
    warn "Compose plugin not found — using standalone docker-compose v1"
    return
  fi

  # Fallback 2: try installing the plugin from apt
  if command -v apt-get &>/dev/null; then
    info "Installing docker-compose-plugin via apt …"
    apt-get install -y docker-compose-plugin &>/dev/null \
      && COMPOSE="docker compose" && return
  fi

  die "No Docker Compose implementation found. Install docker-compose-plugin manually and re-run."
}

# ── Step 4 — Repo ─────────────────────────────────────────────────────────────
setup_repo() {
  step "Repository"
  if [[ -d "${VERAPOS_DIR}/.git" ]]; then
    info "Repo already exists at ${VERAPOS_DIR} — pulling latest …"
    git -C "${VERAPOS_DIR}" pull --ff-only
  else
    info "Cloning into ${VERAPOS_DIR} …"
    git clone "${REPO_URL}" "${VERAPOS_DIR}"
  fi
  success "Repo ready."
}

# ── Step 5 — Environment file (never overwrites) ──────────────────────────────
setup_env() {
  step "Environment"
  local env_path="${VERAPOS_DIR}/${ENV_FILE}"

  if [[ -f "${env_path}" ]]; then
    info ".env already exists — keeping existing values."
    return
  fi

  info "Generating .env …"

  local pg_pass redis_pass jwt_secret
  pg_pass="$(openssl rand -hex 16)"
  redis_pass="$(openssl rand -hex 16)"
  # Random suffix appended so default is never guessable
  jwt_secret="verapos-$(openssl rand -hex 16)"

  mkdir -p "$(dirname "${env_path}")"
  cat > "${env_path}" <<EOF
# Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Edit this file to customise your store, then re-run install.sh to apply.

# ── Store identity ────────────────────────────────────────────────────────────
STORE_ID=${STORE_ID}

# ── Database ──────────────────────────────────────────────────────────────────
POSTGRES_USER=verapos_user
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=verapos

# ── Redis ─────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=${redis_pass}

# ── Backend ───────────────────────────────────────────────────────────────────
JWT_SECRET=${jwt_secret}
PORT=3000

# ── Cloud sync ────────────────────────────────────────────────────────────────
CLOUD_SYNC_ENABLED=true
CLOUD_SYNC_BASE_URL=https://api.verapos.co

# ── Platform service token ────────────────────────────────────────────────────
# Shared secret between this store and the cloud platform.
# Must match PLATFORM_SERVICE_TOKEN on api.verapos.co.
# Generate: openssl rand -hex 32
# PLATFORM_SERVICE_TOKEN=

# ── Automated backups (Backblaze B2) ─────────────────────────────────────────
BACKUP_ENABLED=false
# B2_KEY_ID=
# B2_APP_KEY=
# B2_BUCKET=
# B2_PREFIX=verapos-backup
EOF

  chmod 600 "${env_path}"
  success ".env created at ${env_path}"
  warn "ACTION REQUIRED: set PLATFORM_SERVICE_TOKEN in ${env_path} before going to production."
}

# ── Step 6 — Start / rebuild containers ───────────────────────────────────────
start_containers() {
  step "Containers"
  local dir="${VERAPOS_DIR}/deploy/local"

  # If containers from a previous install are running, rebuild cleanly
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q verapos; then
    info "Existing containers detected — rebuilding with --remove-orphans …"
    $DOCKER_RUN "$COMPOSE -f ${dir}/docker-compose.yml up -d --build --remove-orphans"
  else
    $DOCKER_RUN "$COMPOSE -f ${dir}/docker-compose.yml up -d --build"
  fi

  success "Containers started."
}

# ── Step 7 — Health check ─────────────────────────────────────────────────────
health_check() {
  step "Health check"
  info "Polling ${HEALTH_URL} every ${HEALTH_INTERVAL}s (timeout: ${HEALTH_TIMEOUT}s) …"

  local elapsed=0
  while [[ ${elapsed} -lt ${HEALTH_TIMEOUT} ]]; do
    if curl -sf "${HEALTH_URL}" &>/dev/null; then
      echo ""
      success "Backend is healthy."
      return
    fi
    printf '.'
    sleep "${HEALTH_INTERVAL}"
    elapsed=$(( elapsed + HEALTH_INTERVAL ))
  done

  echo ""
  warn "Health check timed out after ${HEALTH_TIMEOUT}s."
  warn "Inspect logs:"
  warn "  $DOCKER_RUN \"$COMPOSE -f ${VERAPOS_DIR}/${COMPOSE_FILE} logs backend --tail=50\""
  warn "Full install log: ${LOG_FILE}"
  exit 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Tee all output to log file for post-mortem debugging
  exec > >(tee -a "${LOG_FILE}") 2>&1

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  VeraPOS Store Installer${RESET}"
  echo -e "  STORE_ID : ${STORE_ID}"
  echo -e "  Directory: ${VERAPOS_DIR}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  install_docker
  ensure_docker_group
  find_compose_cmd
  setup_repo
  setup_env
  start_containers
  health_check

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")"

  echo ""
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
  echo -e "  API     : http://${ip}:4000"
  echo -e "  Config  : ${VERAPOS_DIR}/${ENV_FILE}"
  echo -e "  Logs    : $DOCKER_RUN \"$COMPOSE -f ${VERAPOS_DIR}/${COMPOSE_FILE} logs -f\""
  echo -e "  Install log: ${LOG_FILE}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  info "Next steps:"
  info "  1. Edit ${VERAPOS_DIR}/${ENV_FILE} — set PLATFORM_SERVICE_TOKEN"
  info "  2. Re-run this script to apply changes"
  info "  3. Register store backendUrl in platform.verapos.co"
  info "  4. Run 'newgrp docker' or re-login to use docker without sudo"
}

main "$@"
