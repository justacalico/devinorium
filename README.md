# Devinorium

A self-hosted web UI for the [Devin CLI](https://devin.ai).

- Backend: Rust (axum + tokio + SQLite)
- Frontend: Flutter web, built with `./scripts/build-flutter.sh` and embedded from `frontend/dist/` at compile time

## What it is

Devinorium lets you use the Devin CLI from a browser. The Rust backend handles authentication, sessions, files, and Devin CLI calls.

## Quick start

Prerequisites: Rust, the `devin` CLI on PATH, authenticated with `devin login`, and the Flutter SDK.

```bash
git clone https://gitlab.com/HttpAnimations/devinorium.git
cd devinorium
cp .env.example .env
# Edit .env to set a real DEVINORIUM_BOOTSTRAP_PASSWORD.
# If it is unset or left as the placeholder, no owner account is created and you cannot log in.

./scripts/build-flutter.sh   # requires Flutter SDK; builds into frontend/dist/
cargo build --release          # embeds the freshly built frontend/dist/
./target/release/devinorium
```

Then open `http://localhost:7878` and log in with the bootstrap credentials.

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
| `DEVINORIUM_FILE_ROOT` | `$HOME` on Unix, `%USERPROFILE%` on Windows | Sandbox path for the file manager |
| `DEVINORIUM_DEVIN_BIN` | `devin` | Path to the `devin` CLI |
| `DEVINORIUM_DEFAULT_MODEL` | `glm-5-2` | Default model for new threads |
| `DEVINORIUM_TRUST_PROXY` | `false` | Trust `X-Forwarded-For` behind a reverse proxy |
| `DEVINORIUM_MAX_BODY_BYTES` | `16777216` | Max request body size in bytes |
| `DEVINORIUM_SECURE_COOKIE` | `false` | Set the `Secure` cookie flag (enable over HTTPS) |
| `DEVINORIUM_ALLOWED_ORIGIN` | (unset or empty) | Explicit allowed origin for CSRF checks |

Database migrations run automatically on startup.

## Testing

```bash
cargo test
```

## Deployment

Devinorium serves HTTP only. For remote or public access, put it behind a reverse proxy or tunnel that terminates TLS. See [docs/deployment.md](docs/deployment.md) for detailed examples.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
