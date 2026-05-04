<div align="center">
  <h1>NovaPanel Installer</h1>
  <p><strong>The official installer for <a href="https://novapanel.dev">NovaPanel</a> — a self-hosted hosting control panel for solo developers, agencies, and resellers.</strong></p>
  <p>
    <a href="https://novapanel.dev"><img alt="Website" src="https://img.shields.io/badge/website-novapanel.dev-3b82f6?style=flat-square"></a>
    <a href="https://novapanel.dev/pricing"><img alt="Free tier" src="https://img.shields.io/badge/free%20tier-forever-10b981?style=flat-square"></a>
    <a href="https://discord.gg/Sx5wAYeZgg"><img alt="Discord" src="https://img.shields.io/badge/discord-join-5865f2?style=flat-square"></a>
    <a href="https://novapanel.dev/status"><img alt="Status" src="https://img.shields.io/badge/status-live-10b981?style=flat-square"></a>
  </p>
</div>

This repository contains the **public, MIT-licensed installer script** that sets up NovaPanel on a fresh Ubuntu server. The panel binary itself is closed-source and distributed via our license-gated CDN; the installer here downloads it, verifies its SHA-256 against a signed release manifest, and wires up the supporting stack (databases, reverse proxy, mail server, DNS).

The installer is open source so you can **audit exactly what runs on your server before piping it to bash**.

---

## Quick start

On a **fresh Ubuntu 22.04 or 24.04** server, as root:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash
```

That's it. The installer takes ~10 minutes on a 2-CPU / 4 GB VPS and auto-issues a free **Community license** bound to your server's machine fingerprint — no signup required.

After install, you can sign in:

- **Admin panel:** `https://<your-host>:2087` — manage users, sites, packages, license, mail, DNS
- **Customer panel:** `https://<your-host>:2083` — what your end-users see

> [!TIP]
> Your server needs a **public hostname pointing at it** before install — Caddy provisions Let's Encrypt certs at install time and needs DNS to resolve. Set up an A record like `panel.example.com → your-server-ip` first.

---

## Install variants

### With a Pro / Developer license key

If you've purchased a paid license, activate it from the start:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- \
  --key NOVA-xxxx-xxxx-xxxx-xxxx-xxxx
```

You can also upgrade from Community to Pro any time later via the admin panel's License page.

### Non-interactive / automated install

For CI or provisioning automation, skip the interactive prompts:

```bash
curl -fsSL https://novapanel.dev/install.sh | sudo bash -s -- \
  --yes \
  --hostname panel.example.com \
  --admin-email admin@example.com \
  --admin-password 'a-strong-password' \
  --key NOVA-xxxx-xxxx-xxxx-xxxx-xxxx
