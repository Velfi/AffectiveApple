# Affective and AffectiveCore Communication Design

Affective should treat AffectiveCore as the durable brain core and Affective as the Apple host/body. The integration should not make SwiftUI views speak raw MCP, and it should not make Zig know about SwiftUI. Both codebases need a shared product protocol in the middle.

The current macOS path can keep using the `affective-core-mcp` stdio process, but that should be one transport adapter under a typed `BrainClient`, not the architecture itself. This is especially important because the iOS version cannot launch or supervise a local stdio helper process.

iOS must work without an Affective remote server. A Mac peer can be useful for handoff, backup, or richer long-running autonomy, but it cannot be required for the iOS app to have a local brain.

## Current Shape

Affective currently has:

- `BrainClient` in `Affective/CoreBridge/BrainClient.swift`.
- `AffectiveCoreMCPBridge` in `Affective/CoreBridge/MCP/AffectiveCoreMCPBridge.swift`.
- `BrainLibrary` in `Affective/BrainLibrary.swift`, which discovers brain folders under `~/Library/Application Support/AffectiveCore/brains`.
- `AffectiveViewModel` in `Affective/AffectiveViewModel.swift`, which talks to AffectiveCore through typed `BrainCore` operations rather than raw tool names.

AffectiveCore currently has:

- `BrainRuntime` and `AppCore` in `src/app/brain.zig`.
- The headless MCP wrapper in `src/main_mcp.zig`.
- The event-sourced conversation path and action-pressure executor in `src/core/brain_action_execution.zig`, `src/core/action_selection.zig`, and the subsystem modules.
- Shared capability schemas in `src/core/capabilities.zig`, `src/core/capability_registry.zig`, and `src/api/chat_client.zig`.
- Brain archive/import/export logic in `src/app/brain_container.zig`.
- A separate Apple MCP dashboard in `apple/AffectiveCore`, duplicating some Swift MCP client logic now present in Affective.

Affective product chat uses the typed `conversation_turn` operation. LanguageMind can propose text and action pressures, but final execution is selected through the action-pressure pipeline and capability executor.

## Design Principle

Use one brain protocol with multiple transports.

```text
Affective SwiftUI
  -> AffectiveKit view models
  -> BrainClient typed protocol
  -> BrainTransport
      macOS current: MCP stdio process
      macOS next: local HTTP or XPC service
      iOS current: embedded API v2 local core
      iOS optional: encrypted local peer sync with Mac Affective
  -> AffectiveCore BrainRuntime/AppCore
```

The stable contract should be Affective brain operations and events. MCP, HTTP, XPC, relay, and embedded C ABI are implementation details.

## Ownership Boundary

Affective owns:

- UI and app state.
- Brain selection and recent brains.
- OS permissions and consent.
- Camera, microphone, notifications, local network, and background policy.
- Provider account setup and host credential storage.
- Pairing and relay trust for iOS.
- Process lifecycle on macOS.

AffectiveCore owns:

- Memory records, conversation summaries, appraisals, impressions, needs, graph, reminders, dreams, and command planning.
- Brain import/export format.
- Skill/command definitions and capability gating.
- Prompt construction and conversation command execution.
- Portable brain tests.

Shared contract owns:

- Typed commands and responses.
- Event stream semantics.
- Brain manifest/schema versions.
- Capability and permission status shape.
- Error model.

## Brain Operation Model

Replace UI-level raw tool calls with a typed operation enum in Swift and matching Zig dispatch layer.

```swift
enum BrainOperation: Codable, Sendable {
    case connect(BrainOpenRequest)
    case hostAttach(HostBindingRequest)
    case hostCapabilityManifest(HostCapabilityManifestRequest)
    case sendExperienceEvent(ExperienceEventRequest)
    case conversationTurn(ConversationTurnRequest)
    case requestDreamTime(DreamTimeRequest)
    case brainMode
    case readModelsSnapshot
    case mailboxList(MailboxListRequest)
    case mailboxMarkRead(MailboxMarkReadRequest)
    case capabilityStatus(CapabilityStatusRequest)
    case importBrain(BrainImportRequest)
    case exportBrain(BrainExportRequest)
}
```

The Swift UI should call typed `BrainCore` operations. Memory, recognition, graph work, reminders, speech, dreams, and mailbox delivery are modeled as experience events and capability requests, not ad hoc UI calls to raw tools.

For the current macOS bridge, `AffectiveCoreMCPBridge` is only a transport adapter. Swift product code should not parse command text or depend on MCP tool names.

## Required New AffectiveCore Operations

### `conversation_turn`

This is the highest priority change in AffectiveCore. It should call the same internal logic as `handleConversationText`, but receive host-supplied input instead of asking `deps.input`.

Request:

