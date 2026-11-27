# OpenRouter integration research (2026-11-27)

Reading method. Most pages came through WebFetch, a SUMMARISING fetcher (a small model answers a prompt over the page). Quotes tagged [S] come from that summary and may be paraphrased by it. Quotes tagged [R] were seen as raw page text (Claude Code docs pages, Vercel page, curl+grep of Codex/Claude docs). Non-primary sources are tagged [NP]. Nothing was called with a key; no accounts created.

## 1. Claude Code -> OpenRouter

Officially supported? By OpenRouter yes (their own guide); by Anthropic only for Claude models.
- OpenRouter guide (cookbook/coding-agents/claude-code-integration, no date shown): "Claude Code with OpenRouter is only guaranteed to work with the Anthropic first-party provider." [S] https://openrouter.ai/docs/guides/guides/claude-code-integration (the .md twin is https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration.md)
- Same guide: "Claude Code is optimized for Anthropic models and may not work correctly with other providers." [S]
- Anthropic gateway docs: "doesn't support routing Claude Code to non-Claude models through any gateway." [R] https://code.claude.com/docs/en/llm-gateway . Same page: "Anthropic doesn't endorse, maintain, or audit third-party gateway products". So non-Anthropic models are neither supported by Anthropic nor guaranteed by OpenRouter.
- Anthropic's gateway contract: any gateway exposing a supported API format works; Anthropic Messages format = `ANTHROPIC_BASE_URL`, endpoints `/v1/messages` and optional `/v1/messages/count_tokens`, must forward `anthropic-beta` and `anthropic-version` verbatim. [R] https://code.claude.com/docs/en/llm-gateway-protocol.md

Exact env (OpenRouter guide, [S]):
- `ANTHROPIC_BASE_URL=https://openrouter.ai/api` (no `/v1`; `/api/v1` gives `/api/v1/v1/messages` -> 404)
- `ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"`
- `ANTHROPIC_API_KEY=""` (must be explicitly empty): "keeps Claude Code from falling back to authenticating against Anthropic directly."
- Optional `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` (model picker).
- Claude Code side: bearer var is `ANTHROPIC_AUTH_TOKEN` -> `Authorization: Bearer`; `ANTHROPIC_API_KEY` -> `x-api-key`. [R] https://code.claude.com/docs/en/llm-gateway-connect.md
- Model selection: `ANTHROPIC_MODEL` is not named on the fetched gateway pages (not documented there). OpenRouter's guide uses per-tier vars `ANTHROPIC_DEFAULT_{FABLE,OPUS,SONNET,HAIKU}_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL`. Value formats [S]: `~anthropic/claude-sonnet-latest[1m]` (floating alias), `anthropic/claude-sonnet-5[1m]` (pinned version), `@preset/claude-code`. `[1m]` is stripped before routing; without it Claude Code assumes 200k context.
- Headless caveat: `env` values in settings.json are literal (no `$VAR` expansion) -> use `apiKeyHelper` or export in the process env. [S] A saved claude.ai login can conflict; `/logout` or isolate the config dir. [R]/[S]
- `--bare` (recommended for scripted calls) "never reads OAuth credentials or the system keychain" and needs `ANTHROPIC_API_KEY` or `apiKeyHelper` in `--settings`; with a gateway bearer token use env `ANTHROPIC_AUTH_TOKEN`. [R] https://code.claude.com/docs/en/headless.md (interplay of --bare + AUTH_TOKEN not stated: UNVERIFIED).

Degradation behind any gateway (Anthropic table, [R] llm-gateway-protocol.md "feature pass-through"):
- Prompt caching: if the gateway strips `cache_control`, "No error: the conversation bills as uncached input".
- Token counting: without `count_tokens` "Claude Code falls back to a character-based estimate".
- Missing betas (interleaved thinking, extended context): silently unavailable; mid-conversation `role:"system"` entries can 400 and Claude Code retries without them.
- 400s naming `context_management`/`Extra inputs are not permitted`: set `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`. Gateways must pass error bodies unmodified or retry logic breaks.
- Fast mode needs `CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1` behind a bearer-token gateway. [R] llm-gateway-connect.md
- Whether OpenRouter's `/api/v1/messages` implements `count_tokens`, caches, thinking for NON-Anthropic models: not documented (OpenRouter's guide has "no limitations for tool calling, thinking, prompt caching, count_tokens" listed, i.e. silent). [S]
- OpenRouter docs mention `/api/v1/messages` takes a `fallbacks` param (max 3, not combinable with `models`). [S] https://openrouter.ai/docs/guides/routing/model-fallbacks.md

