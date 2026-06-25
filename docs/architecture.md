# Affective Architecture

Affective is the Apple frontend and host shell for affective memory-based intelligence. The prototype in `/Users/zelda/Documents/AffectiveCore` already has the right conceptual split: a portable core brain with explicit capabilities, plus platform bodies that fulfill those capabilities through cameras, microphones, power sensors, storage, speech, and provider APIs.

The Affective app should keep that split. The Apple app owns identity, consent, permissions, provider tokens, and device integration. The brain owns memory, appraisal, needs, attention, conversation command planning, and durable brain export/import.

## Goals

- Run as a first-class SwiftUI app on macOS and iOS.
- Keep the intelligence core mostly portable and testable outside Apple UI.
- Treat webcam, microphone, battery, storage, speech, notifications, and provider calls as explicit capabilities.
- Give each AI provider a clean sign-in or token setup flow, stored securely per host, not inside exported brain files.
- Preserve the prototype's brain container idea: memories and affective state move with the brain; host credentials and device permissions stay with the device.

## Proposed Shape

```text
Affective SwiftUI app
  -> AppModel / feature view models
  -> AffectiveKit Swift package
     -> BrainClient protocol
     -> ProviderAccountStore
     -> PermissionCoordinator
     -> DeviceSenses
     -> MediaCapture
     -> SpeechIO
  -> Transport
     -> macOS: local core process or native library bridge
     -> iOS: network relay or embedded portable core
  -> Core Brain
     -> memory, graph, appraisals, needs, autonomy, command execution
```

The user-facing app should not call provider SDKs or OS sensors directly from views. Views talk to observable models; models talk to AffectiveKit services; services expose capability status and structured observations to the brain.

## Layers

### 1. SwiftUI Shell

The app target should contain only platform UI, navigation, presentation state, and small view models. Shared views can be kept cross-platform with conditional affordances where needed.

Initial areas:

- Home: current inner state, attention, recent memory, active conversation.
- Conversation: text and voice interaction with visible sensing state.
- Memory: recall, pin, forget, inspect, export, import.
- Providers: connect OpenAI, Anthropic, Google/Gemini, local models later.
- Permissions: camera, microphone, speech, notifications, local network, background behavior.
- Device: power, storage, camera/mic availability, current host capabilities.

### 2. AffectiveKit

Create a shared Swift package or app module that hides transport and platform APIs behind protocols.

Core protocols:

```swift
protocol BrainClient {
    func call(_ command: BrainCommand) async throws -> BrainObservation
    func streamConversation(_ input: ConversationInput) -> AsyncThrowingStream<BrainEvent, Error>
}

protocol ProviderCredentialStore {
    func status(for provider: AIProvider) async -> ProviderConnectionStatus
    func saveToken(_ token: ProviderToken, for provider: AIProvider) async throws
    func deleteToken(for provider: AIProvider) async throws
}

protocol DeviceSenses {
    func snapshot() async -> DeviceSenseSnapshot
}

protocol MediaCapture {
    func captureStillImage() async throws -> CapturedImage
    func recordAudio(until stop: AsyncStream<Void>) async throws -> CapturedAudio
}
```

The exact types can evolve, but the direction matters: every external capability has a typed boundary, a permission state, and an unavailable/error state.

### 3. Core Brain

The AffectiveCore Zig core should be treated as the starting point for Affective's Core Brain.

Keep or port:

- `src/core/bot.zig`: command-driven cognition loop.
- `src/core/person_memory.zig`, `src/storage/*`, `src/core/vector_index.zig`: memory and graph model.
- `src/core/emotion.zig`, `src/core/needs.zig`, `src/core/psyche.zig`: affective/appraisal layer.
- `src/api/chat_client.zig`: command schema and capability gating.
- brain export/import container, minus host credentials.

Change over time:

- Replace environment-variable provider keys with host-supplied credential handles.
- Replace shell-command macOS sensors with Apple-native sensors in the app host where possible.
- Move MCP from "debug/admin surface" to one possible transport, not the only app integration.

## Transport Options

### Phase 1: macOS local process

Use the existing `affective-core-mcp` style for fast progress. The macOS app launches a local core process over stdio and calls tools. This is already proven in `AffectiveCore/apple/AffectiveCore`.

Pros:

- Fastest migration.
- Keeps Zig core intact.
- Easy to debug with command-line tools and tests.

Limits:

- macOS only.
- Harder to stream rich media.
- Provider tokens must be passed carefully to the process.

### Phase 2: local HTTP or XPC bridge on macOS

Move from stdio MCP to a local host service with a typed API. This can still be backed by Zig.

Use this for:

- Streaming conversation events.
- Passing image/audio files by secure local URLs.
- Long-lived background autonomy.
- Cleaner crash/restart handling.

### Phase 3: iOS bridge

iOS cannot launch the Zig stdio server, and Affective must not require an Affective remote server. Pick a local-first path:

- Embedded core: compile a portable subset of the core into an iOS-compatible library.
- Shared Swift core: port the portable brain model into AffectiveKit.
- Optional Mac peer: sync or hand off with the user's Mac over local network/iCloud/Bonjour after local iOS operation works.

