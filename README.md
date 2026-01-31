# UniFi Controller Stack (Template)

This folder is a **template** for running the UniFi Network Application with an external MongoDB in Docker.

## Directory layout

- `docker-compose.yml`
- `.env.example` (installer generates `.env`)
- `scripts/first-run-mongo.sh` (Mongo init script; runs only on a fresh DB)
- `scripts/backup.sh`, `scripts/restore.sh`
- `scripts/unifi-cert-deploy.sh` (optional; for Let's Encrypt -> UniFi keystore import)
- `backups/` (backup outputs)
- `mongo-data/` (Mongo persistent data)
- `unifi-data/` (UniFi persistent data)

## Install (2-step, interactive)

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/stratacorps/unifi-controller-stack/main/install.sh
bash install.sh
```

Why not one-liner `curl | bash`? Interactive prompts can hang or misbehave when stdin is a pipe.
This installer reads from `/dev/tty` to be reliable.

## Notes

### Mongo user permissions
UniFi uses three DBs by default:
- `unifi`
- `unifi_stat`
- `unifi_audit`

The init script grants `dbOwner` on all three.

### First boot
Mongo initialization only runs when `mongo-data/` is empty.
If you change credentials later, you must wipe `mongo-data/` (destructive) or update Mongo users manually.

### Let's Encrypt / DNS-01 (Cloudflare)
If you can't use 80/443, use DNS-01 validation.
After you obtain certs on the host under `/etc/letsencrypt/live/<DOMAIN>/`,
run:

```bash
sudo DOMAIN=<DOMAIN> ./scripts/unifi-cert-deploy.sh
```

That will build a PKCS12 bundle and import it into UniFi's keystore.

## Backup & restore

Backup:
```bash
./scripts/backup.sh
```

Restore (staging):
```bash
RESTORE_MODE=staging ./scripts/restore.sh ./backups/<file>.tar.gz
```

Restore (in place):
```bash
RESTORE_MODE=inplace ./scripts/restore.sh ./backups/<file>.tar.gz
```