Cost/usage in `claude -p --output-format json`:
- "With `--output-format json`, the response payload includes `total_cost_usd` and a per-model cost breakdown" and "Both figures are client-side estimates and can differ from your actual bill." [R] https://code.claude.com/docs/en/headless.md
- "The `total_cost_usd` and `costUSD` fields are client-side estimates, not authoritative billing data." Computed locally from a bundled price table (or managed `modelPricing`). [R] https://code.claude.com/docs/en/agent-sdk/cost-tracking.md
- Consequence (INFERENCE): for a non-Anthropic model slug the bundled table has no price; whether the field is 0, absent or wrong is not documented. Authoritative cost = OpenRouter (`usage.cost`, generation stats, key `usage`).
- `--max-budget-usd`: documented as a cap on Claude Code's own accumulated estimate ("reaches its `--max-budget-usd` cap, Claude Code stops"). [R] headless.md. It therefore inherits the estimate's blindness for unknown models: UNVERIFIED for non-Anthropic models. Do not rely on it; use the OpenRouter per-key limit as the hard stop.

## 2. Codex CLI -> OpenRouter

Supported by OpenRouter's guide: https://openrouter.ai/docs/cookbook/coding-agents/codex-cli.md (no date shown). "It supports multiple model providers, including OpenRouter". [S]
Config block published by OpenRouter [S, TOML shown as page text]:
```
model_provider = "openrouter"
model = "~openai/gpt-sol-latest"        # any OpenRouter slug, or pinned slug
[model_providers.openrouter]
name = "openrouter"
base_url = "https://openrouter.ai/api/v1"
[model_providers.openrouter.auth]
command = "sh"
args = ["-c", "echo $OPENROUTER_API_KEY"]
```
- Note on `env_key = "OPENROUTER_API_KEY"`: "also works for authentication, but Codex won't fetch the OpenRouter model catalog in that mode" -> "Unknown model" fallback-metadata warning. [S]
- Wire API: Codex config reference: "`responses` is the only supported value, and it is the default when omitted." [S] https://learn.chatgpt.com/docs/config-file/config-reference (redirect target of developers.openai.com/codex/config-reference). `wire_api = "chat"` is therefore gone (the page does not name "chat": inference).
- OpenRouter implements Responses: `POST /api/v1/responses` is "the main endpoint" in its quickstart [S] https://openrouter.ai/docs/quickstart.md . The API is stateless: "requests with `store: true` or non-null `previous_response_id` return a 400" [S] https://openrouter.ai/docs/api-reference/responses/overview.md . Whether current Codex 0.172 sends `store`/`previous_response_id`/WebSocket transport to a custom provider: UNVERIFIED (`supports_websockets` exists as a provider key, default not stated).
- Provider table keys: `base_url`, `env_key`, `wire_api`, `query_params`, `http_headers`, `env_http_headers`, `auth{command,args,timeout_ms=5000,refresh_interval_ms=300000}`; `auth` cannot combine with `env_key`. Reserved ids: openai, ollama, lmstudio, amazon-bedrock, amazon-bedrock-runtime, gcp. [S] config-reference / config-advanced.
- `-c key=value` overrides, TOML-parsed, dot notation: [S] https://learn.chatgpt.com/docs/config-file/config-advanced . Headless one-liner (INFERENCE from those keys): `codex exec --json -c model_provider=openrouter -c 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"' -c 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"' -m <slug> "..."` with `CODEX_HOME` pointing at an isolated dir (CODEX_HOME exists: "`$CODEX_HOME/config.toml`" [R] https://developers.openai.com/codex/noninteractive.md). Profiles: since 0.134.0 `[profiles.name]` tables are no longer read; use `--profile name` -> `~/.codex/name.config.toml`. [S]
- `--ignore-user-config` skips `$CODEX_HOME/config.toml`. [R] noninteractive.md
- Usage in headless: `{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}` [R] noninteractive.md. This is the OpenAI-host example; that OpenRouter-served runs populate the same fields: UNVERIFIED (OpenRouter Responses returns `usage` incl. `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`, `cost` per its usage page [S]).
- Limits (apply_patch, tool calling, reasoning items with non-OpenAI models): OpenRouter guide lists none; Responses tool calling and encrypted reasoning are described [S]; behaviour of `apply_patch` freeform tool on non-OpenAI models: not documented.
- `OPENAI_API_KEY`/`CODEX_API_KEY` must not leak into the job: a 401 "not an OpenRouter API key" means Codex sent another provider's key. [S] OpenAI warns not to set them job-level where repo code runs. [R] noninteractive.md