Recommended path: build the typed contract now, then make iOS local-first. The Mac can remain a trusted peer for richer autonomy, backup, and sync, but the iPhone must be able to open a local brain, converse, remember, recall, and inspect state without the Mac or an Affective-hosted service.

## Provider Sign-In And Tokens

Provider credentials should belong to the host device/account, not to a brain.

Store:

- API keys and OAuth tokens in Keychain.
- Non-secret provider preferences in SwiftData or app settings.
- Token provenance and last health check in local app state.
- No provider secrets in brain exports.

Provider setup should support two styles:

- API key paste flow for providers that do not offer appropriate consumer OAuth.
- OAuth/App token flow where provider terms and APIs allow it.

Proposed provider account model:

```text
ProviderAccount
  id
  provider: openai | anthropic | google | local
  displayName
  authKind: apiKey | oauth | local
  keychainReference
  allowedCapabilities: text, vision, audio, imageGeneration, embeddings
  defaultModels
  healthStatus
  createdAt
  lastUsedAt
```

The core brain should receive a provider route and a short-lived credential resolution from the host, not read `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` directly. For the first migration, the macOS app can launch the local process with sanitized environment variables assembled from Keychain, but that should be considered a bridge, not the final shape.

## Permissions And Device Capabilities

Apple permissions are part of the body, not the mind. Affective should model them explicitly and show what is available.

Capabilities:

- Camera: `AVCaptureDevice` authorization and still/video capture.
- Microphone: `AVAudioSession` on iOS, `AVCaptureDevice`/audio capture on macOS.
- Speech recognition or local transcription: Apple Speech framework, local Whisper, or provider audio.
- Battery/power: `ProcessInfo`, IOKit on macOS if needed, `UIDevice` on iOS.
- Storage: file system capacity and brain database size.
- Notifications: reminders and autonomy nudges.
- Background execution: limited on iOS, richer on macOS.
- Local network: only if optional Mac peer sync is enabled.

Each capability should expose:

- authorization status
- runtime availability
- last successful observation
- failure reason
- whether the brain may request it autonomously

This matches the prototype's `commandUnavailableReason` behavior and keeps the UI honest.

## Memory And Data Ownership

Use three data zones:

```text
Brain data
  memories, graph, events, appraisals, needs, captures promoted into memory,
  generated artifacts, seed orientation, brain runtime options

Host data
  provider tokens, OS permission grants, device identifiers, local paths,
  notification settings, local network pairing, UI preferences

Transient data
  raw camera frames, scratch audio, temporary transcriptions,
  failed captures, streaming chunks
```

Brain exports include only brain data. Host data is recreated on each device. Transient data is purged aggressively unless promoted by the brain.

For the Apple app:

- Use SwiftData for app metadata, accounts, UI preferences, and host records.
- Keep the core brain's SQLite/JSON stores under Application Support.
- Use Keychain for secrets.
- Use App Group containers only if adding extensions or companion helpers.

## Suggested Repository Layout

```text
Affective/
  App/
    AffectiveApp.swift
    Navigation/
    Features/
  AffectiveKit/
    Brain/
    Providers/
    Permissions/
    Device/
    Media/
    Storage/
  CoreBridge/
    MCP/
    LocalHTTP/
    ProcessSupervisor/
  Resources/
docs/
  architecture.md
```

The existing Xcode project uses a file-system synchronized group for `Affective/`, so adding real folders under `Affective/` should work cleanly.

## Migration Plan

1. Replace the starter SwiftData item UI with an Affective dashboard shell.
2. Add AffectiveKit protocols and stub implementations.
3. Port the `AffectiveCore/apple/AffectiveCore` MCP client into `CoreBridge/MCP`.
4. Add a macOS-only local process supervisor for `affective-core-mcp`.
5. Add provider settings backed by Keychain, initially launching the core process with env vars.
6. Add permission and capability dashboards for camera, mic, power, storage, speech, and notifications.
7. Add text conversation and memory screens against the existing MCP tools.
8. Add media capture on the Apple side and pass captured files to core commands.
9. Promote the transport to local HTTP/XPC if streaming and lifecycle needs outgrow stdio.
10. Add an embedded/local iOS brain client once the typed brain contract is stable.
11. Add optional Mac peer sync after local iOS operation works.

## Open Decisions

- Should the durable core remain Zig long-term, or should part of it move into Swift for tighter Apple integration?
- Should the local iOS core be embedded Zig, a Swift port, or a smaller Swift subset that syncs with the Zig core?
- Should provider calls happen inside the core, or should the Swift host act as the provider broker and return model responses to the core?
- How much autonomy should be allowed on iOS given background execution limits?
- Which data should be end-to-end encrypted when syncing or relaying between devices?

## Recommendation

Start with a macOS host-first architecture:

- SwiftUI app for consent, accounts, device capabilities, and interaction.
- Zig core as a supervised local process.
- MCP retained for admin/debug tools and early app calls.
- Keychain-backed provider credentials injected by the host.
- Explicit capability model shared between UI and core.
- iOS local-first as a requirement: no Affective remote server dependency, with optional Mac peer sync later.

That gives Affective a working body quickly while preserving the prototype's strongest idea: a memory-bearing mind that asks its body for situated observations, rather than a UI that casually leaks sensors and provider calls all over the codebase.
