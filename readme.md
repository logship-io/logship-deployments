# Logship Deployment Examples

This repository contains a set of examples for logship deployments onto different platforms.

## Quick start

### Native single-host install

Install the Logship database, frontend, and agent together on a Linux host with systemd:

```sh
curl -fsSL https://raw.githubusercontent.com/logship-io/logship-deployments/main/src/shell/install.sh | sh
```

Useful flags:

- `--path /custom/path`
- `--data-root /custom/data`
- `--hostname example.com`
- `--database-port 5000`
- `--frontend-port 8000`
- `--overwrite`
- `--no-install`

The installer lives at `src/shell/install.sh`.

### Docker Compose single-node

```sh
git clone https://github.com/logship-io/logship-deployments.git
cd logship-deployments/src/compose/single-node
docker compose pull
docker compose up -d
```