## 3. Spend control and accounting

Limited key creation:
- UI: Key limit in the key dialog. API: management key `POST https://openrouter.ai/api/v1/keys` with `name`, `limit`, `limit_reset`, `include_byok_in_limit`, `disabled`; update via `PATCH /api/v1/keys/{key_hash}`. "Management keys cannot be used to make API calls to OpenRouter's completion endpoints". Management-key expiration cannot be changed later. [S] https://openrouter.ai/docs/guides/overview/auth/management-api-keys.md
- `limit_reset`: daily, weekly, monthly, "resets at midnight UTC"; unset = lifetime cap. `include_byok_in_limit` default false. [S] https://openrouter.ai/docs/guides/best-practices/capping-shared-agent-keys.md
- Key expiry: `expires_at` at creation is mentioned on the limits page ("Setting `expires_at` at creation avoids a separate delete request") [S] https://openrouter.ai/docs/api-reference/limits ; the management-keys page does not document it for API keys (conflict between two summaries; verify on the API reference).
- Read state: `GET /api/v1/key` returns `limit`, `limit_reset`, `limit_remaining` (and `free_model_daily_requests`). [S] limits page.
Limit hit:
- Capping page: "Requests on that key return `403 Forbidden` with a 'Key limit exceeded' message" (workspace budget: also 403). [S]
- Limits page: 402 with `error.metadata.limit_source` in {`openrouter_key_limit`, `openrouter_in_flight_budget`, `openrouter_credits`}. [S] CONFLICT between the two pages: a harness must treat 402 AND 403 as "budget stop"; record the body. Also a 402 can fire with positive balance (in-flight budget; honour `Retry-After`).
- Mid-stream: "the error arrives as an SSE event with `finish_reason: "error"` rather than an HTTP 429". [S]
Rate limits: free `:free` models 20 req/min; 50/day if <10 credits purchased, 1000/day if >=10 [S]; key-management writes 10,000/day; paid-model limits "not summarised" on the page (not documented in what I saw). 429: exponential backoff, honour `Retry-After`. [S]
Per-request cost: every response carries `usage` automatically ("Full usage details are always included automatically in every response on both APIs"); fields `cost`, `cost_details.upstream_inference_cost`, `prompt_tokens_details.cached_tokens` / Responses `input_tokens_details.{cached_tokens,cache_write_tokens}`, `is_byok`. `usage:{include:true}` and `stream_options` are deprecated no-ops. Async: `GET /generation?id=<gen-id>`. `upstream_inference_cost` only populated for BYOK. [S] https://openrouter.ai/docs/cookbook/administration/usage-accounting.md
Billing: credits purchase fee 5.5% (min $0.80; crypto 5%), "Provider pricing has no markup". BYOK: 5% after a $25,000/month allowance (pay-as-you-go). [S] https://openrouter.ai/docs/faq.md
Free models: IDs end `:free`; "Free models have low rate limits ... generally not suited to production"; `openrouter/free` router picks one. Data policy of free models: the privacy page says "Paid and free models have separate settings" for training opt-out. [S] faq.md, provider-logging.md. Per-model free data policy beyond that: not documented in fetched pages.
Budgets above keys: workspace budgets and guardrail budgets (daily/weekly/monthly; first limit hit blocks); spend is attributed to the key's CREATOR; workspace-owned keys need their own limit. [S] https://openrouter.ai/docs/guides/best-practices/spend-controls.md

## 4. Reproducibility

