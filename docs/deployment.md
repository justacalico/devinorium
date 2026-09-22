# Deploying Devinorium

Devinorium is a single self-contained binary. It serves HTTP only — for
public exposure, put it behind a reverse proxy or tunnel that terminates
TLS. This guide covers the common deployment patterns.

## Prerequisites

- A Rust toolchain (or a pre-built `devinorium` binary)
- The Flutter SDK, used to build the web frontend
- `git` — repositories are cloned and managed through the git CLI
- The agent provider CLIs you plan to use (e.g. `devin`), installed and
  authenticated; threads cannot run without one
- A directory for the SQLite database

## 1. Build

The frontend is a Flutter app in `flutter/` built to web. The backend embeds
the built assets from `frontend/dist/` at compile time via `include_dir!`, so
the binary is fully self-contained. Build the frontend **before** building the
backend:

```sh
# Build the Flutter web frontend (output goes to frontend/dist/)
./scripts/build-flutter.sh

# Build the backend, which embeds frontend/dist/ at compile time
cargo build --release
# Binary is at target/release/devinorium
```

## 2. Configure

Copy `.env.example` to `.env` and edit:

```sh
cp .env.example .env
```

**Critical settings:**

| Variable | Notes |
|---|---|
| `DEVINORIUM_SESSION_KEY` | Generate with `openssl rand -base64 48`. Must be ≥32 chars. |
| `DEVINORIUM_BOOTSTRAP_PASSWORD` | A strong password for the first owner account. |
| `DEVINORIUM_SECURE_COOKIE` | Set `true` when serving over HTTPS. |
| `DEVINORIUM_TRUST_PROXY` | Set `true` when behind a reverse proxy (so client IPs are read from `X-Forwarded-For`). |

## 3. Run

```sh
./target/release/devinorium
```

On first run, the bootstrap owner account is created from
`DEVINORIUM_BOOTSTRAP_USERNAME` / `DEVINORIUM_BOOTSTRAP_PASSWORD`.

## 4. Expose securely

### Option A: Reverse proxy (nginx + Let's Encrypt)

Devinorium listens on `127.0.0.1:7878`. Put nginx in front for TLS.

```nginx
server {
    listen 443 ssl http2;
    server_name devinorium.example;

    ssl_certificate     /etc/letsencrypt/live/devinorium.example/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/devinorium.example/privkey.pem;

    # Devinorium handles its own security headers; we just proxy.
    location / {
        proxy_pass http://127.0.0.1:7878;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support — required by the terminal view and by
        # federation node links.
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Allow large file uploads
        client_max_body_size 20m;
    }
}

# Redirect HTTP -> HTTPS
server {
    listen 80;
    server_name devinorium.example;
    return 301 https://$host$request_uri;
}
```

Then in `.env`:
```
DEVINORIUM_TRUST_PROXY=true
DEVINORIUM_SECURE_COOKIE=true
DEVINORIUM_ALLOWED_ORIGIN=https://devinorium.example
```

Get a certificate with certbot:
```sh
sudo certbot certonly --nginx -d devinorium.example
```

### Option B: Cloudflare Tunnel (no open ports)

Cloudflare Tunnel connects your local Devinorium to Cloudflare's edge
without opening any inbound ports on your router/firewall.

```sh
# Install cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Authenticate (one-time)
cloudflared tunnel login

# Create a tunnel
cloudflared tunnel create devinorium

# Route DNS
cloudflared tunnel route dns devinorium devinorium.example

# Run the tunnel pointing at Devinorium
cloudflared tunnel run --url http://127.0.0.1:7878 devinorium
```

Then in `.env`:
```
DEVINORIUM_TRUST_PROXY=true
DEVINORIUM_SECURE_COOKIE=true
DEVINORIUM_ALLOWED_ORIGIN=https://devinorium.example
```

**Why this is safe:** No inbound ports are opened on your machine.
Cloudflare terminates TLS at the edge and authenticates the tunnel via a
per-tunnel credential file. You can add Cloudflare Access policies for
an additional authentication layer in front of Devinorium's own login.

### Option C: Port forwarding (NOT recommended for production)

If you must forward a port directly from your router:

1. Forward port 443 (or your chosen port) to `127.0.0.1:7878`.
2. **You still need TLS.** Use a reverse proxy (Option A) in front of
   Devinorium even with port forwarding — never expose the HTTP port
   directly to the internet, because:
   - Session cookies would be sent in cleartext.
   - The `Secure` cookie flag cannot be set over HTTP.
   - Login credentials would be sniffable.

