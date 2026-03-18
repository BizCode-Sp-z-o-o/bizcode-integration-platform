# BizCode Integration Platform

Self-hosted integration platform for SAP Business One based on Node-RED.

> [!IMPORTANT]
> **This is an installer only, not open-source software.**
> The container images are proprietary and require a commercial license from BizCode.
> This repository contains only the deployment scripts (Docker Compose, installer, control script).
>
> **Interested?** Contact us at **info@bizcode.pl** to discuss licensing and pricing.
>
> [www.bizcode.pl](https://www.bizcode.pl)

## Quick Start

```bash
git clone https://github.com/BizCode-Sp-z-o-o/bizcode-integration-platform.git
cd bizcode-integration-platform
chmod +x install.sh ctl.sh
./install.sh
```

The installer will guide you through configuration and start all services.

## Architecture

| Service | Description | Dev Port |
|---------|-------------|----------|
| bip-00 to bip-09 | Node-RED instances | 1880-1889 |
| Redis | Cache and pub/sub | 6379 |
| RabbitMQ | Message queue | 5672 (mgmt: 15672) |
| PostgreSQL | Database | 5432 |
| CUPS | Print server | 631 |
| Nginx Proxy Manager | Reverse proxy (prod) | 80/443 (admin: 81) |

## Management

```bash
./ctl.sh start    # Start all services
./ctl.sh stop     # Stop all services
./ctl.sh status   # Show status
./ctl.sh logs     # View logs
./ctl.sh update   # Pull latest images and restart
./ctl.sh backup   # Backup all Node-RED data
```

## Deployment Modes

- **Dev** — direct port access (1880-1889), no SSL
- **Prod** — Nginx Proxy Manager with SSL and domain routing

## Requirements

- Docker Engine 24+
- Docker Compose v2
- ACR credentials (provided by BizCode)

## License

Proprietary — BizCode Sp. z o.o. All rights reserved.

This software is not open-source. Unauthorized use, copying, or distribution is prohibited.
Contact **info@bizcode.pl** for licensing.
