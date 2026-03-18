#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# BizCode Integration Platform — Control Script
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load profiles
PROFILES=""
[ -f .profiles ] && PROFILES=$(cat .profiles)

# Detect mode
COMPOSE_CMD="docker compose"
if [ -f docker-compose.prod.yml ] && grep -q "prod" .env 2>/dev/null; then
    # Check if NPM is configured
    if docker compose -f docker-compose.yml -f docker-compose.prod.yml config --services 2>/dev/null | grep -q npm; then
        COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
    fi
fi

case "${1:-help}" in
    start)
        echo "Starting BizCode Integration Platform..."
        $COMPOSE_CMD $PROFILES up -d
        ;;
    stop)
        echo "Stopping BizCode Integration Platform..."
        $COMPOSE_CMD $PROFILES down
        ;;
    restart)
        echo "Restarting BizCode Integration Platform..."
        $COMPOSE_CMD $PROFILES down
        $COMPOSE_CMD $PROFILES up -d
        ;;
    status)
        $COMPOSE_CMD $PROFILES ps
        ;;
    logs)
        shift
        $COMPOSE_CMD $PROFILES logs -f "${@:---tail=50}"
        ;;
    update)
        echo "Pulling latest images..."
        source .env
        echo "$ACR_PASSWORD" | docker login bizcode.azurecr.io -u "$ACR_USERNAME" --password-stdin >/dev/null 2>&1
        $COMPOSE_CMD $PROFILES pull
        echo "Recreating containers..."
        $COMPOSE_CMD $PROFILES up -d --remove-orphans
        echo "Update complete."
        ;;
    backup)
        BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        echo "Backing up volumes to $BACKUP_DIR..."
        for i in $(seq 0 9); do
            idx=$(printf '%02d' $i)
            vol="bizcode-integration-platform_bip-${idx}-data"
            if docker volume inspect "$vol" >/dev/null 2>&1; then
                echo "  bip-${idx}..."
                docker run --rm -v "${vol}:/data" -v "$(pwd)/${BACKUP_DIR}:/backup" alpine tar czf "/backup/bip-${idx}.tar.gz" -C /data .
            fi
        done
        echo "Backup complete: $BACKUP_DIR"
        ;;
    help|*)
        echo "BizCode Integration Platform — Control Script"
        echo ""
        echo "Usage: ./ctl.sh <command>"
        echo ""
        echo "Commands:"
        echo "  start    Start all services"
        echo "  stop     Stop all services"
        echo "  restart  Restart all services"
        echo "  status   Show service status"
        echo "  logs     Show logs (optionally: ./ctl.sh logs bip-00)"
        echo "  update   Pull latest images and recreate containers"
        echo "  backup   Backup all Node-RED data volumes"
        ;;
esac