**Port-forward safety checklist:**
- [ ] TLS is terminated by a reverse proxy, not Devinorium directly.
- [ ] `DEVINORIUM_SECURE_COOKIE=true`
- [ ] `DEVINORIUM_TRUST_PROXY=true` (so the proxy's `X-Forwarded-For` is trusted)
- [ ] `DEVINORIUM_ALLOWED_ORIGIN` is set to your public HTTPS URL.
- [ ] Your router forwards only 443 → the reverse proxy, not 7878 → Devinorium.
- [ ] The firewall on the host blocks direct access to port 7878 from the LAN/WAN.
- [ ] `DEVINORIUM_SESSION_KEY` is a fresh random value (not the example).
- [ ] `DEVINORIUM_BOOTSTRAP_PASSWORD` is strong and changed after first login.
- [ ] Only the owner account can create and manage other user accounts.

### Option D: Tailscale (private tailnet access)

When every device that needs access is on the same
[Tailscale](https://tailscale.com) tailnet, Devinorium can publish itself as
`https://<machine>.<tailnet>.ts.net` via `tailscale serve`. Tailscale
provisions the certificate and WireGuard encrypts the traffic, so no reverse
proxy, open inbound port, or public DNS record is needed.

Requirements:

- `tailscaled` running on the server host with the node logged in
  (`tailscale up`).
- MagicDNS enabled on the tailnet (Tailscale admin console → DNS).
- The `tailscale` CLI on `PATH`.

Enable it at runtime via Settings → Servers → Tailscale → "Tailscale HTTPS"
(owner only). The tailnet-side HTTPS port can be changed in the port field
next to the toggle (default 443). The card also lists the tailnet IP and
MagicDNS HTTP endpoints that other devices on the tailnet can use to reach
the server.

The setting is stored in the server database: an enabled mapping is
re-applied on startup, and it is removed again on graceful shutdown.
Disabling the toggle removes every serve mapping that points at this server
without touching mappings other services own, and the server refuses to
enable serve on a port already mapped by something else.

Notes:

- Both the server and the connecting device must be on the same tailnet.
- The HTTPS endpoint works with the default `DEVINORIUM_HOST=127.0.0.1`
  loopback bind: `tailscale serve` proxies to localhost. The plain HTTP
  tailnet-IP endpoints only answer when the bind covers the tailnet
  interface (`0.0.0.0` or the `100.x` address).
- Because browsers see a real HTTPS URL, `DEVINORIUM_SECURE_COOKIE=true` is
  compatible with tailscale-serve access and recommended when you do not
  also log in over plain LAN HTTP.
- The bundled desktop server cannot use Tailscale; its loopback-only server
  must not be republished, and the settings card is greyed out there.

## 5. Deploy with Docker

The repo ships a multi-stage `Dockerfile` that builds the Flutter web
bundle, compiles the server with the assets embedded, and produces a slim
runtime image:

```sh
docker build -t devinorium .
```

Run it with a named volume for the SQLite database:

```sh
docker run -d --name devinorium \
  -p 127.0.0.1:7878:7878 \
  -v devinorium-data:/home/devinorium/data \
  -e DEVINORIUM_SESSION_KEY=$(openssl rand -base64 48) \
  -e DEVINORIUM_BOOTSTRAP_PASSWORD=<a strong password> \
  devinorium
```

Or use the bundled `docker-compose.yml`:

```sh
export DEVINORIUM_SESSION_KEY=$(openssl rand -base64 48)
export DEVINORIUM_BOOTSTRAP_PASSWORD=<a strong password>
docker compose up -d
```

Notes:

- The image exposes plain HTTP on 7878. For anything beyond localhost,
  terminate TLS in front of it (see §4) and set
  `DEVINORIUM_TRUST_PROXY`/`DEVINORIUM_SECURE_COOKIE` accordingly.
- The database lives at `/home/devinorium/data/devinorium.db` inside the
  volume. Project, worktree, and clone roots default to the container's
  home directory, which is *not* in the volume — set the project root
  under `/home/devinorium/data` (Settings → Servers) or widen the volume
  to `/home/devinorium` if projects must survive container recreation.
- Agent provider CLIs (e.g. `devin`) are not part of the image. Threads
  that need a provider CLI require it to be installed into the image or
  mounted, and any credentials the CLI needs (config directories, SSH
  keys) must be mounted as well.
- Release pipelines build and push the image to the project's GitLab
  container registry as `devinorium:<tag>` and `devinorium:latest`.

## 6. Run as a systemd service

Create the service user, install the binary, and write the unit:

```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin devinorium
sudo install -d -m 750 -o devinorium -g devinorium /etc/devinorium
sudo install -m 600 -o devinorium -g devinorium .env /etc/devinorium/devinorium.env
sudo install -m 755 target/release/devinorium /usr/bin/devinorium
```

```ini
# /etc/systemd/system/devinorium.service
[Unit]
Description=Devinorium
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=devinorium
Group=devinorium
StateDirectory=devinorium devinorium/data
WorkingDirectory=/var/lib/devinorium
EnvironmentFile=-/etc/devinorium/devinorium.env
ExecStart=/usr/bin/devinorium
Restart=on-failure
RestartSec=5

# Hardening — deliberately limited: agents must be able to clone
# repositories and edit files outside /var/lib/devinorium, so no
# ProtectHome or ReadWritePaths restriction.
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now devinorium
```

## 7. Post-deployment

- **Create accounts** for other users via the user menu → Accounts (owner only).
  Non-owner accounts are a trust reduction, not full isolation: they are
  confined to the managed project/worktree/clone roots and the project
  scopes you give them, but those managed roots are *shared* — every
  non-owner can read, write, and delete inside them. Create non-owner
  accounts only for people you would trust with every project's files;
  there is no per-user file isolation today.
- **Enable TOTP** (2FA) on your account via the user menu → Enable 2FA.
- **Backups:** the SQLite database (`data/devinorium.db`) is the
  only state you need to back up. Project paths can live anywhere
  on the filesystem, so back those up separately if desired. Stop
  the service before copying the db file, or use `sqlite3 ... ".backup"`.
- **Health checks:** `GET /healthz` returns `{"status": "ok"}` and needs no
  credentials — point uptime monitors, load balancer probes, or a Docker
  `HEALTHCHECK` at it.
- **Updates:** self-hosted servers can update in-app via Settings →
  Servers → Server update (downloads the release asset for your platform,
  verifies its SHA-256, swaps the binary, and restarts). For source builds,
  pull the latest main, rebuild the frontend with
  `./scripts/build-flutter.sh`, then `cargo build --release`, and restart
  the service. Migrations run automatically on startup.
