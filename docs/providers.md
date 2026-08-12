# Adding a new AI provider

Devinorium talks to AI backends through a single trait defined in
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

- Append `"my-provider"` to `available_providers()`.

That is the entire surface area of the change. No other file in the project
needs to be touched — the rest of Devinorium only depends on the `Provider`
trait.

## Selecting a provider at runtime

Set `DEVINORIUM_PROVIDER` (planned) in the environment. Today only
`devin-cli` is implemented.
