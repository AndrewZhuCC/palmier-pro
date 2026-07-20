# BYOK implementation and macOS 26 validation notes

Date: July 20, 2026

## Summary

This work replaces the previous single-provider assumptions with a shared provider architecture for both Agent conversations and media generation. Palmier-managed services remain supported, while users can configure their own Anthropic, OpenAI, fal, or compatible endpoints.

The implementation keeps provider-specific wire formats behind adapters, stores secrets in Keychain rather than project or profile JSON, applies the same availability rules across the UI, Agent tools, and MCP, and persists enough non-sensitive job state to resume asynchronous generation after reopening a project.

## Provider configuration and credentials

- Added reusable provider profiles that can enable Agent support, Generation support, or both.
- Added presets and configuration for Palmier managed, Anthropic Messages, OpenAI Responses, OpenAI Chat Completions, OpenAI media generation, fal queue generation, and compatible v1 generation services.
- Added authentication modes for bearer tokens, `x-api-key`, custom authorization headers, and unauthenticated endpoints.
- Stored non-sensitive provider metadata atomically in Application Support.
- Stored primary credentials and secret header values as separate Keychain items under the `io.palmier.pro.ai-provider` service.
- Kept secret values out of serialized provider profiles and merged them only when constructing runtime profiles.
- Added transactional save and migration behavior so metadata failures attempt to restore the previous Keychain state.
- Added migration from the legacy Anthropic API key to a stable Anthropic provider profile.

Important implementation areas:

- `Sources/PalmierPro/AIProviders/AIProviderModels.swift`
- `Sources/PalmierPro/AIProviders/AIProviderEndpoint.swift`
- `Sources/PalmierPro/AIProviders/AIProviderRepository.swift`
- `Sources/PalmierPro/AIProviders/AIProviderCredentialVault.swift`
- `Sources/PalmierPro/AIProviders/AIProviderStore.swift`
- `Sources/PalmierPro/AIProviders/AIProviderRuntimeProfile.swift`

## Validation and security rules

Provider validation now rejects unsafe or ambiguous configuration before requests are made:

- Duplicate profile identifiers and invalid Palmier-managed identity combinations.
- Remote plain HTTP unless the user explicitly opts in; loopback HTTP remains available for local development.
- Absolute endpoint URLs, authorities, queries, fragments, path traversal, and encoded traversal variants.
- Invalid or structural HTTP headers and attempts to override protocol-owned headers.
- CR/LF and other unsafe control characters in credentials or header values.
- Additional JSON fields that override protocol-reserved request fields.
- Missing Agent models, invalid token limits, incomplete credentials, and missing secret headers.
- Cross-origin or cross-port credential forwarding unless explicitly enabled.

Provider response bodies, API keys, secret headers, signed URLs, and user prompts are not included in user-facing transport errors.

## Agent providers and codecs

Agent requests and streaming events now use provider-neutral internal models for text, images, tool calls, tool results, usage, and finish reasons.

Supported Agent protocols:

- Palmier managed
- Anthropic Messages
- OpenAI Responses
- OpenAI Chat Completions

The provider codecs preserve conversation and tool-result ordering, aggregate fragmented tool arguments, normalize usage and finish reasons, handle malformed stream events, and maintain valid tool-call structure when a turn is cancelled or fails.

The shared HTTP transport uses an ephemeral `URLSession`, disables cookies and credential storage, limits response and stream sizes, validates UTF-8, and only follows same-origin redirects by default.

Important implementation areas:

- `Sources/PalmierPro/Agent/Clients/AgentClientTypes.swift`
- `Sources/PalmierPro/Agent/Clients/AgentClientFactory.swift`
- `Sources/PalmierPro/Agent/Clients/Codecs/`
- `Sources/PalmierPro/Agent/Clients/AnthropicClient.swift`
- `Sources/PalmierPro/Agent/Clients/OpenAIResponsesClient.swift`
- `Sources/PalmierPro/Agent/Clients/OpenAIChatCompletionsClient.swift`
- `Sources/PalmierPro/Agent/AgentService.swift`

## Generation providers, catalog, and recovery

Generation now goes through a common provider interface that can either return completed artifacts immediately or return a persistent job handle for polling.

Supported generation adapters:

- Palmier managed generation
- fal queue generation
- OpenAI image, TTS, and configured video models
- Compatible v1 synchronous or asynchronous generation endpoints

Model identifiers are qualified by provider profile so two providers can safely expose the same model identifier. `ModelCatalog` merges Palmier models with enabled external catalogs and isolates individual provider failures.

Managed and BYOK access policies are intentionally different:

- Palmier-managed models continue to enforce account, credit, and paid-tier rules.
- BYOK models require an enabled, valid provider with complete credentials and are not hidden by Palmier subscription gating.

