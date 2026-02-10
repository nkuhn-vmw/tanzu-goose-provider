# Upstream PR: Tanzu AI Services Provider for Goose

## PR Title
`feat: Add Tanzu AI Services provider for VMware Tanzu Platform`

## PR Description

### Summary
Add a first-class Tanzu AI Services provider for Goose, enabling enterprise-managed LLM access through VMware Tanzu Platform's GenAI proxy.

### What this PR does
- Adds `TanzuAIServicesProvider` as a Builtin provider using `OpenAiCompatibleProvider`
- Supports both **single-model** and **multi-model** credential binding formats from Tanzu AI Services
- Automatic credential detection from `VCAP_SERVICES` for Cloud Foundry deployments
- Dynamic model discovery via the `config_url` endpoint with capability-based filtering
- Bearer token (JWT) authentication
- 14 unit tests for credential parsing, URL construction, and format detection
- 10 integration tests using wiremock for HTTP-level testing
- Documentation added to `providers.md`

### Configuration
```bash
export GOOSE_PROVIDER=tanzu_ai
export TANZU_AI_ENDPOINT="https://genai-proxy.sys.example.com/plan-name"
export TANZU_AI_API_KEY="eyJhbGciOiJIUzI1NiJ9..."
export GOOSE_MODEL="openai/gpt-oss-120b"
```

Or auto-detected from `VCAP_SERVICES` when running on Cloud Foundry.

### Files Changed
| File | Change |
|------|--------|
| `crates/goose/src/providers/tanzu.rs` | **New** — Provider implementation |
| `crates/goose/src/providers/mod.rs` | Add `pub mod tanzu;` |
| `crates/goose/src/providers/init.rs` | Register `TanzuAIServicesProvider` |
| `crates/goose/tests/tanzu_provider.rs` | **New** — Integration tests |
| `documentation/docs/getting-started/providers.md` | Add Tanzu row |

### Testing
- `cargo fmt` — passes
- `cargo clippy -p goose -- -D warnings` — passes
- `cargo test -p goose -- tanzu` — 24 tests pass (14 unit + 10 integration)
- No new dependencies added

### Prior Art
- Pattern follows xAI provider (`xai.rs`) using `OpenAiCompatibleProvider`
- Error handling uses `openai_compatible::map_http_error_to_provider_error`
- Enterprise provider patterns from Databricks and GCP Vertex AI

### Labels
`enhancement`, `provider`
