# Technical Specification: Tanzu AI Services Provider for Goose

**Author:** Nick Kuhn  
**Date:** February 2026  
**Status:** Draft / Proposal  
**Target Repository:** [block/goose](https://github.com/block/goose)  
**License:** Apache License 2.0 (consistent with Goose project)

---

## 1. Overview

### 1.1 Problem Statement

[Goose](https://block.github.io/goose/) is an open-source AI agent framework by Block that supports 20+ LLM providers. [AI Services for VMware Tanzu Platform](https://techdocs.broadcom.com/us/en/vmware-tanzu/platform/ai-services/10-3/ai/index.html) provides enterprise-managed LLM access through Cloud Foundry service bindings, exposing an OpenAI-compatible API behind a GenAI proxy with JWT-based authentication. There is currently no native Goose provider for Tanzu AI Services.

Enterprise developers deploying applications on Tanzu Platform need the ability to point Goose at their platform-provisioned AI models—whether that's a single-model binding (e.g., a dedicated chat model) or a multi-model binding (e.g., a plan that bundles chat, tools, and embedding models together). Today, the only workaround is to manually configure the OpenAI-compatible ("OpenAI-like") custom provider, which requires the user to know the correct base URL construction, pass the JWT API key, and cannot leverage the rich metadata (model capabilities, model discovery via config URL, wire format) that Tanzu AI Services exposes.

### 1.2 Proposed Solution

Implement a first-class `TanzuAIServicesProvider` in Goose's Rust provider system that:

1. Accepts credentials in **both** the single-model and multi-model binding formats from Tanzu AI Services.
2. Automatically constructs the OpenAI-compatible API base URL from the binding credentials.
3. Uses the `config_url` endpoint for dynamic model discovery (listing available models and their capabilities).
4. Supports Bearer token authentication using the JWT `api_key` from the binding.
5. Allows environment variable or `VCAP_SERVICES`-based configuration for Cloud Foundry-deployed use cases.
6. Integrates into Goose's provider registry, CLI configuration flow, and Desktop UI.

### 1.3 Value Proposition

- **Zero-config for CF apps**: Applications deployed on Tanzu Platform can auto-detect credentials from `VCAP_SERVICES`.
- **Dynamic model discovery**: Multi-model bindings expose multiple models; the provider can enumerate them and let users select.
- **Enterprise-ready**: Tanzu AI Services provides rate limiting, RBAC, audit logging, and governance—this provider brings those benefits to Goose users.
- **OSS contribution**: Adds Tanzu Platform to Goose's growing list of supported enterprise providers alongside Databricks, Azure OpenAI, AWS Bedrock, and GCP Vertex AI.

---

## 2. Background

### 2.1 Goose Provider Architecture

Goose providers implement the `Provider` trait defined in `crates/goose/src/providers/base.rs`. Key elements:

- **`Provider` trait**: Defines async methods for `complete()`, `complete_stream()`, `complete_fast()`, and `generate_session_name()`. All return `Result<(Message, ProviderUsage), ProviderError>`.
- **`ProviderMetadata`**: Static metadata including name, description, required configuration keys, default model, and supported model list.
- **`ProviderRegistry`**: A global registry at `crates/goose/src/providers/factory.rs` that catalogs providers with constructors. Providers are registered in `init_registry()`.
- **`ApiClient`**: A shared HTTP client abstraction at `crates/goose/src/providers/utils.rs` that handles request execution, retry logic, and error classification.
- **`ModelConfig`**: Model-specific settings including context limits and temperature.
- **Format Adapters**: Providers use format adapters (e.g., `openai_format`) to convert between Goose's internal `Message` type and provider-specific API payloads.

Providers are classified into four types: `Preferred`, `Builtin`, `Declarative`, and `Custom`. The Tanzu provider would be registered as `Builtin`.

### 2.2 Tanzu AI Services Binding Credentials

Tanzu AI Services exposes credentials through the `VCAP_SERVICES` environment variable (for CF-bound apps) or via `cf service-key` (for external consumers). There are two credential formats:

#### Single-Model Format (Deprecated but still supported)

```json
{
  "api_base": "https://genai-proxy.sys.example.com/<GUID>/openai",
  "api_key": "eyJhbGciOiJIUzI1NiJ9...",
  "endpoint": {
    "api_base": "https://genai-proxy.sys.example.com/<GUID>",
    "api_key": "eyJhbGciOiJIUzI1NiJ9...",
    "config_url": "https://genai-proxy.sys.example.com/<GUID>/config/v1/endpoint",
    "name": "<GUID>"
  },
  "model_aliases": null,
  "model_capabilities": ["chat", "tools"],
  "model_name": "openai/gpt-oss-120b",
  "wire_format": "openai"
}
```

Key characteristics:
- Top-level `api_base` already includes `/openai` suffix — ready for direct OpenAI API calls.
- `model_name` identifies the single model available.
- `model_capabilities` enumerates what the model supports (chat, tools, embedding).
- `wire_format` is always `openai` (currently the only supported format).
- The nested `endpoint` block provides the config URL for richer discovery.

#### Multi-Model Format (Recommended)

```json
{
  "endpoint": {
    "api_base": "https://genai-proxy.sys.example.com/<PLAN-NAME>",
    "api_key": "eyJhbGciOiJIUzI1NiJ9...",
    "config_url": "https://genai-proxy.sys.example.com/<PLAN-NAME>/config/v1/endpoint",
    "name": "<PLAN-NAME>"
  }
}
```

Key characteristics:
- Only the `endpoint` block is present—no top-level `model_name` or `api_base`.
- The OpenAI API URL is formed by appending `/openai` to `endpoint.api_base`.
- Model discovery happens dynamically via `endpoint.config_url` or the OpenAI `/models` endpoint.
- Multiple models are available through a single binding.

### 2.3 API Interaction Pattern

All inference requests use the standard OpenAI chat completions format:

```
POST {endpoint.api_base}/openai/v1/chat/completions
Authorization: Bearer {api_key}
Content-Type: application/json

{
  "model": "llama3.2:1b",
  "messages": [...],
  "tools": [...],
  "stream": true
}
```

Model listing:
```
GET {endpoint.api_base}/openai/v1/models
Authorization: Bearer {api_key}
```

Config discovery (richer metadata including capabilities):
```
GET {endpoint.config_url}
Authorization: Bearer {api_key}
```

---

## 3. Detailed Design

### 3.1 File Structure

```
crates/goose/src/providers/
├── tanzu.rs           # New: TanzuAIServicesProvider implementation
├── base.rs            # Provider trait (existing)
├── factory.rs         # Registry (modify to register Tanzu provider)
├── openai.rs          # OpenAI provider (reference implementation)
├── utils.rs           # ApiClient utilities (existing)
└── mod.rs             # Module declaration (add tanzu)

documentation/docs/getting-started/
└── providers.md       # Update with Tanzu provider documentation

crates/goose/tests/
└── tanzu_provider.rs  # Integration tests
```

### 3.2 Configuration Keys

The provider will use the following configuration keys, registered in `ProviderMetadata`:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `TANZU_AI_API_KEY` | Secret | Yes | JWT Bearer token from the binding's `api_key` field |
| `TANZU_AI_ENDPOINT` | Param | Yes | The `endpoint.api_base` URL (e.g., `https://genai-proxy.sys.example.com/plan-name`) |
| `TANZU_AI_CONFIG_URL` | Param | No | The `endpoint.config_url` for rich model discovery. Auto-derived if not set. |
| `TANZU_AI_MODEL_NAME` | Param | No | Override model name (useful for single-model bindings). Auto-discovered if not set. |

Additionally, the provider will support automatic credential detection from `VCAP_SERVICES` when running on Cloud Foundry:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `VCAP_SERVICES` | Param | No | Standard CF environment variable. If present, the provider parses `genai` service bindings automatically. |

### 3.3 Provider Struct

```rust
pub struct TanzuAIServicesProvider {
    client: ApiClient,
    model: ModelConfig,
    /// The base endpoint URL (without /openai suffix)
    endpoint_base: String,
    /// JWT API key for Bearer auth
    api_key: String,
    /// Config URL for model discovery
    config_url: Option<String>,
    /// Cached list of available models (from discovery)
    available_models: Vec<TanzuModel>,
}

#[derive(Debug, Clone)]
struct TanzuModel {
    name: String,
    capabilities: Vec<String>,
    aliases: Vec<String>,
}
```

### 3.4 Credential Parsing Logic

The provider must handle three credential sources in priority order:

```
1. Explicit environment variables (TANZU_AI_ENDPOINT + TANZU_AI_API_KEY)
2. VCAP_SERVICES parsing (automatic CF detection)
3. Manual CLI configuration
```

#### VCAP_SERVICES Parsing

```rust
fn parse_vcap_services(vcap_json: &str) -> Option<TanzuCredentials> {
    let vcap: Value = serde_json::from_str(vcap_json).ok()?;
    let genai_bindings = vcap.get("genai")?.as_array()?;

    // Use the first genai binding
    let binding = genai_bindings.first()?;
    let creds = binding.get("credentials")?;

    // Try multi-model format first (recommended)
    if let Some(endpoint) = creds.get("endpoint") {
        return Some(TanzuCredentials {
            endpoint_base: endpoint["api_base"].as_str()?.to_string(),
            api_key: endpoint["api_key"].as_str()?.to_string(),
            config_url: endpoint["config_url"].as_str().map(String::from),
            model_name: creds.get("model_name")
                .and_then(|v| v.as_str())
                .map(String::from),
            model_capabilities: parse_capabilities(creds),
        });
    }

    // Fall back to single-model format (deprecated)
    Some(TanzuCredentials {
        endpoint_base: extract_endpoint_base(creds["api_base"].as_str()?),
        api_key: creds["api_key"].as_str()?.to_string(),
        config_url: None,
        model_name: creds.get("model_name")
            .and_then(|v| v.as_str())
            .map(String::from),
        model_capabilities: parse_capabilities(creds),
    })
}

/// Single-model api_base includes "/openai" suffix; strip it to get the endpoint base
fn extract_endpoint_base(api_base: &str) -> String {
    api_base.trim_end_matches("/openai").to_string()
}
```

#### Binding Format Detection

The provider detects the binding format using these heuristics:

| Condition | Format | Behavior |
|-----------|--------|----------|
| Top-level `model_name` present | Single-model | Use `model_name` as default model; strip `/openai` from `api_base` |
| Only `endpoint` block present | Multi-model | Discover models via config URL or `/openai/v1/models` |
| Both present | Single-model (v10.3+) | Single-model format now includes `endpoint` block; prefer `model_name` as default |

### 3.5 Model Discovery

For multi-model bindings, the provider discovers available models at initialization:

```rust
async fn discover_models(&self) -> Result<Vec<TanzuModel>, ProviderError> {
    // Prefer config_url for rich metadata (capabilities, aliases)
    if let Some(config_url) = &self.config_url {
        if let Ok(config) = self.fetch_config(config_url).await {
            return Ok(config.models);
        }
    }

    // Fall back to OpenAI /v1/models endpoint
    let models_url = format!("{}/openai/v1/models", self.endpoint_base);
    let response = self.client.get(&models_url, &self.api_key).await?;
    // Parse {"data": [{"id": "model-name", ...}]}
    Ok(parse_openai_models_response(response))
}
```

The config URL response provides richer metadata:

```json
{
  "name": "all-models-9afff1f",
  "advertisedModels": [
    {
      "name": "llama3.2:1b",
      "capabilities": ["CHAT", "TOOLS"]
    },
    {
      "name": "mxbai-embed-large",
      "capabilities": ["EMBEDDING"]
    }
  ]
}
```

The provider filters to models with `CHAT` or `TOOLS` capabilities for use as the primary completion model.

### 3.6 Provider Trait Implementation

```rust
#[async_trait]
impl Provider for TanzuAIServicesProvider {
    fn metadata() -> ProviderMetadata {
        ProviderMetadata::new(
            "tanzu_ai",
            "Tanzu AI Services",
            "LLM access via VMware Tanzu Platform AI Services (OpenAI-compatible)",
            vec![
                ConfigKey::new("TANZU_AI_API_KEY", true, true, None),  // secret
                ConfigKey::new("TANZU_AI_ENDPOINT", false, true, None), // required
                ConfigKey::new("TANZU_AI_CONFIG_URL", false, false, None), // optional
            ],
            TANZU_DEFAULT_MODEL.to_string(),
        )
    }

    async fn complete(
        &self,
        system: &str,
        messages: &[Message],
        tools: &[Tool],
    ) -> Result<(Message, ProviderUsage), ProviderError> {
        // Build OpenAI-format request payload
        let payload = openai_format::create_request(
            &self.model,
            system,
            messages,
            tools,
        )?;

        let url = format!("{}/openai/v1/chat/completions", self.endpoint_base);
        let response = self.client.post(&url, &payload).await?;

        // Handle Tanzu-specific error responses
        let (message, usage) = handle_tanzu_response(response)?;
        Ok((message, usage))
    }

    async fn complete_stream(
        &self,
        system: &str,
        messages: &[Message],
        tools: &[Tool],
    ) -> Result<Pin<Box<dyn Stream<Item = Result<StreamEvent>>>>, ProviderError> {
        let mut payload = openai_format::create_request(
            &self.model,
            system,
            messages,
            tools,
        )?;
        payload["stream"] = json!(true);

        let url = format!("{}/openai/v1/chat/completions", self.endpoint_base);
        // Use SSE streaming (same pattern as OpenAI provider)
        let stream = self.client.post_stream(&url, &payload).await?;
        Ok(openai_format::response_to_streaming_message(stream))
    }

    async fn list_models(&self) -> Result<Vec<String>, ProviderError> {
        let models = self.discover_models().await?;
        Ok(models.iter()
            .filter(|m| m.capabilities.iter().any(|c|
                c.eq_ignore_ascii_case("chat") || c.eq_ignore_ascii_case("tools")
            ))
            .map(|m| m.name.clone())
            .collect())
    }
}
```

### 3.7 API Client Configuration

The provider configures its `ApiClient` with:

- **Auth**: `Bearer {TANZU_AI_API_KEY}` header on all requests.
- **Base URL**: `{TANZU_AI_ENDPOINT}/openai` for the OpenAI-compatible endpoint.
- **Timeout**: 600 seconds default (configurable), matching the pattern of other providers.
- **Retry**: Standard Goose retry logic with exponential backoff on 429/5xx.

### 3.8 Error Handling

The provider handles Tanzu-specific error conditions:

| HTTP Status | Condition | Goose Error |
|-------------|-----------|-------------|
| 401 | Expired or invalid JWT | `ProviderError::Authentication` |
| 403 | Insufficient permissions / RBAC | `ProviderError::Authentication` |
| 429 | Rate limited by Tanzu middleware | `ProviderError::RateLimitExceeded` (with retry-after) |
| 502 | GenAI proxy → AI Server failure | `ProviderError::ServerError` (retryable) |
| 400 + "too long" | Context length exceeded | `ProviderError::ContextLengthExceeded` |

### 3.9 Registration in Factory

In `crates/goose/src/providers/factory.rs`, add the Tanzu provider to `init_registry()`:

```rust
// In init_registry()
register::<TanzuAIServicesProvider>(&mut registry, ProviderType::Builtin);
```

This makes it appear in the `goose configure` provider selection menu and in the Desktop UI.

---

## 4. Configuration UX

### 4.1 CLI Configuration Flow

```
$ goose configure
┌ goose-configure
│
◇ What would you like to configure?
│ Configure Providers
│
◆ Which model provider should we use?
│ ○ Anthropic
│ ○ OpenAI
│ ○ Databricks
│ ● Tanzu AI Services
│ ○ ...
│
◇ Provider Tanzu AI Services requires TANZU_AI_ENDPOINT, please enter a value
│ https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-all-models-1a56b7a
│
◇ Provider Tanzu AI Services requires TANZU_AI_API_KEY, please enter a value
│ ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪
│
◇ Discovering available models...
│ Found 3 models: openai/gpt-oss-120b, qwen3-30b, nomic-embed-text
│
◇ Enter a model from that provider:
│ openai/gpt-oss-120b
│
◇ Configuration saved!
└
```

### 4.2 Environment Variable Configuration

For Cloud Foundry-deployed scenarios or CI/CD:

```bash
# Option A: Explicit credentials
export GOOSE_PROVIDER=tanzu_ai
export TANZU_AI_ENDPOINT="https://genai-proxy.sys.example.com/my-plan-abc123"
export TANZU_AI_API_KEY="eyJhbGciOiJIUzI1NiJ9..."
export GOOSE_MODEL="openai/gpt-oss-120b"

# Option B: Auto-detect from VCAP_SERVICES (when running on CF)
export GOOSE_PROVIDER=tanzu_ai
# VCAP_SERVICES is automatically set by Cloud Foundry
```

### 4.3 Config File

In `~/.config/goose/config.yaml`:

```yaml
GOOSE_PROVIDER: tanzu_ai
GOOSE_MODEL: openai/gpt-oss-120b
TANZU_AI_ENDPOINT: https://genai-proxy.sys.example.com/tanzu-all-models-1a56b7a
```

(API key stored in system keyring, not config file.)

---

## 5. Multi-Model Support & Lead/Worker Pattern

Goose supports a lead/worker multi-model strategy where a "lead" model handles complex reasoning while a "worker" model handles simpler tasks. Tanzu multi-model bindings map naturally to this:

### 5.1 Model Selection Strategy

When connected to a multi-model binding, the provider:

1. **Discovers all models** via the config URL.
2. **Filters by capability**: Only models with `CHAT` or `TOOLS` capabilities are eligible as lead/worker models.
3. **Default model**: The first chat-capable model discovered, or the user-specified `GOOSE_MODEL`.
4. **Fast model**: If a second chat-capable model is available, it can be configured as the worker/fast model via `GOOSE_FAST_MODEL`.

### 5.2 Example Configuration with Multi-Model

```yaml
# Lead model: powerful for complex reasoning
GOOSE_PROVIDER: tanzu_ai
GOOSE_MODEL: openai/gpt-oss-120b

# Worker model: faster for simpler tasks (optional)
GOOSE_FAST_MODEL: qwen3-30b

# Shared endpoint
TANZU_AI_ENDPOINT: https://genai-proxy.sys.example.com/tanzu-all-models-1a56b7a
```

---

## 6. Testing Strategy

### 6.1 Unit Tests

Location: `crates/goose/src/providers/tanzu.rs` (inline tests)

- **Credential parsing**: Test both single-model and multi-model JSON formats.
- **VCAP_SERVICES parsing**: Test extraction from realistic VCAP JSON.
- **URL construction**: Verify `/openai` suffix handling for both formats.
- **Format detection**: Verify single vs. multi-model format heuristics.
- **Model filtering**: Test capability-based filtering (chat vs. embedding).

### 6.2 Integration Tests

Location: `crates/goose/tests/tanzu_provider.rs`

- **Provider initialization**: Test creating provider from environment variables.
- **Model discovery**: Mock HTTP server returning model list; verify parsing.
- **Streaming completion**: Mock SSE stream; verify message reconstruction.
- **Error handling**: Test 401, 429, 502 responses are classified correctly.
- **Config validation**: Test the provider configuration test (tool call verification).

### 6.3 Manual Validation

```bash
# Build and test
cargo build -p goose
cargo test -p goose -- tanzu
cargo clippy --all-targets -- -D warnings

# End-to-end with real Tanzu environment
export TANZU_AI_ENDPOINT="https://genai-proxy.sys.example.com/plan-name"
export TANZU_AI_API_KEY="..."
export GOOSE_PROVIDER=tanzu_ai
export GOOSE_MODEL=openai/gpt-oss-120b
goose session
```

---

## 7. Documentation

### 7.1 Provider Documentation Page

Add a Tanzu AI Services section to `documentation/docs/getting-started/providers.md`:

- Description of Tanzu AI Services and what it provides
- Prerequisites (Tanzu Platform access, a genai service binding)
- Configuration steps for CLI and Desktop
- Environment variable reference
- VCAP_SERVICES auto-detection explanation
- Multi-model binding usage
- Troubleshooting (common errors, JWT expiry, model not found)

### 7.2 Example Recipes

Provide Goose recipes for common Tanzu AI Services workflows:

```yaml
# tanzu-chat.yaml - Basic chat with Tanzu AI Services
name: tanzu-chat
description: Chat using Tanzu Platform AI Services
provider: tanzu_ai
model: openai/gpt-oss-120b
```

---

## 8. Implementation Plan

### Phase 1: Core Provider (MVP)

**Scope**: Basic provider with explicit credential configuration.

1. Create `crates/goose/src/providers/tanzu.rs` with `TanzuAIServicesProvider` struct.
2. Implement `Provider` trait using OpenAI format adapter.
3. Support both single-model and multi-model credential formats.
4. Register in `factory.rs` as `Builtin` provider.
5. Add configuration keys: `TANZU_AI_ENDPOINT`, `TANZU_AI_API_KEY`.
6. Add unit tests for credential parsing and URL construction.
7. Add integration test with mocked HTTP server.
8. Update `documentation/docs/getting-started/providers.md`.

**Estimated effort**: 3-5 days

### Phase 2: Auto-Discovery & VCAP

**Scope**: Dynamic model discovery and CF auto-configuration.

1. Implement `config_url` fetching for model discovery.
2. Implement `VCAP_SERVICES` parsing for automatic CF detection.
3. Add `list_models()` support for CLI interactive model selection.
4. Add capability-based model filtering.
5. Support multiple `genai` bindings in VCAP_SERVICES (let user select).

**Estimated effort**: 2-3 days

### Phase 3: Polish & Contribution

**Scope**: Prepare for upstream contribution.

1. Add Desktop UI support (ensure provider appears correctly in settings).
2. Write comprehensive documentation with screenshots.
3. Add recipe examples.
4. Run `cargo fmt`, `clippy-lint.sh`, full test suite.
5. Open PR against `block/goose` with description following contributing guidelines.
6. Address review feedback.

**Estimated effort**: 2-3 days

---

## 9. Contribution Approach

### 9.1 PR Structure

Following Goose's [contributing guidelines](https://github.com/block/goose/blob/main/CONTRIBUTING.md):

- **Single PR** containing the new provider, tests, and documentation.
- **Title**: `feat: Add Tanzu AI Services provider for VMware Tanzu Platform`
- **Description**: Link to this spec, describe the two binding formats, and explain the enterprise use case.
- **Labels**: `enhancement`, `provider`

### 9.2 Pre-Submission Checklist

- [ ] `cargo fmt` passes
- [ ] `./scripts/clippy-lint.sh` passes
- [ ] `cargo test -p goose` passes (including new tests)
- [ ] `cargo build -p goose-cli` succeeds
- [ ] Documentation updated in `providers.md`
- [ ] No new dependencies added (uses existing `reqwest`, `serde_json`, `tokio`)
- [ ] Provider tested against real Tanzu AI Services endpoint
- [ ] Self-test recipe works: `goose run --recipe goose-self-test.yaml`

### 9.3 Prior Art in the Goose Repo

Recent provider additions to reference for patterns:

- **OVHcloud AI Provider** (`#6527` by @rbeuque74) — recent community-contributed provider
- **Custom Provider Auth Flag** (`#6705` by @rabi) — `requires_auth` pattern
- **GCP Vertex AI** — enterprise cloud provider with OAuth, good reference for enterprise patterns
- **Databricks Provider** — complex auth (OAuth PKCE), model discovery, closest analog to Tanzu

---

## 10. Security Considerations

- **JWT tokens**: The `api_key` is a JWT signed by the GenAI proxy. It contains endpoint and client identifiers but no sensitive user data. Stored in Goose's keyring (or `secrets.yaml` fallback).
- **Token expiry**: Tanzu JWTs may have expiration. The provider should handle 401 responses gracefully and prompt for re-authentication.
- **No credential logging**: API keys must never appear in logs. Follow Goose's existing pattern of using the `Secret` config key type.
- **TLS**: All communication with `genai-proxy` is over HTTPS. The provider should respect system CA certificates for enterprise environments with custom CAs.
- **VCAP_SERVICES scope**: When parsing VCAP_SERVICES, only read the `genai` service type. Do not access or log credentials from other service bindings.

---

## 11. Open Questions

1. **Provider naming**: Should the provider be named `tanzu_ai`, `tanzu_ai_services`, or `vmware_tanzu`? Need to balance brevity with clarity. Recommendation: `tanzu_ai`.

2. **Multi-binding selection**: When `VCAP_SERVICES` contains multiple `genai` bindings, should the provider prompt for selection or use the first? Recommendation: Use the first binding by default, allow override via `TANZU_AI_BINDING_NAME` env var.

3. **Embedding support**: Goose's `Provider` trait includes an optional `embed()` method. Should the Tanzu provider support embeddings for models with the `EMBEDDING` capability? Recommendation: Yes, for Phase 2.

4. **Preferred vs. Builtin**: Should Tanzu AI Services be a `Preferred` provider (prominent in UI) or `Builtin` (standard)? Recommendation: `Builtin` initially, upgrade to `Preferred` based on community adoption.

5. **Custom provider compatibility**: Users currently work around this by using the "OpenAI-like" custom provider. Should we document a migration path? Recommendation: Yes, include in docs.

---

## Appendix A: Reference Binding Payloads

### A.1 Single-Model Binding (from real environment)

```json
{
  "api_base": "https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-gpt-oss-120b-v1025-eaf66e7/openai",
  "api_key": "eyJhbGciOiJIUzI1NiJ9...",
  "endpoint": {
    "api_base": "https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-gpt-oss-120b-v1025-eaf66e7",
    "api_key": "eyJhbGciOiJIUzI1NiJ9...",
    "config_url": "https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-gpt-oss-120b-v1025-eaf66e7/config/v1/endpoint",
    "name": "tanzu-gpt-oss-120b-v1025-eaf66e7"
  },
  "model_aliases": null,
  "model_capabilities": ["chat", "tools"],
  "model_name": "openai/gpt-oss-120b",
  "wire_format": "openai"
}
```

### A.2 Multi-Model Binding (from real environment)

```json
{
  "endpoint": {
    "api_base": "https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-all-models-1a56b7a",
    "api_key": "eyJhbGciOiJIUzI1NiJ9...",
    "config_url": "https://genai-proxy.sys.tas-ndc.kuhn-labs.com/tanzu-all-models-1a56b7a/config/v1/endpoint",
    "name": "tanzu-all-models-1a56b7a"
  }
}
```

### A.3 VCAP_SERVICES Example (Multi-Model)

```json
{
  "genai": [
    {
      "binding_guid": "162e78b4-408b-4bdd-8df3-0ae1e4d6d13b",
      "binding_name": null,
      "credentials": {
        "endpoint": {
          "api_base": "https://genai-proxy.sys.example.com/all-models-9afff1f",
          "api_key": "eyJhbGciOiJIUzI1NiJ9...",
          "config_url": "https://genai-proxy.sys.example.com/all-models-9afff1f/config/v1/endpoint",
          "name": "all-models-9afff1f"
        }
      },
      "instance_guid": "5008a1ec-c406-4ee8-8f9d-56c723af2f1f",
      "instance_name": "all-models",
      "label": "genai",
      "name": "all-models",
      "plan": "all-models",
      "tags": ["genai", "llm"]
    }
  ]
}
```

---

## Appendix B: Existing Provider Reference (OpenAI)

The OpenAI provider at `crates/goose/src/providers/openai.rs` is the closest reference implementation. Key patterns to follow:

| Aspect | OpenAI Pattern | Tanzu Adaptation |
|--------|---------------|------------------|
| Auth | `Bearer {OPENAI_API_KEY}` | `Bearer {TANZU_AI_API_KEY}` (JWT) |
| Host | `OPENAI_HOST` (default: api.openai.com) | `TANZU_AI_ENDPOINT` (required, no default) |
| Path | `OPENAI_BASE_PATH` (default: v1/chat/completions) | Always `openai/v1/chat/completions` relative to endpoint |
| Format | OpenAI format adapter | Same OpenAI format adapter |
| Streaming | SSE via LinesCodec | Same SSE approach |
| Models | Hardcoded list or fetched | Dynamic discovery via config URL |
| Timeout | `OPENAI_TIMEOUT` (600s) | `TANZU_AI_TIMEOUT` (600s default) |