```json
{
  "brain_id": "default",
  "turn_id": "uuid",
  "input": {
    "kind": "text",
    "text": "Hello",
    "source": "typed | speech | relay",
    "attachments": [
      {
        "kind": "image | audio | video | file",
        "path": "/host/accessible/path",
        "mime_type": "image/jpeg",
        "caption": "optional host note"
      }
    ]
  },
  "host_context": {
    "client_id": "macbook-pro | iphone",
    "frontend": "macos | ios",
    "local_time": "2026-06-24T08:00:00-05:00",
    "capabilities": ["text_input", "uploaded_media_read", "speech_output"]
  }
}
```

Response:

```json
{
  "turn_id": "uuid",
  "spoken_text": "What the bot said, if any.",
  "observations": "bounded readable trace",
  "summary": {
    "user": "stored user summary",
    "bot": "stored bot summary"
  },
  "commands": [
    {
      "name": "say",
      "status": "completed",
      "observation": "..."
    }
  ],
  "state_delta": {
    "memory_changed": true,
    "reminders_changed": false,
    "graph_changed": false
  }
}
```

Implementation guidance:

- Extract `Bot.handleConversationText` into a public-ish `handleConversationInput(input_mod.HeardSpeech, ConversationHostContext)` or `BrainRuntime.conversationTurn`.
- Preserve existing memory/appraisal/summary behavior.
- Return structured event batches plus display directives, not stdout or a single observation string.
- Keep prompt inspection and other diagnostics outside the product runtime path.

### `brain_manifest`

Affective needs a safe, typed description of a brain for the welcome screen and iOS relay.

Response:

```json
{
  "brain_id": "default",
  "display_name": "Default",
  "format_version": 1,
  "component_count": 8,
  "total_bytes": 123456,
  "avatar": {
    "path": "avatar.png",
    "mime_type": "image/png"
  },
  "capabilities": {
    "conversation": "available",
    "memory": "available",
    "graph": "available",
    "speech_output": "host_required",
    "camera": "host_required"
  }
}
```

This can be built from `brain_container.inspectBrain` plus Affective metadata.

### `runtime_options_get` and `runtime_options_update`

Affective currently writes `runtime_options.json` directly. The healthier contract is:

- Affective sends a patch.
- AffectiveCore validates known fields.
- AffectiveCore reports which fields apply immediately and which need restart.

This avoids Swift duplicating Zig config rules.

## Event Model

Longer term, conversation should stream events. Even before full streaming, shape results as event-like records so UI and logs do not diverge.

```swift
enum BrainEvent: Codable, Sendable {
    case lifecycle(BrainLifecycleEvent)
    case commandStarted(CommandEvent)
    case commandFinished(CommandEvent)
    case observation(ObservationEvent)
    case message(BrainMessageEvent)
    case memoryChanged(MemoryChangedEvent)
    case reminderChanged(ReminderChangedEvent)
    case error(BrainErrorEvent)
}
```

Examples:

- `lifecycle`: connecting, connected, disconnected, restarting.
- `message`: user text accepted, bot text emitted.
- `commandStarted`: capability request accepted, with capability id and causal event ids.
- `commandFinished`: capability request completed, failed, refused, or unavailable, with outcome events.
- `memoryChanged`: created memory id, recalled memory id, promoted memory.
- `error`: provider unavailable, missing permission, bridge disconnected.

MCP stdio can return a batch of events in the tool result. Local HTTP/XPC can stream them. iOS relay can forward them.

## Transport Strategy

### macOS Current: MCP stdio

Keep the current Affective path:

```text
Affective -> AffectiveCoreMCPBridge -> affective-core-mcp -> BrainRuntime
```

Changes:

- `AffectiveCoreMCPBridge` should be only a transport adapter; product state should flow through typed operations and event batches.
- Add a typed adapter from `BrainOperation` to MCP.
- Add process supervision: exit detection, restart, timeout, and single-flight request handling.
- Add `tools/list` verification during connect and expose unsupported tools as capability errors.
- Add `conversation_turn` to `src/main_mcp.zig`.

### macOS Next: local service

Move to local HTTP or XPC when stdio becomes too cramped.

Use it for:

- Streaming events.
- File upload references.
- Better crash/restart semantics.
- Multiple clients, including iOS relay.
- Background autonomy service.

Recommended route:

```text
Affective macOS app
  -> LocalBrainServiceClient
  -> localhost/Unix-domain local service
  -> AffectiveCore BrainRuntime
```

XPC is Apple-native and secure but macOS-specific. Local HTTP is easier to share with iOS relay and command-line diagnostics. Either is acceptable if the typed JSON contract is shared.

### iOS Current: embedded API v2 local core

iOS should not try to launch `affective-core-mcp`, and it should not depend on an Affective remote server. The iOS app needs a local brain runtime inside the app process.

Recommended iOS path:

```text
Affective iOS
  -> EmbeddedBrainClient
  -> Swift/C ABI bridge
  -> affective-core-embedded static library
  -> Zig BrainRuntime
  -> local iOS brain storage
```

iOS can provide input and sensors:

- typed text
- speech transcript
- captured image/audio as uploaded attachments
- battery/charging state
- notification interactions

This does not mean every AffectiveCore feature must be present on iOS on day one. The iOS local core can start with typed conversation, memory, appraisals, graph, reminders, brain import/export, and local attachments. Capabilities that need subprocesses or long-running background work should be unavailable or delegated to host-provided Apple APIs.

Current implementation:

- `AffectiveCore/src/affective_core_embedded.zig` exports the first C ABI surface.
- `zig build embedded` builds `libaffective-core-embedded.a`.
- The exported ABI can create/destroy a local brain runtime and run embedded API v2 typed operation dispatch plus event draining.
- `Affective/Core/BrainCore.swift` has the Swift wrapper for that ABI.
- `Affective.xcodeproj` now has an iOS-only build phase that runs `scripts/build_affective_core.sh`.
- The build script compiles the Zig static library for `iphoneos` and `iphonesimulator` into DerivedData, including fat simulator archives when needed.
- Affective links `libaffective-core-embedded.a` and `sqlite3` only for iOS SDKs. macOS continues to use the MCP stdio bridge.

Remaining iOS integration work:

- Run on-device functional smoke tests for open brain, conversation, memory, recall, and reminders.
- Continue expanding the ABI as Affective needs more host-facing brain operations.
- Replace any remaining subprocess-backed capabilities with Apple host adapters or explicit unavailable capability responses.
- Move provider credentials into Keychain-backed host resolution instead of brain/runtime environment reads.

### iOS optional: Mac peer

The Mac can still be a peer, not a required server.

```text
Affective iOS local brain
  <-> encrypted local network / iCloud document sync / user-approved transfer
Affective macOS local brain
```

Use the Mac peer for:

- importing/exporting brains
- copying memories and graph changes
- running richer autonomy while the Mac is awake
- provider-heavy or model-heavy work when the user explicitly routes it there
- backup and restore

The iPhone must still open, converse, remember, recall, and inspect its local brain when the Mac is absent.

### Embedded core requirements

AffectiveCore now has the first iOS-compatible Zig-library shape through `src/affective_core_embedded.zig`. The Zig route preserves the existing implementation better, but it must keep moving away from executable assumptions.

Requirements:

- No subprocesses in the portable core.
- No environment-variable credential reads.
- No hardcoded Mac paths.
- Host-provided filesystem roots.
- Host-provided provider, media, speech, and notification adapters.
- Clear memory ownership across C ABI.

This is no longer a later nice-to-have; it is required for iOS if the product guarantee is no Affective remote server.

## Shared Swift Package

Create an `AffectiveKit` Swift package/module used by Affective macOS and iOS. It should contain:

- `BrainClient` typed protocol.
- `BrainOperation`, request, response, and event types.
- `BrainTransport` protocol.
- `MCPTransport` implementation for macOS only.
- `RelayTransport` interface for iOS companion mode.
- `EmbeddedBrainTransport` for iOS local core.
- JSON value utilities if still needed.
- Provider account and capability models.

This prevents Affective and `AffectiveCore/apple/AffectiveCore` from keeping separate MCP clients forever.

Suggested replacement:

```text
AffectiveCore/apple/AffectiveCore
  -> depends on AffectiveKit or a small AffectiveCoreAppleClient package
Affective
  -> depends on the same package
```

If keeping a separate package is too heavy right now, move the duplicated Swift MCP code into one folder in Affective and treat `AffectiveCore/apple/AffectiveCore` as deprecated.

## Brain Storage and Export

Use one canonical brain folder layout:

```text
~/Library/Application Support/AffectiveCore/brains/{brain_id}/
  brain.sqlite
  artifacts/
  captures/
  generated/
  metadata.json
```

Affective can keep reading manifest metadata directly for fast welcome-screen discovery, but cognitive state belongs behind AffectiveCore APIs and import/export should use AffectiveCore's `brain_container` format, not raw folder copies.

Migration:

1. Affective folder import/export remains available.
2. Add `.friendlybrain` import/export through AffectiveCore `exportBrain` and `importBrain`.
3. Prefer `.friendlybrain` for iOS relay/sync because it has a manifest and version.

Brain exports may include memory, graph, appraisals, events, selected captures, generated artifacts, and brain preferences.

Brain exports must not include provider tokens, local network pairing secrets, permission grants, host device ids, or absolute host-only paths.

## Provider and Secret Boundary

Provider credentials should move out of AffectiveCore environment reads and into host resolution.

Short-term macOS bridge:

- Affective stores provider tokens in Keychain.
- Affective launches `affective-core-mcp` with a sanitized temporary environment.
- AffectiveCore still reads provider env vars.

Target:

- AffectiveCore asks a host provider broker for model completion/image/audio work.
- The brain receives results, not raw long-lived secrets.
- iOS and macOS each maintain their own Keychain credentials.
- If the device has no network, provider-backed skills report unavailable and the local brain still supports memory, recall, appraisals, graph, reminders, and any bundled/local model features.

This keeps brain archives portable and safe.

## Capability Contract

Both sides should speak explicit capabilities:

```json
{
  "text_input": "available",
  "speech_input": "available | denied | unavailable",
  "speech_output": "available | unavailable",
  "camera": "available | denied | unavailable",
  "uploaded_media_read": "available",
  "audio_transcription": "available | unavailable",
  "local_notifications": "available | denied",
  "background_autonomy": "limited | available | unavailable",
  "provider_text": "available | missing_credentials | degraded"
}
```

AffectiveCore already has capability gating through skills. Affective should surface host capability state and pass it to the core. The core should decide what commands are callable from capabilities, not from UI assumptions.

## Error Contract

Normalize bridge errors:

```json
{
  "code": "missing_binary | disconnected | unknown_operation | missing_permission | missing_credentials | invalid_request | provider_failure | internal",
  "message": "human readable",
  "recoverability": "retry | reconnect | configure | unsupported",
  "details": {}
}
```

Affective should use this to decide whether to show:

- run `zig build mcp`
- reconnect
- open provider settings
- request permission
- disable unsupported iOS feature

## Concrete Changes by Repo

### AffectiveCore

1. `BrainRuntime.conversationTurn` now routes through `Bot.handleConversationText`.
2. `conversation_turn` is available over MCP.
3. `src/affective_core_embedded.zig` exposes the embedded C ABI for iOS-local Affective.
4. The embedded ABI supports typed operation dispatch.
5. Add richer structured JSON envelopes for product operations.
6. Add `runtime_options_get` and `runtime_options_update`.
7. Add `brain_manifest`.
8. Keep adding tests that product conversation mutates memory/summaries while debug prompt inspection does not.
9. Keep `AppCore` as the boundary for future HTTP/XPC/C ABI transports.
10. Move duplicated Apple MCP client code toward shared AffectiveKit or deprecation.

### Affective

1. Affective chat now uses `BrainClient.sendText`, backed by MCP `conversation_turn` on macOS and the embedded ABI on iOS.
2. MCP process ownership and framing stay inside `AffectiveCoreMCPBridge`, which is macOS-only.
3. `EmbeddedBrainClient` is the iOS path and calls the Zig static library in-process.
4. The Xcode target builds and links the embedded Zig core for iOS simulator and device SDKs.
5. Keep view-model communication on typed `BrainCore` operations.
6. Add response decoders for memory, reminders, attention, state, and conversation.
7. Add provider account model and Keychain-backed store.
8. Add a capability/permission model shared between macOS and iOS UI.
9. Switch import/export to AffectiveCore brain archive when available.
10. Keep diagnostics outside the primary product runtime path.
11. Add optional peer sync with Mac Affective after local iOS brain operations work.

## Phased Roadmap

### Phase 0: Stabilize current macOS bridge

- Keep stdio MCP.
- Add process supervision and timeouts.
- Verify tools on connect.
- Keep UI usable when disconnected.

### Phase 1: Real conversation

- Add `conversation_turn` to AffectiveCore.
- Keep Affective typed chat on real mutating conversation.
- Return command/event batches to Affective logs.

### Phase 2: Typed AffectiveKit contract

- Add typed Swift operations/events.
- Decode JSON responses instead of displaying raw strings everywhere.
- Hide raw MCP from view models.

### Phase 3: Offline iOS

- Build and link the embedded iOS brain client.
- Store brain data locally in the app container.
- Support typed conversation, memory, graph, reminders, and brain import/export without an Affective remote server.
- Gate provider, speech, camera, and background autonomy features through iOS host capabilities.
- Verify the linked core on real iOS hardware.

### Phase 4: Local peer sync and service improvements

- Promote macOS transport to local HTTP/XPC if needed.
- Add optional encrypted local peer sync between iOS and macOS.
- Add conflict/merge rules for memory, graph, reminders, and brain metadata.
- Keep Affective remote server out of the critical path.

## Recommended Immediate Next Step

Run the iOS build on a physical device and smoke-test the linked embedded core: open a brain, send typed text, remember something, recall it, set a reminder, list reminders, disconnect, and reconnect. That is the proof point that Affective can host AffectiveCore locally on iOS without an Affective remote server.

After that, extract Affective's Swift contract into typed operations and continue replacing host-dependent Zig behavior with explicit Apple host adapters. Mac peer sync should remain an optional enhancement rather than a dependency.