```

Or via environment variables:

```bash
NOVA_HOSTNAME=panel.example.com \
NOVA_ADMIN_EMAIL=admin@example.com \
NOVA_ADMIN_PASSWORD='a-strong-password' \
NOVA_LICENSE_KEY=NOVA-xxxx-xxxx-xxxx-xxxx-xxxx \
curl -fsSL https://novapanel.dev/install.sh | sudo -E bash
```

### Skip optional components

Flags to skip optional pieces if you don't need them:

| Flag | Effect |
|---|---|
| `--skip-mail` | Don't install Postfix / Dovecot / OpenDKIM / Roundcube |
| `--skip-dns` | Don't install PowerDNS |
| `--skip-ftp` | Don't install vsftpd |
| `--skip-clamav` | Don't install ClamAV virus scanner |
| `--skip-waf` | Don't build Caddy with the WAF module (faster install on small VPSes) |
| `--skip-firewall` | Don't configure UFW (use your provider's firewall instead) |

---

## What the installer does

1. **Detects + prepares the OS** — confirms Ubuntu 22.04/24.04, sets `NEEDRESTART_MODE=a` to avoid the Ubuntu 24.04 prompts that hang automated runs.
2. **Installs the database stack** — PostgreSQL 16 (panel's own DB), MariaDB (for customer MySQL databases), and Redis (sessions + cache).
3. **Installs the reverse proxy** — Caddy 2 with auto-TLS, optionally compiled with the Coraza WAF module via `xcaddy`.
4. **Installs PHP 8.3 + Composer** — for hosted customer sites.
5. **(Optional) installs the mail stack** — Postfix, Dovecot, OpenDKIM, OpenDMARC, Roundcube webmail.
6. **(Optional) installs DNS** — PowerDNS authoritative with optional DNSSEC keys generated on demand.
7. **(Optional) installs FTP and ClamAV.**
8. **Fetches your license** — auto-issues a free Community license bound to the server's fingerprint, or activates a Pro/Developer key if you provided one.
9. **Downloads the panel binary** — pulled from the license-gated R2 CDN, SHA-256 verified against the signed release manifest, installed to `/usr/local/bin/novapanel`.
10. **Configures systemd** — `novapanel.service` set up to start on boot.
11. **Applies database migrations** — embedded in the binary, run on first start.
12. **Provisions Let's Encrypt** — Caddy obtains certs for the panel hostname automatically.
13. **Sets up the firewall** — UFW rules for `22, 80, 443, 21, 25, 53, 110, 143, 465, 587, 993, 995, 2083, 2087`.
14. **Drops a MOTD** — friendly login banner showing the panel URL, version, license tier.

The whole run is **idempotent** — re-running on a server that already has NovaPanel is safe; it just upgrades the binary and re-applies any missing service config.

---

## System requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU | 2 cores | 4+ cores |
| RAM | 2 GB | 4+ GB (8 GB if running mail) |
| Disk | 30 GB | 50+ GB SSD |
| Network | Public IP, hostname pointing at it | + IPv6 |

> [!NOTE]
> **Port 25** is required for outbound mail. **Most VPS providers block it by default** to prevent spam abuse — Hetzner / OVH / Scaleway will lift the block on request, DigitalOcean / Vultr usually won't. If your provider blocks 25, configure an SMTP relay (Mailgun, SES, Postmark) in admin → Mail after install.

---

## Tiers

| | Community | Pro | Developer |
|---|---|---|---|
| Price | Free, forever | £4.99/mo or £49/yr | £9.99/mo or £99/yr |
| Sites | 5 | Unlimited | Unlimited |
| Databases | 5 | Unlimited | Unlimited |
| Customer accounts | 5 | Unlimited | Unlimited |
| Admin users (staff) | 1 | 3 | Unlimited |
| WAF | — | ✓ | ✓ |
| Virus scanner | — | ✓ | ✓ |
| S3 / Backblaze backups | — | ✓ | ✓ |
| Email accounts + relay | — | ✓ | ✓ |
| Git deploy | — | ✓ | ✓ |
| White-label branding | — | ✓ | ✓ |
| Priority email support | — | — | ✓ |
| Renewal model | Never expires | Subscription | Subscription |

See [novapanel.dev/pricing](https://novapanel.dev/pricing) for the current pricing and [/features](https://novapanel.dev/features) for what each item does in detail.

---

## Managing your subscription

Everything subscription-related happens in the **customer portal** at [license.novapanel.dev/portal](https://license.novapanel.dev/portal):

- Magic-link sign-in (no password)
- View your active licenses + machine fingerprints
- Manage subscription via Stripe / PayPal hosted billing portal
- Reset machine binding when you want to move servers
- Self-serve refund within 14 days
- Resend the welcome email if you've lost it

The portal link also lands in every welcome email — click it and you're signed in for 7 days with no further auth.

---

## Documentation

- 📖 [Full docs](https://novapanel.dev/docs) — install, license, upgrade, troubleshooting
- 🍳 [How-to guides](https://novapanel.dev/docs) — set up email, migrate WordPress, white-label, restore backups, configure DNS
- 📊 [Comparison vs cPanel](https://novapanel.dev/compare/cpanel)
- 📊 [Comparison vs Plesk](https://novapanel.dev/compare/plesk)
- 🗺️ [Roadmap](https://novapanel.dev/roadmap)
- 📝 [Changelog](https://novapanel.dev/changelog)

---

## Community + support

- 💬 [Discord](https://discord.gg/Sx5wAYeZgg) — fastest way to get help; release announcements land here too
- 📧 [support@novapanel.dev](mailto:support@novapanel.dev) — billing, technical issues, account questions
- 📧 [hello@novapanel.dev](mailto:hello@novapanel.dev) — general
- 🔒 [privacy@novapanel.dev](mailto:privacy@novapanel.dev) — data requests
- 🚨 [Live status](https://novapanel.dev/status)

---

## License

This installer script (`install.sh` and everything in this repository) is **open source under the [MIT License](LICENSE)**.

The NovaPanel panel binary itself is **closed-source** and distributed under our [End-User License Agreement](https://novapanel.dev/eula). Running the installer constitutes acceptance of the EULA — see its section 1 for the formal licence grant.

By using NovaPanel you also agree to:

- 📜 [Terms of Service](https://novapanel.dev/terms) — billing, refunds, suspension, liability
- 🔐 [Privacy Policy](https://novapanel.dev/privacy) — what data we collect, how we handle it (UK GDPR compliant)
- ⚖️ [End-User License Agreement (EULA)](https://novapanel.dev/eula) — what you can and can't do with the panel binary

The installer is open so you can verify what gets installed; the panel is closed-source so we can fund continued development.

---

<div align="center">
  <sub>Built by people who wanted a hosting panel that doesn't cost £600/year per server.</sub><br>
  <sub><a href="https://novapanel.dev">novapanel.dev</a> · <a href="https://discord.gg/Sx5wAYeZgg">Discord</a> · <a href="https://novapanel.dev/changelog">Changelog</a></sub>
</div>
