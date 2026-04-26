# NovaPanel Installer

The official installer for [NovaPanel](https://novapanel.dev) — the modern hosting control panel.

## Install

On a fresh **Ubuntu 24.04** server, as root:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash
```

The installer auto-issues a free Community license bound to your server's
fingerprint. No signup required to get started.

### With a Pro license key

If you've purchased a Pro license, activate it from the start:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- --key NOVA-xxxx-xxxx-xxxx-xxxx-xxxx
```

You can also upgrade later from the panel's admin UI (Config → License).

### Non-interactive

For automated provisioning:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- --yes --email admin@example.com
```

## What it installs

- PostgreSQL 16 — panel's own database
- Redis — sessions + cache
- Caddy — TLS + reverse proxy + Let's Encrypt
- MariaDB — for customer MySQL databases
- PHP 8.3 + Composer — for customer PHP sites
- The NovaPanel binary itself (downloaded from the license-gated CDN,
  verified by SHA-256)
- A `novapanel.service` systemd unit
- UFW firewall rules (allow 22, 80, 443, 2083, 2087)

Optional services (mail, FTP, DNS, virus scanner) can be enabled from
the admin UI later.

## Requirements

- Ubuntu 24.04 or newer
- 2+ vCPU, 4+ GB RAM, 40+ GB disk recommended
- A public IP and a hostname pointing at it (for SSL)
- Root access

## Tiers

| | Community (free) | Pro | Developer |
|---|---|---|---|
| Sites | 5 | Unlimited | Unlimited |
| Databases | 5 | Unlimited | Unlimited |
| Customer accounts | 5 | Unlimited | Unlimited |
| WAF, virus scanner, S3 backups, git deploy, email, branding | — | ✓ | ✓ |
| Lifetime / no expiry | ✓ | Subscription | ✓ |

See [novapanel.dev/pricing](https://novapanel.dev/pricing) for current pricing.

## License

NovaPanel itself is commercial software. This installer script is open-source
(MIT) so you can audit exactly what runs on your server.
