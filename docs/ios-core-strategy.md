# iOS Core Strategy

Affective does not need a complete second implementation for iOS, but it does need a clean split between portable brain logic and platform-specific host runtime. The current prototype in `/Users/zelda/Documents/AffectiveCore` is close to this conceptually, but its executable shape is Mac/Linux oriented: it launches local processes, reads environment variables, shells out for sensors, and speaks over stdio MCP.

iOS cannot launch and supervise a local stdio helper process the way macOS can. The shared part must therefore be a library, a Swift package, a network service, or a shared protocol and data format.

## Core Idea

Use one brain model with many bodies.

```text
Portable Brain Core
  memory model
  graph and recall
  appraisal and emotion
  needs
  command schemas
  prompt construction
  provider routing abstractions
  brain import/export

Host Runtime
  camera and microphone capture
  battery and storage sensing
  provider token storage
  notifications
  background execution
  local files
  process/service lifecycle
  networking and pairing
```

The portable brain should be shared as much as possible. The host runtime should be different on macOS and iOS because Apple's permission, backgrounding, filesystem, and process models are different.

## What Can Be Shared

- Brain data schema and migration logic.
- Memory, relationship graph, appraisals, impressions, needs, and attention policy.
- Command and observation schemas.
- Prompt-building rules and capability gating.
- Provider routing model, without embedding provider secrets.
- Brain export/import container format.
- Tests for memory, recall, command planning, and appraisals.

## What Must Be Platform-Specific

- Camera permissions and capture through AVFoundation.
- Microphone permissions and recording through AVFoundation or Speech.
- Battery/power sensing through iOS/macOS-specific APIs.
- Keychain access and provider-token lifecycle.
- Background execution and notification behavior.
- Local path management and app sandbox details.
- Companion relay, local network pairing, and iCloud transport.
- Process supervision on macOS.

## Options

### Option 1: Shared Swift Package Core

Port the portable brain into `AffectiveKit`, a Swift package or shared app module used by both macOS and iOS.

```text
Affective macOS
  -> AffectiveKit
     -> BrainCore
     -> Apple runtime adapters

Affective iOS
  -> AffectiveKit
     -> BrainCore
     -> Apple runtime adapters
```

Pros:

- Best fit for SwiftUI, SwiftData, Keychain, AVFoundation, and Apple lifecycle.
- Easiest iOS integration.
- One language for app and shared core.
- Strong tooling for app state and async UI.

Cons:

- Requires porting substantial Zig prototype logic.
- Risk of drifting from the proven prototype unless tests move with the port.
- Less portable to non-Apple devices unless the core is carefully isolated.

Use this if Affective is primarily an Apple-platform product.

### Option 2: Shared Zig Core Embedded As A Library

Keep the brain in Zig, but reshape it from executable-first code into a library with a C ABI that Swift can call.

```text
Affective iOS/macOS app
  -> Swift host runtime
  -> C ABI bridge
  -> Zig BrainCore library
```

Pros:

- Preserves the existing implementation.
- Keeps non-Apple portability.
- Lets command-line, Mac, iOS, and future hardware bodies share one core.

Cons:

- Requires removing executable assumptions from the core.
- No subprocesses, shell commands, arbitrary env-var reliance, or CLI-only tools in shared code.
- C ABI and memory ownership must be designed carefully.
- iOS builds must use only App Store-compatible libraries and APIs.

Use this if the Zig brain is expected to remain the durable core across Apple and non-Apple bodies.

Current foothold:

- AffectiveCore now has `src/affective_core_embedded.zig`, a C ABI entrypoint for Affective.
- `zig build embedded` builds `libaffective-core-embedded.a`.
- The ABI currently supports local runtime create/destroy plus the embedded API v2 dispatch, drain, and introspection JSON routes. Affective sends typed text, touch, poke, and tool events through the v2 envelope.
- Affective has a `BrainCore` wrapper that creates the Zig handle from a selected brain's local paths and routes brain actions through that embedded ABI.
- Affective has an iOS-only Xcode build phase that runs `scripts/build_affective_core.sh`, compiling the Zig library into DerivedData for `iphoneos` and `iphonesimulator`.
- Affective links the embedded Zig library and `sqlite3` only for iOS SDKs. macOS remains on the `affective-core-mcp` process bridge.

