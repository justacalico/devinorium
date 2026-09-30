# Devinorium

A self-hosted web UI for AI coding agents.

- Backend: Rust
- Frontend: Flutter web

<p align="center">
  <img src="docs/images/running.png" width="100%" alt="Devinorium running" />
</p>

<p align="center">
  <img src="docs/images/mobile-3.png" width="30%" alt="Devinorium sidebar on mobile" />
  <img src="docs/images/mobile-2.png" width="30%" alt="Devinorium thread view on mobile" />
  <img src="docs/images/mobile-1.png" width="30%" alt="Devinorium code editor on mobile" />
</p>

## What it is

Devinorium lets you use coding agents from a browser. The Rust backend handles authentication, sessions, files, and provider calls; the provider layer is pluggable, so new backends can be added without touching the rest of the app.

## Supported providers

- [Devin CLI](https://devin.ai)
- [OpenCode](https://opencode.ai)
- [Codex CLI](https://github.com/openai/codex)
- [Grok Code](https://grok.com)

## Quick start

Prerequisites: Rust, the CLI for your chosen provider on PATH, and the Flutter SDK.
For the Devin provider, authenticate with `devin login`; for OpenCode, authenticate with `opencode auth login`; for Codex, authenticate with `codex login`; for Grok Code, authenticate with `grok login`.

```bash
git clone https://gitlab.com/HttpAnimations/devinorium.git
cd devinorium
cp .env.example .env
# Edit .env to set a real DEVINORIUM_BOOTSTRAP_PASSWORD.
# If it is unset or left as the placeholder, no owner account is created and you cannot log in.

./scripts/build-flutter.sh   # requires Flutter SDK; builds into frontend/dist/
cargo build --release          # embeds the freshly built frontend/dist/
mkdir -p data                # creates a place to store the database
./target/release/devinorium
```

Then open `http://localhost:7878` and log in with the bootstrap credentials.

For a throwaway instance that skips login entirely, run the backend with
`--dev` (or `-dev`): it binds a random free port on all interfaces, serves
every request as the passwordless `local` owner account, and keeps the
database in memory so nothing persists once the process exits. The URL it
bound is printed on startup. Anyone who can reach the port gets full owner
access, including other machines on the network, which is the point: it
exists to test the UI from a device other than the one running the
backend. Pass `--local` (or `-local`) to bind loopback only.

```bash
cargo run -- --dev          # reachable from other machines on the network
cargo run -- --dev --local  # loopback only
cargo run -- --local        # same thing
```

## Configuration

All configuration is via environment variables. See `.env.example` for the full list.

| Variable | Default | Purpose |
|---|---|---|
| `DEVINORIUM_HOST` | `127.0.0.1` | Bind address |
| `DEVINORIUM_PORT` | `7878` | Listen port |
| `DEVINORIUM_SESSION_KEY` | (ephemeral) | Secret for signing session cookies; set a long random value for persistence |
| `DEVINORIUM_DB_URL` | `sqlite:data/devinorium.db?mode=rwc` | SQLite connection string |
| `DEVINORIUM_BOOTSTRAP_USERNAME` | `owner` | First-run owner username |
| `DEVINORIUM_BOOTSTRAP_PASSWORD` | (none) | First-run owner password; if unset, no owner is created |
| `DEVINORIUM_DEFAULT_MODEL` | `glm-5-2` | Default model for new threads |
| `DEVINORIUM_TRUST_PROXY` | `false` | Trust `X-Forwarded-For` behind a reverse proxy |
| `DEVINORIUM_MAX_BODY_BYTES` | `16777216` | Max request body size in bytes |
| `DEVINORIUM_SECURE_COOKIE` | `false` | Set the `Secure` cookie flag (enable over HTTPS) |
| `DEVINORIUM_ALLOWED_ORIGIN` | (unset or empty) | Explicit allowed origin for CSRF checks |
| `DEVINORIUM_PUSH_CONTACT` | `mailto:devinorium@localhost` | Contact URI in VAPID JWTs for Web Push. Set a real `mailto:` or `https:` address; some push providers reject sends without one |
| `DEVINORIUM_LOCAL_TOKEN` | (unset) | Bundled desktop mode: requests bearing this token map onto the passwordless `local` owner account, and the process exits when stdin closes. Set automatically by the desktop app; not for normal servers |
| `DEVINORIUM_FEDERATION_TOKEN` | (unset) | Shared fleet secret. On a hub it gates satellite registration and is sent as the bearer token on proxied calls; on a satellite it authenticates the hub. Required on both sides |
| `DEVINORIUM_HUB_URL` | (unset) | Set on a satellite to register with a hub, e.g. `https://hub.example`. Re-registers every 30 s as the heartbeat |
| `DEVINORIUM_NODE_NAME` | hostname | Display name a satellite advertises to the hub |
| `DEVINORIUM_NODE_URL` | bound address | Base URL the hub dials to reach a satellite; set when behind NAT or a tunnel |

Federation lets one public hub reach many private machines: satellites
register with the hub and the owner picks a node in the sidebar. See
[docs/federation.md](docs/federation.md).

Tailscale serve is configured from the UI instead of env vars: Settings →
Servers → Tailscale (owner only). See `docs/deployment.md` Option D.

Database migrations run automatically on startup.

## Desktop apps (Linux, macOS, Windows)

Desktop builds bundle the `devinorium` server binary inside the app package
(`server/` next to the app executable). On launch the app spawns it on a
random loopback port with a fresh `DEVINORIUM_LOCAL_TOKEN`, so no login is
needed and other user accounts on the machine cannot use the API. The server
exits automatically when the app closes.

Remote servers still work: use "Add server" in Settings → Servers to connect
to a Devinorium instance running on another machine, and switch between it
and the bundled "This device" server from the sidebar. Tailscale remote
access is unavailable on the bundled server (it binds to loopback only), so
the Tailscale card in Settings → Servers is greyed out there.

For development, the bundled server is only found inside packaged builds. To
run it under `flutter run`, point the app at a binary you built yourself:

```bash
cargo build --release
flutter run --dart-define=DEVINORIUM_SERVER_BINARY="$PWD/target/release/devinorium"
```

## Notifications

Notifications cover every thread, not just the open one: run completion,
failure, stops, permission prompts, and agent questions all surface through
the global run-events stream. Enable them under Settings → Personalization.

- **Foreground/backgrounded app**: local notifications via the OS
  (`flutter_local_notifications` on Android and iOS, `notify-send` /
  `osascript` / PowerShell on desktop, the Notifications API on web). On
  Android 13+ the app requests `POST_NOTIFICATIONS` at runtime.

Set `DEVINORIUM_PUSH_CONTACT` to a real contact URI for reliable delivery.

## Testing

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

## Deployment

Devinorium serves HTTP only. For remote or public access, put it behind a reverse proxy or tunnel that terminates TLS. See [docs/deployment.md](docs/deployment.md) for detailed examples.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
