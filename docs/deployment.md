# Deploying Devinorium

Devinorium is a single self-contained binary. It serves HTTP only — for
public exposure, put it behind a reverse proxy or tunnel that terminates
TLS. This guide covers the common deployment patterns.

## Prerequisites

- A Rust toolchain (or a pre-built `devinorium` binary)
- The `dioxus` CLI (`dx`), used to build the frontend to WASM:
  ```sh
  cargo binstall dioxus-cli --version 0.6.3
  ```
- The `devin` CLI installed and authenticated (`devin login`)
- A directory for the SQLite database and file root

## 1. Build

The frontend is a Rust crate in `frontend/` built with Dioxus 0.6 to
WebAssembly. The backend embeds the built assets from `frontend/dist/` at
compile time via `include_dir!`, so the binary is fully self-contained.
Build the frontend **before** building the backend:

```sh
# Build the Dioxus WASM frontend (output goes to frontend/dist/)
./scripts/build-frontend.sh

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
| `DEVINORIUM_SESSION_KEY` | Generate with `openssl rand -base64 48`. Must be ≥64 chars. |
| `DEVINORIUM_BOOTSTRAP_PASSWORD` | A strong password for the first owner account. |
| `DEVINORIUM_FILE_ROOT` | A single absolute path. The file manager and Devin sessions are sandboxed to this. |
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

        # WebSocket support (for future streaming features)
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
- [ ] Only trusted users have invite tokens.

## 5. Run as a systemd service

```ini
# /etc/systemd/system/devinorium.service
[Unit]
Description=Devinorium
After=network.target

[Service]
Type=simple
User=devinorium
WorkingDirectory=/opt/devinorium
EnvironmentFile=/opt/devinorium/.env
ExecStart=/opt/devinorium/devinorium
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/devinorium/data /opt/devinorium/fileroot
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now devinorium
```

## 6. Post-deployment

- **Create invite tokens** for other users via the user menu → Invites.
- **Enable TOTP** (2FA) on your account via the user menu → Enable 2FA.
- **Backups:** the SQLite database (`data/devinorium.db`) and the
  file root directory are all you need to back up. Stop the service
  before copying the db file, or use `sqlite3 ... ".backup"`.
- **Updates:** pull the latest main, rebuild the frontend with
  `./scripts/build-frontend.sh`, then `cargo build --release`, and restart
  the service. Migrations run automatically on startup.