Generation persistence now records provider identity, job handles, output indexes, and result URLs without persisting credentials. After reopening a project, a placeholder can resume polling or continue downloading an already completed result. Signed or credential-bearing upload URLs are not persisted or reused.

Important implementation areas:

- `Sources/PalmierPro/Generation/Providers/`
- `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift`
- `Sources/PalmierPro/Generation/GenerationService.swift`
- `Sources/PalmierPro/Generation/Edit/EditSubmitter+Rerun.swift`
- `Sources/PalmierPro/Models/MediaAsset.swift`
- `Sources/PalmierPro/Models/MediaManifest.swift`

## Settings, UI, and MCP

- Added an **AI Providers** settings page for creating, editing, copying, enabling, testing, and deleting provider profiles.
- Added independent Agent and Generation configuration within a profile.
- Added provider and per-provider model selection to the Agent panel.
- Updated Agent readiness messages to distinguish Palmier account requirements from BYOK configuration or credential problems.
- Updated generation model menus to show the provider name and expose only currently usable models.
- Updated edit, rerun, upscale, music, image, video, and audio generation paths to use the shared provider policy.
- Updated `list_models` and MCP model resources to include provider identity and expose the same models available in the application.
- Configured the provider store before the model catalog during application startup.

Important implementation areas:

- `Sources/PalmierPro/Settings/ProvidersPane.swift`
- `Sources/PalmierPro/Settings/AgentPane.swift`
- `Sources/PalmierPro/Agent/Panel/AgentPanelView.swift`
- `Sources/PalmierPro/Agent/MCP/MCPService.swift`
- `Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift`
- `Sources/PalmierPro/App/main.swift`

## macOS 26 build and test remediation

The initial macOS 26 full-suite run exposed 41 failures. Thirty-eight shared one root cause: the Apple Metal compiler was unavailable, and failed plugin commands left zero-byte `.metallib` outputs that SwiftPM could later treat as valid resources.

The remediation was:

- Install and verify Apple Metal Toolchain `17C7003j`.
- Delete stale build artifacts and perform a clean rebuild.
- Change `MetalCIKernelPlugin` to remove an old final output before compiling.
- Compile to `.air`, create a staged `.metallib`, validate both files are non-empty, and atomically move the staged file into the final output path.
- Clean temporary `.air` and staged files on every exit path.
- Shell-quote generated paths.

Additional focused fixes normalized Anthropic stream errors, made the Palmier-managed reserved-field test construct a valid managed profile, and used stable second-precision dates in the provider repository round-trip test.

Relevant files:

- `Plugins/MetalCIKernelPlugin/MetalCIKernelPlugin.swift`
- `Sources/PalmierPro/Agent/Clients/Codecs/AnthropicCodec.swift`
- `Tests/PalmierProTests/AIProviders/AIProviderCoreTests.swift`

## Automated validation

Completed validation:

- Focused regression selection: 6 tests passed.
- `swift build`: passed.
- Full `swift test`: 1,199 tests in 183 suites passed with zero failures.
- Metal resources: 11 generated `.metallib` files, all non-empty.
- `git diff --check`: passed.

The build still reports non-blocking linker warnings because some Convex/BoringSSL objects were built for macOS 26.2 while the current link target is macOS 26.0.

Automated tests use no production provider credentials. Real Anthropic, OpenAI, fal, compatible-gateway, and Palmier-managed connectivity still requires manual testing with valid configuration.

## Runnable test application

A local debug application bundle is available at:

```text
.build/PalmierPro.app
```

Launch it from the project root with:

```bash
open .build/PalmierPro.app
```

The bundle is ad-hoc signed, its `Info.plist` passes validation, and it contains all 11 non-empty Core Image Metal libraries. Its assembled size is 121,540,280 bytes.

This particular trial bundle was assembled from the normal debug build without the `BundledSpeech` trait. The active Apple Swift 6.2.3 toolchain cannot resolve `mlx-swift 0.31.5` because that dependency now declares Swift tools 6.3. Agent BYOK, generation BYOK, editing, Metal effects, and the rest of the normal debug application are present; bundled local speech, VAD, and MLX-dependent features are not included.

No `.env` backend configuration was present when the bundle was assembled. Palmier-managed account and backend features may therefore be unavailable, while BYOK profiles can still be configured under **Settings > AI Providers**.

## Suggested manual smoke test

1. Open `.build/PalmierPro.app` and create or open a disposable project.
2. Open **Settings > AI Providers** and add a provider without placing secrets in project files.
3. Test the connection and confirm the provider and model appear in the Agent panel.
4. Send a short Agent prompt and verify streaming text and tool behavior.
5. If the profile supports generation, confirm its models appear with the provider name and run a small generation request.
6. Quit and reopen the app to verify provider metadata persists and credentials remain available through Keychain.
7. Exercise one Metal-based effect and confirm rendering succeeds.