This is not yet a complete iOS product runtime, but it is now a linked local core path. The next gap is functional device smoke testing and replacing host-dependent capabilities with Apple adapters or honest unavailable responses.

### Option 3: Local iOS Core With Optional Mac Peer

Keep the brain local on iOS, with the Mac available as an optional peer for sync, backup, or richer long-running work. The iOS app must not require an Affective remote server.

```text
iPhone Affective
  -> embedded local core
  -> local brain storage
  -> optional local/iCloud user-approved sync with Mac Affective
```

Pros:

- Satisfies the no Affective remote server requirement.
- Lets iPhone open, converse, remember, recall, and inspect a brain when the Mac is absent.
- Mac can still help with long-running autonomy, larger models, and backup when present.
- Keeps user memory local-first.

Cons:

- Requires embedded-core or porting work earlier.
- Requires merge/sync rules when the same brain changes on iOS and Mac.
- Privacy and encryption need careful attention.

Use this because offline iOS is a product requirement.

### Option 4: Cloud Or Personal Server Core

Run the brain on a server controlled by the user or by Affective infrastructure. iOS and macOS both become clients.

Pros:

- Simple app clients.
- Works across devices without requiring the Mac to be awake.
- Easier push notifications and background jobs.

Cons:

- Highest privacy burden.
- Requires authentication, encryption, account recovery, hosting, monitoring, and sync.
- Conflicts with Affective's local, embodied, memory-sensitive spirit unless designed very carefully.

Do not use this for Affective's primary iOS architecture. It can remain an optional user-owned deployment idea, but Affective should not require an Affective remote server.

## Recommended Path

Start with a local iOS core requirement and design toward either Option 1 or Option 2.

Phase 1:

- macOS app launches or connects to the existing Zig core.
- iOS app uses the same typed brain contract, backed by the embedded Zig target for typed conversation, introspection, and current Affective live tools.
- Shared contracts are command schemas, observation schemas, provider account metadata, and brain export format.

Phase 2:

- Extract a platform-neutral `BrainCore` boundary.
- Remove env-var, process, shell-command, and hardcoded path assumptions from portable brain logic.
- Add host-supplied capability and credential providers.
- Build tests around the shared brain contract.

Phase 3:

- Continue with the embedded Zig path unless product needs force a Swift core port.
- Keep compiling the Zig core as an iOS-compatible static library.
- Run device-level smoke tests for open brain, conversation, memory, recall, reminders, disconnect, and reconnect.
- Keep iOS local brain storage and local core execution independent of any Affective remote server.

Phase 4:

- Add local offline iOS brain features.
- Sync or merge brain data with the Mac host.
- Keep host secrets and device permissions out of brain exports.

## Data And Secret Boundary

Brain files may move between devices. Host credentials should not.

Brain export may include:

- memories
- relationship graph
- appraisals and impressions
- seed orientation
- promoted captures and generated artifacts
- brain-specific runtime preferences

Brain export must not include:

- OpenAI, Anthropic, Google, or other provider tokens
- OAuth refresh tokens
- SMTP credentials
- local device identifiers
- permission grants
- absolute local paths that only make sense on one host
- local network pairing secrets

Each device should reestablish its own provider accounts and OS permissions.

## iOS Runtime Notes

iOS can provide:

- camera and microphone capture
- speech recognition or audio recording
- battery level and charging state
- notifications and reminders
- Keychain storage
- local encrypted files
- limited background tasks
- local network communication with user consent

iOS cannot provide:

- arbitrary long-running background autonomy
- launching and supervising a bundled stdio helper process like macOS
- unrestricted filesystem access
- shelling out to tools like `ffmpeg`, `pmset`, or `whisper-cli`

This means the current `affective-core-mcp` executable should be viewed as a macOS bridge, not an iOS integration strategy.

## Practical Design Rule

When adding core behavior, ask:

- Does this code depend on a sensor, permission, filesystem path, provider credential, subprocess, or background policy?
- If yes, it belongs in the host runtime or behind a host capability protocol.
- If no, it may belong in the portable brain core.

That rule keeps Affective from becoming two separate products. The brain can stay continuous while each body remains honest about what it can actually sense and do.
