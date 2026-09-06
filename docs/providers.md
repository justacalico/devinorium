# Adding a new AI provider

Devinorium talks to agent backends through a single trait defined in
`src/providers/mod.rs`:

```rust
#[async_trait]
pub trait Provider: Send + Sync {
    fn id(&self) -> &str;
    fn name(&self) -> &str;
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>>;
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse>;
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse>;
    async fn export(&self, session_id: &str, working_dir: &Path) -> anyhow::Result<serde_json::Value>;
    async fn health_check(&self) -> anyhow::Result<()>;
    // Optional: report installed/latest versions for the Settings card.
    // The default implementation reports nothing.
    async fn version_info(&self) -> ProviderVersion { ProviderVersion::default() }
}
```

## Adding a provider is exactly two changes

### 1. Create one new file

`src/providers/my_provider.rs`:

```rust
use async_trait::async_trait;
use super::*;

pub struct MyProvider;

#[async_trait]
impl Provider for MyProvider {
    fn id(&self) -> &str { "my-provider" }
    fn name(&self) -> &str { "My Provider" }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> { /* ... */ }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> { /* ... */ }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> { /* ... */ }
    async fn export(&self, _: &str, _: &Path) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
    async fn health_check(&self) -> anyhow::Result<()> { /* ... */ }
}
```

### 2. Edit one line in the registry

In `src/providers/mod.rs`:

- Add `pub mod my_provider;` at the top.
- Add one match arm in `build_provider`:

```rust
match cfg.id.as_str() {
    "devin-cli" => Ok(Box::new(acp::AcpProvider::new(AgentKind::Devin, cfg))),
    "opencode" => Ok(Box::new(acp::AcpProvider::new(AgentKind::Opencode, cfg))),
    "my-provider" => Ok(Box::new(my_provider::MyProvider)),   // <- one line
    other => anyhow::bail!("unknown provider: {other}"),
}
```

- Append a `ProviderInfo { id: "my-provider", name: "My Provider" }` entry to `available_providers()`.

That is the entire surface area of the change. No other file in the project
needs to be touched — the rest of Devinorium only depends on the `Provider`
trait.

## Selecting a provider at runtime

Users can pick their default provider from **Settings**, and each thread can
pick its own provider from the composer dropdown. The list is exposed through
the `GET /api/providers` endpoint, the user's default is stored on the user
record, and a thread's provider is stored in `threads.provider_id`. Once a
thread has started a provider session the provider is locked, because the
stored session id only means something to the provider that created it.

`GET /api/models?provider=<id>` returns the model catalog for a specific
provider. When the provider is omitted the user's default provider is used.

Each user also sets the provider **command** (e.g. `devin` or `opencode`) in
Settings. `users.provider_command` holds the command for the default provider
and `users.provider_commands` is a JSON map of per-provider overrides; the
effective command is resolved by `UserRow::command_for_provider`, falling back
to `providers::default_command` when no override exists. The **Test** button
calls `POST /api/providers/health`, which opens the ACP connection and sends
`InitializeRequest`, then immediately closes. It does not create a session or
run a prompt.

The Settings card also shows the provider's installed and latest versions via
`GET /api/providers/version`, which calls the optional `Provider::version_info`
(default: reports nothing). `devin-cli` implements it by running
`<command> --version` for the installed version and reading the published
release manifest for the latest.
