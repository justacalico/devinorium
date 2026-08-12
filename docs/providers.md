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
    "devin-cli" => Ok(Box::new(devin_acp::DevinAcpProvider::new(...))),
    "my-provider" => Ok(Box::new(my_provider::MyProvider)),   // <- one line
    other => anyhow::bail!("unknown provider: {other}"),
}
```

- Append a `ProviderInfo { id: "my-provider", name: "My Provider" }` entry to `available_providers()`.

That is the entire surface area of the change. No other file in the project
needs to be touched — the rest of Devinorium only depends on the `Provider`
trait.

## Selecting a provider at runtime

Users can pick their default provider from **Settings**. The list is exposed
through the `GET /api/providers` endpoint and the active provider is stored on
the user record. Today only `devin-cli` is available, so the dropdown is a
single entry; as more providers are implemented the selection will be wired
directly into the request path.

Each user also sets the provider **command** (e.g. `devin` or `devin-cli`) in
Settings. The command is stored in `users.provider_command` and is passed to
`build_provider` along with `provider_id`. The **Test** button calls
`POST /api/providers/health`, which opens the ACP connection and sends
`InitializeRequest`, then immediately closes. It does not create a session or
run a prompt.