- Pin version: `id` is a mutable slug; `canonical_slug` is "Permanent slug for the model that never changes" (dated). `~vendor/model-latest` aliases float. [S] https://openrouter.ai/docs/guides/overview/models.md . The models page does not describe `~latest`; the Claude Code/Codex guides use it. For an eval: use a dated/versioned slug, never `~...-latest`; record the models-list entry (`canonical_slug`, `expiration_date`) per run.
- Provider routing object (request body only): `order`, `only`, `ignore`, `allow_fallbacks` (default true), `require_parameters` (false), `data_collection` (default "allow"; "deny"), `zdr`, `quantizations` (int4, int8, fp4, mxfp4, nvfp4, fp6, fp8, mxfp8, fp16, bf16, fp32, unknown), `sort`, `max_price`, ... [S] https://openrouter.ai/docs/guides/routing/provider-selection.md . Default routing is load-balanced and random: "each request picks one at random, weighted by those shares" -> same slug can hit different providers run to run. [S]
- Variance statement by OpenRouter: quantized models "may exhibit degraded performance for certain prompts" [S]; "Providers serving the same model can vary meaningfully in tool-use behavior." [S] https://openrouter.ai/docs/guides/routing/model-variants/exacto.md ; providers differ on "price, TTFT, reliability, quality, 429s" [S] traffic-routing.md. Also structured-output support "is determined per endpoint, not just per model". [S]
- Disable fallbacks: `provider.allow_fallbacks=false` and/or `provider.only=[one]`; omit `models`. With `order`/single-provider `only`, routing is skipped. [S] traffic-routing.md. Model-level fallbacks: "any error can trigger the use of a fallback model" when `models` is given. [S] model-fallbacks.md
- Claude Code and Codex cannot send a `provider` object (INFERENCE; Vercel's page says the same of Claude Code: "Claude Code can't send those AI Gateway options itself" [R]). Ways to pin without body control: a Preset referenced as model `@preset/<name>` (can carry provider routing, model(s), parameters; "Request fields override matching preset fields"; API uses latest version) [S] https://openrouter.ai/docs/guides/features/presets.md ; OpenRouter's own Claude Code page uses `@preset/claude-code` with `provider.order:["anthropic"]` [S]; account/workspace default guardrail (allowed providers/models, ZDR). Whether `@preset/` slug works as Codex `model`: not documented. Presets are mutable (new version = active), so store the preset version/contents per run.
- Seeds/temperature: Chat API schema has `seed` and `temperature` (0-2); unsupported params are ignored; `system_fingerprint` only if provider supports it. [S] https://openrouter.ai/docs/api-reference/overview.md . Determinism is not promised; treat runs as stochastic.
- Which provider served: response has `id` (gen-...), `model` (actual model, can differ from requested); `provider` appears in example responses; `GET /generation` stats for after-the-fact lookup. [S] api-reference/overview.md, usage-accounting. Claude Code/Codex JSON do not surface this: log via generation lookups or Broadcast.

## 5. Privacy and security

- Defaults: OpenRouter "does not store your prompts or responses" unless you opt in to Input/Output Logging or "OpenRouter Use of Inputs/Outputs" (1% discount); metadata (tokens, latency) always stored; flagged CSAM exceptions; anonymous categorisation sample. [S] https://openrouter.ai/docs/guides/privacy/data-collection.md ; logging retention "a minimum of 3 months" when logging is on. [S] https://openrouter.ai/docs/guides/features/input-output-logging.md
- Provider tiers: ZDR / Safety Retention / standard retention; "OpenRouter does not have routing rules that change based on data retention policies of providers" -> you must filter. Training opt-out is an account setting (paid and free separately); request-level `data_collection:"deny"` and `zdr:true`. "Training avoidance is not guaranteed ... but there are exceptions." [S] provider-logging.md, zdr.md
- ZDR: account-level per model group (Anthropic, OpenAI, Google, "All other"), guardrail-level (`enforce_zdr_*`), request-level `provider.zdr:true` (additive only). Unknown policy => assumed to retain and train. Endpoint list: `GET https://openrouter.ai/api/v1/endpoints/zdr`. Tools/plugins (web search) have their own retention. [S] https://openrouter.ai/docs/guides/features/zdr.md
- Region: `eu.openrouter.ai` / `us.openrouter.ai` in-region routing, Business/Enterprise only. [S] provider-logging.md. Default processing location otherwise: not documented in fetched pages.
- Before sending proprietary code (INFERENCE from the above): ZDR-only + no-training at account/workspace guardrail level; leave logging and "use of inputs" OFF; Broadcast destinations off or Privacy Mode; allowed-provider list; BYOK only if your own agreement covers it; check Safety Retention allowance; get Enterprise terms/DPA (not documented here).
- Key hygiene: Security Center (posted 2026-09-28) flags keys with no limit/no expiry/unused 90+ days; admins can enforce a maximum key lifetime; expiry of an existing key can't be changed -> rotate by new key + disable/archive old; IP allowlist is Enterprise-only; "Key scopes" and secret scanning: not documented. [S] https://openrouter.ai/docs/guides/overview/auth/security-settings.md , https://openrouter.ai/blog/announcements/security-center/ ; rotation cookbook: https://openrouter.ai/docs/cookbook/administration/api-key-rotation.md (not read).
- Incidents: no first-party OpenRouter advisory/postmortem found. [NP] third-party reports of OpenRouter keys stolen from other platforms (Railway disclosure Oct 2026, Zeabur env leak) = key theft at the customer's host, not an OpenRouter breach; an "unconfirmed OpenRouter breach claim" appears in one commentary. https://blog.railway.com/p/security-disclosure-recommendation-check-for-unexpected-openrouter-usage . [NP] The Register 2026-10-26 on a LiteLLM master-key issue (relevant to alternative 7): https://www.theregister.com/2026/10/26/litellm_master_key/5305544 (headline only, article not read).

## 6. Services calling LLMs (Go, Rust, Python)

Facts: OpenAI-compatible base URL `https://openrouter.ai/api/v1`; quickstart shows OpenAI SDK with `responses.create`; attribution headers `HTTP-Referer` and `X-OpenRouter-Title` (page uses this name, not `X-Title`). Official SDKs: TypeScript `@openrouter/sdk`, Python `openrouter`; agent SDKs TS/Python; no Go SDK (examples call HTTP), no Rust SDK listed. [S] https://openrouter.ai/docs/quickstart.md , https://openrouter.ai/docs/app-attribution.md (not read). Maturity: not documented.

Practice -> scaffold ships -> hermetic verification (all verification = local fake of `/api/v1/chat/completions` or `/responses`; no paid call):
- Gateway as config, not code -> `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` env, default OpenRouter, any OpenAI-compatible URL swaps in -> test points base URL at fake; CI greps no hard-coded host.
- Pinned model slug (no `~latest`) -> slug validated at config load -> unit test rejects `~`/`:free`/missing slug.
- Fallbacks as resilience -> `models:[primary,fallback]` array, or `provider.order`; explicit `allow_fallbacks` -> fake returns 5xx/429 for primary; assert request body carries the array; assert response `model` is recorded as served-model. ("You pay the rate of the model that ultimately served"; list only `:free` to keep a request free.) [S]
- Timeouts/retries -> client timeout per request, bounded exponential backoff with jitter on 429/5xx, honour `Retry-After`, never blind-retry non-idempotent tool side effects. OpenRouter guidance: 429 backoff; 402 do not retry blindly. [S] limits page. Idempotency keys / request dedupe: not documented. Timeout values: not documented.
- Streaming + mid-stream errors -> SSE parser ignores `:` comment lines ("occasionally contain a comment payload, which you should ignore") and handles an error chunk with `finish_reason:"error"` after HTTP 200 [S] -> fake emits comment, error-chunk, truncated stream; test asserts no partial result is committed.
- Structured outputs -> `response_format.json_schema` strict + `provider.require_parameters:true`; support is per endpoint; invalid JSON still possible -> validate output locally -> fake returns invalid JSON; assert validation error and bounded repair/retry.
- Tool calling -> `supported_parameters=tools` model check, `parallel_tool_calls` explicit; executor in your code; replay all output items in order -> fake returns tool_call then final; assert loop terminates and has a max-turns cap. Tool error rate varies by provider (Exacto). [S]
- Prompt caching -> stable prefix first, optional `cache_control` (Anthropic/Qwen/Gemini), `session_id`/`x-session-id` for sticky routing; manual `provider.order` overrides stickiness. [S] https://openrouter.ai/docs/guides/best-practices/prompt-caching.md -> assert prefix bytes identical across calls; read `cached_tokens` from usage in fake.
- Cost/observability -> log `id`, `model`, `provider` (if present), `usage.cost`, token counts per call as structured fields; attribution headers set -> test asserts headers sent and a metric emitted from fake `usage`.
- Broadcast: OpenRouter-side trace export, OTel Collector destination, one trace per request, Privacy Mode per destination, up to 5 destinations per workspace. [S] https://openrouter.ai/docs/guides/features/broadcast.md . OpenTelemetry GenAI semantic conventions status in OpenRouter: not documented; scaffold should emit its own client spans.
- BYOK -> optional, off by default; fees 5% beyond allowance; data policies still apply; BYOK not in budgets unless toggled. [S] https://openrouter.ai/docs/guides/overview/auth/byok.md -> config test that BYOK flag is explicit.
- Secrets -> key from env/secret manager only, per-service limited key with expiry -> secret-scan gate; fake test asserts key never logged.
- Data policy in code -> send `provider:{data_collection:"deny", zdr:true}` on every request from services handling sensitive data -> assert in fake.

## 7. Alternatives (axes: self-host / per-key budgets / Anthropic-format endpoint for Claude Code)

- LiteLLM proxy: self-hosted; serves Anthropic `/v1/messages` and Claude Code via `ANTHROPIC_BASE_URL` [S] https://docs.litellm.ai/docs/tutorials/claude_responses_api ; per-key spend tracking cited by Anthropic: "tracks spend by key" [R] https://code.claude.com/docs/en/costs.md ("unaffiliated with Anthropic ... not been audited for security"). Budget details not seen on the tutorial page.
- Vercel AI Gateway: hosted only (not shown self-hostable); Anthropic-compatible `https://ai-gateway.vercel.sh/claude-code` with the same env triplet; page last_updated 2026-09-13 [R] https://vercel.com/docs/ai-gateway/coding-agents/claude-code ; per-key budgets not on that page.
- Cloudflare AI Gateway: hosted; Anthropic endpoint `https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/anthropic`; budgets and self-hosting not covered on that page [S] https://developers.cloudflare.com/ai-gateway/usage/providers/anthropic/
- Portkey: managed (self-host not on page); `ANTHROPIC_BASE_URL=https://api.portkey.ai` with `x-portkey-*` headers via `ANTHROPIC_CUSTOM_HEADERS`; cost/token/rate limits; needs `forward_headers:["anthropic-beta"]` [S] https://portkey.ai/docs/integrations/libraries/claude-code
- Direct provider APIs: no gateway risk; Anthropic Console workspaces have spend limits [R] costs.md; Claude Code to Anthropic first-party is the only Anthropic-supported path for Claude models, plus Claude apps gateway (Anthropic's self-hosted gateway, per-user spend limits) [R] https://code.claude.com/docs/en/claude-apps-gateway ; OpenAI direct for Codex.

## 8. Recommendation (INFERENCE, not from docs)

Minimal safest model axis for headless evals:
1. Split the axis by host: Claude Code arm = Anthropic models only via OpenRouter (supported path; pin `anthropic/<versioned>` slug plus `@preset/<eval>` with `provider.order:["anthropic"]`, fallbacks off). Codex arm = OpenAI-family slugs first (Responses-native), then others as an explicitly "unsupported-by-host" tier. Run non-Anthropic models in Claude Code only as a labelled experiment (Anthropic says unsupported).
2. One OpenRouter workspace for evals; one limited key per eval run/suite: `limit` small, `limit_reset` set, `expires_at` days, created by a management key kept off the runner. Treat HTTP 402 and 403 as budget-stop.
3. Isolated config per run: fresh `CLAUDE_CONFIG_DIR` (or equivalent) and `CODEX_HOME` containing only the provider block; inject the key via env, never in settings files; `ANTHROPIC_API_KEY=""`; unset `OPENAI_API_KEY`; `--bare` for Claude if it works with the bearer token (verify).
4. Cost captured from OpenRouter, not the hosts: after each run read `GET /api/v1/key` usage delta (one key per run makes it exact) and/or `/generation` per id; keep host `total_cost_usd` only as a cross-check.
5. Record per run: slug, preset content/version, `canonical_slug`, served `model`/provider, host version, key hash, spend. Privacy: ZDR on, no-training, logging off for proprietary corpora.
Top 5 risks:
1. Silent provider drift/quantization: default routing is random across providers; without a preset/`only` pin the "same model" is not the same.
2. Non-Anthropic models in Claude Code are unsupported by Anthropic and unguaranteed by OpenRouter; failures look like model weakness (confounds the skill A/B).
3. Host cost fields are client estimates and likely wrong/zero for unknown slugs; `--max-budget-usd` unreliable there -> only the OpenRouter limit is a hard cap, and its error code (402 vs 403) is inconsistently documented.
4. Codex vs OpenRouter statelessness/WebSocket/`apply_patch` on non-OpenAI models unverified; headless `codex exec` behaviour through OpenRouter was never run here.
5. Key and data exposure: bearer keys in env visible to repo-controlled code run by the agent; proprietary code to third-party providers (retention tiers, Safety Retention, unknown-policy assumed training) .

## UNVERIFIED (not confirmed from a primary source; tried)
- Claude Code with a non-Anthropic OpenRouter slug: actual `total_cost_usd`/`modelUsage` values and `--max-budget-usd` behaviour (docs only say client-side estimate; not run - would need paid call).
- `ANTHROPIC_MODEL` semantics behind a gateway (tried gateway/connect pages; only per-tier vars shown by OpenRouter).
- OpenRouter `/api/v1/messages` support for `count_tokens`, caching and thinking on non-Anthropic models (no dedicated page found; messages API reference URL 404'd).
- Codex 0.172 request shape to custom providers (store, previous_response_id, websockets), and `turn.completed.usage` populated via OpenRouter (github docs/exec.md not found; openai/codex repo docs only point to the web docs).
- Whether `expires_at` is accepted on API-key create (two summaries disagree); exact 402-vs-403 on key limit.
- Paid-model rate limits, request timeouts, idempotency, default processing region, OTel GenAI conventions, Go/Rust SDK maturity: not documented in pages read.
- Security incidents: only third-party material; no first-party advisory found; The Register LiteLLM article not opened.
- Quotes tagged [S] were not seen verbatim; the WebFetch summariser may have reworded them.

## SOURCES (date shown on page)
OpenRouter (all "no date shown" unless noted): https://openrouter.ai/docs/guides/guides/claude-code-integration ; .../cookbook/coding-agents/claude-code-integration.md ; .../cookbook/coding-agents/codex-cli.md ; .../api-reference/limits ; .../guides/routing/provider-selection.md ; .../guides/routing/model-fallbacks.md ; .../guides/routing/traffic-routing (guides/providers/traffic-routing.md) ; .../guides/routing/model-variants/exacto.md ; .../guides/features/presets.md ; .../guides/features/zdr.md ; .../guides/features/broadcast.md ; .../guides/features/structured-outputs.md ; .../guides/features/tool-calling.md ; .../guides/features/input-output-logging.md ; .../guides/privacy/data-collection.md ; .../guides/privacy/provider-logging.md ; .../guides/best-practices/{prompt-caching,capping-shared-agent-keys,spend-controls,uptime-optimization}.md ; .../guides/overview/auth/{management-api-keys,security-settings,byok}.md ; .../guides/overview/models.md ; .../cookbook/administration/usage-accounting.md ; .../api-reference/overview.md ; .../api-reference/responses/overview.md ; .../quickstart.md ; .../faq.md ; https://openrouter.ai/blog/announcements/security-center/ (2026-09-28) ; index https://openrouter.ai/docs/llms.txt
Anthropic: https://code.claude.com/docs/en/{llm-gateway,llm-gateway-connect,llm-gateway-protocol,headless,costs,agent-sdk/cost-tracking}.md (no date shown)
OpenAI Codex: https://developers.openai.com/codex/noninteractive.md ; https://learn.chatgpt.com/docs/config-file/{config-advanced,config-reference} (redirect of developers.openai.com/codex/config-*) (no date shown)
Alternatives: https://docs.litellm.ai/docs/tutorials/claude_responses_api (no date) ; https://vercel.com/docs/ai-gateway/coding-agents/claude-code (last_updated 2026-09-13) ; https://developers.cloudflare.com/ai-gateway/usage/providers/anthropic/ (no date) ; https://portkey.ai/docs/integrations/libraries/claude-code (no date)
Non-primary [NP]: https://blog.railway.com/p/security-disclosure-recommendation-check-for-unexpected-openrouter-usage ; https://www.theregister.com/2026/10/26/litellm_master_key/5305544 (search-result listing only)
