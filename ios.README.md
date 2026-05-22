# iosHealthExport

iOS app that reads raw HealthKit samples and POSTs them in JSON batches to a fixed HTTP endpoint. No aggregation. No user configuration. Run it, watch it go, inspect the data on the other end.

---

## Contents

- [Purpose](#purpose)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Module reference](#module-reference)
- [Data types exported](#data-types-exported)
- [Export pipeline](#export-pipeline)
- [Error model](#error-model)
- [API contract](#api-contract)
- [State machine](#state-machine)
- [UI](#ui)
- [Tests](#tests)
- [Known limitations](#known-limitations)
- [Adding a new HealthKit type](#adding-a-new-healthkit-type)

---

## Purpose

The app exists to get raw HealthKit data off-device and into a backend for analysis. It is a foreground-only export tool — no background sync, no incremental anchoring (v1), no auth header management. The endpoint is hardcoded at compile time.

---

## Requirements

- Xcode 16+
- iOS 17+ deployment target (uses `@Observable`, `async`/`await`, Swift 6 default `@MainActor` isolation)
- Physical device for HealthKit access (simulator has no real data)
- HealthKit capability enabled in Signing & Capabilities

The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, meaning all types and functions are implicitly `@MainActor` unless explicitly annotated otherwise. `SWIFT_APPROACHABLE_CONCURRENCY = YES` is also set; this relaxes some strict concurrency requirements at ObjC/HealthKit call boundaries.

---

## Configuration

The endpoint URL lives in one place:

```swift
// iosHealthExport/AppConfig.swift
enum AppConfig {
    static let endpoint = EndpointConfiguration(
        url: URL(string: "https://trace.mnalavadi.org/ios-dump")!
    )
}
```

Change the URL string there. No other configuration exists — no timeout knob, no headers, no UserDefaults.

---

## Architecture

Single app target. No SPM packages. No third-party dependencies.

```
UI (SwiftUI)
  └── ExportViewModel          presentation layer; mirrors state machine
        └── ExportCoordinator  orchestration; owns the export Task
              ├── ExportStateMachine   single source of truth for all state
              ├── ErrorReporter        routes errors → state machine
              ├── HealthKitPermissionService
              ├── HealthKitSampleStreamer
              └── BatchUploader
```

**Dependency direction:** UI depends on ViewModel. ViewModel depends on Coordinator and StateMachine. Coordinator depends on service protocols. Services have no knowledge of UI or each other.

All objects are `@MainActor`. HealthKit query callbacks arrive on background threads but only call into `AsyncThrowingStream.Continuation`, which is thread-safe. The main actor is released at every `await` point, so the export loop does not block the UI.

---

## Module reference

```
iosHealthExport/
├── AppConfig.swift                  endpoint URL constant
├── iosHealthExportApp.swift         app entry point; wires all objects together
│
├── Domain/
│   ├── ExportState.swift            ExportState enum
│   ├── ExportError.swift            ExportError, ErrorCategory, ErrorSeverity
│   ├── ExportStateMachine.swift     @Observable state machine (single source of truth)
│   ├── ExportSummary.swift          completed-run summary struct
│   ├── TypeExportProgress.swift     per-type progress (status, fraction, counts)
│   ├── BannerStyle.swift            UI-agnostic banner state enum
│   ├── ErrorReporter.swift          centralised error routing
│   ├── ExportCoordinator.swift      export pipeline orchestration
│   └── FlatSample.swift             Codable sample struct + HKSample mapper
│
├── HealthKit/
│   ├── HealthKitTypeCatalog.swift   exported types and their HK identifiers/units
│   ├── HealthKitPermissionService.swift  authorization request
│   └── HealthKitSampleStreamer.swift     AsyncThrowingStream<FlatSample> factory
│
├── Networking/
│   ├── EndpointConfiguration.swift  URL wrapper struct
│   ├── HTTPResponseClassifier.swift status-code → NetworkFailure classification
│   └── BatchUploader.swift          URLSession POST with one immediate retry
│
└── Features/
    └── Export/
        ├── ExportViewModel.swift    @Observable view model
        ├── ExportView.swift         root view
        ├── StatusBannerView.swift   global status banner
        ├── TypeProgressView.swift   per-type progress row
        ├── ErrorFeedView.swift      last-3 error feed
        └── SummaryView.swift        post-export summary sheet
```

---

## Data types exported

Defined in `HealthKitTypeCatalog.swift`. All are `HKQuantityType`.

| Display name     | HK identifier                  | Unit exported |
|------------------|-------------------------------|---------------|
| Step Count       | `.stepCount`                  | `count`       |
| Distance         | `.distanceWalkingRunning`     | `m`           |
| Flights Climbed  | `.flightsClimbed`             | `count`       |
| Active Energy    | `.activeEnergyBurned`         | `kcal`        |

To add a type, add a case to `HealthKitExportType` with its HK identifier and preferred unit. The rest of the pipeline picks it up automatically via `CaseIterable`.

---

## Export pipeline

`ExportCoordinator.startExport()` kicks off a single `Task` (subsequent calls are no-ops until the current task finishes or is cancelled):

```
1. requestingPermissions
   └── HealthKitPermissionService.requestAuthorization()
       ├── HKHealthStore.isHealthDataAvailable() → fatal if false
       └── requestAuthorization(toShare:[], read: all 4 types)
           Note: HealthKit does not expose per-type read-denial to the app.
           Authorization failure here means the system rejected the request outright.

2. running
   For each type in HealthKitTypeCatalog.all (sequential):

   a. markTypeQuerying  →  UI shows indeterminate spinner
   b. HKSampleQuery fires; callback delivers all samples at once
   c. onTotal(samples.count) called → UI switches to determinate progress bar
   d. Samples yielded one-by-one from AsyncThrowingStream
   e. Buffer fills to 500; flush() posts batch, clears buffer
   f. Remainder flushed at end of type
   g. markTypeCompleted / markTypeFailed (non-fatal; next type continues)

3. completed(summary) or failed(error)
```

**Batch size:** 500 samples. Constant in `ExportCoordinator.batchSize`. Each batch is an independent POST; a failed batch is counted and logged but does not stop subsequent batches or types.

**Memory:** At most one 500-sample buffer is live at a time per type. `HKSampleQuery` delivers all results for a type into memory before iteration begins — for users with years of dense step-count data this can be large. See [Known limitations](#known-limitations).

---

## Error model

Two severity levels:

| Severity  | Behaviour | Examples |
|-----------|-----------|---------|
| `.fatal`  | Transition to `.failed`; export stops; Export button disabled | `HKHealthStore.isHealthDataAvailable() == false`, auth request throws |
| `.nonFatal` | Logged to ring buffer; counters increment; export continues | HK query error on one type, network failure on one batch |

```swift
enum ErrorCategory {
    case permissions   // fatal
    case healthKit     // non-fatal per type
    case network       // non-fatal per batch
    case unknown
}
```

`ErrorReporter` is the single entry point for reporting errors. It calls `stateMachine.appendError()` on every error, and additionally calls `stateMachine.transition(to: .failed)` for fatal ones.

The state machine keeps the last 3 errors in a ring buffer (`recentErrors`). Older entries are dropped. Counters (`networkFailureCount`, `healthKitFailureCount`) accumulate for the lifetime of the run.

---

## API contract

The app sends HTTP `POST` requests to `AppConfig.endpoint.url`.

### Request

```
POST /ios-dump HTTP/1.1
Content-Type: application/json
```

**Body:**

```json
{
  "batchIndex": 12,
  "samples": [
    {
      "type": "Step Count",
      "uuid": "550E8400-E29B-41D4-A716-446655440000",
      "start": "2024-01-15T08:32:00Z",
      "end": "2024-01-15T08:32:00Z",
      "value": 42.0,
      "unit": "count",
      "source": "Apple Watch",
      "deviceName": "Apple Watch Series 9",
      "deviceModel": "Watch6,1",
      "deviceManufacturer": "Apple Inc.",
      "deviceHardwareVersion": "1.0",
      "deviceSoftwareVersion": "10.0",
      "metadata": {
        "HKMetadataKeyWasUserEntered": "0"
      }
    }
  ]
}
```

**Field notes:**

| Field | Type | Notes |
|-------|------|-------|
| `batchIndex` | `Int` | Global monotonic index across all types in one run. Not reset per type. |
| `type` | `String` | Display name from `HealthKitExportType.displayName` |
| `uuid` | `String` | `HKSample.uuid` as uppercase UUID string |
| `start` / `end` | `String` | ISO 8601, UTC (`JSONEncoder.dateEncodingStrategy = .iso8601`) |
| `value` | `Double?` | `null` for non-quantity samples |
| `unit` | `String?` | HK unit string; `null` for non-quantity samples |
| `source` | `String` | `HKSourceRevision.source.name` (e.g. `"Apple Watch"`, `"Health"`) |
| `deviceName` | `String?` | `HKDevice.name`; `null` if no device attached to sample |
| `deviceModel` | `String?` | `HKDevice.model` (e.g. `"Watch6,1"`) |
| `deviceManufacturer` | `String?` | `HKDevice.manufacturer` (e.g. `"Apple Inc."`) |
| `deviceHardwareVersion` | `String?` | `HKDevice.hardwareVersion` |
| `deviceSoftwareVersion` | `String?` | `HKDevice.softwareVersion` (watchOS / iOS version on the recording device) |
| `metadata` | `Object` | All metadata keys coerced to strings. Non-string, non-number values are dropped. |

Dates within the array are ordered ascending by `startDate` per type. Ordering across types within a batch is not guaranteed since types are processed sequentially and each type produces its own batches.

### Response

| Status | Behaviour |
|--------|-----------|
| `2xx`  | Success; batch acknowledged |
| `4xx`  | Non-retryable; batch counted as failed, export continues |
| `5xx`  | Retried once immediately; if still failing, counted as failed, export continues |
| Transport error (timeout, connection lost, etc.) | Same retry/continue behaviour as 5xx |

The response body is captured and included verbatim (up to 200 characters) in the error message shown in the UI. The server can use it to return a human-readable reason.

---

## State machine

`ExportStateMachine` owns all observable state. It is the only object that mutates UI-visible properties.

```
idle
 │  startExport()
 ▼
requestingPermissions
 │  permissionsFailed (fatal) ──────────────────► failed
 │  permissionsOK
 ▼
running
 │  HK unavailable (fatal) ─────────────────────► failed
 │  pipeline done (non-fatal errors allowed)
 ▼
completed(summary)
 │  dismissFailure() / reset
 ▼
idle
```

`failed` → `idle` via `dismissFailure()` / `reset()`.

**Derived flags** (computed from state + counters):

| Property | Description |
|----------|-------------|
| `isExportEnabled` | `true` only in `.idle` and `.completed` |
| `bannerStyle` | `.gray / .blue / .orange / .green / .red` |
| `showPulsingFailure` | `true` when `state == .failed` |

**Per-type status lifecycle:**

```
pending → querying → uploading → completed
                  ↘           ↘ failed
```

`querying`: HealthKit query in flight, total unknown → indeterminate spinner.  
`uploading`: total known, samples being batched → deterministic `0–100%` progress bar.

---

## UI

| Component | File | Role |
|-----------|------|------|
| `ExportView` | `Features/Export/ExportView.swift` | Root view; scroll container |
| `StatusBannerView` | `Features/Export/StatusBannerView.swift` | Global status; color-coded; pulses red on failure |
| `TypeProgressView` | `Features/Export/TypeProgressView.swift` | One row per HealthKit type; shows phase, progress %, counts |
| `ErrorFeedView` | `Features/Export/ErrorFeedView.swift` | Last 3 errors from ring buffer |
| `SummaryView` | `Features/Export/SummaryView.swift` | Modal sheet on completion; per-type breakdown |

`ExportViewModel` is a thin `@Observable` wrapper over `ExportStateMachine`. It adds action methods (`startExport`, `stopExport`, `dismissFailure`, `openHealthSettings`) and re-exposes state properties so views hold only one reference.

Banner color mapping:

| `BannerStyle` | Color | Meaning |
|---------------|-------|---------|
| `.gray`   | System gray | Idle |
| `.blue`   | Blue | Exporting, no errors |
| `.orange` | Orange | Exporting, non-fatal errors accumulated |
| `.green`  | Green | Completed |
| `.red`    | Red + pulse | Fatal failure |

---

## Tests

Test files live in `iosHealthExportTests/`. A Unit Testing Bundle target must be added in Xcode pointing at that directory.

| File | What it covers |
|------|----------------|
| `HTTPResponseClassifierTests.swift` | All status-code branches; retryable vs non-retryable; transport errors; response body in error message |
| `ExportStateMachineTests.swift` | State transitions; ring buffer cap; counter increments; banner style derivation; per-type lifecycle; progress fraction |
| `FlatSampleEncodingTests.swift` | JSON key presence; device field encoding; null handling for optional fields; `BatchPayload` wrapping |

HealthKit and URLSession are not hit in tests — `HealthKitPermissionServicing` and `SampleStreaming` are protocols; inject mocks to test `ExportCoordinator` in isolation.

---

## Known limitations

**All samples loaded into memory per type.** `HKSampleQuery` delivers its entire result set in one callback. For a user with years of dense step-count data this could be hundreds of thousands of objects. The buffer between query and upload holds at most `batchSize` (500) `FlatSample` structs at a time, but the original `[HKSample]` array from HealthKit remains alive until the stream finishes. Mitigation for a future version: use `HKAnchoredObjectQuery` with a page limit.

**No incremental / anchored export.** Every run re-exports from `.distantPast`. If you call this repeatedly against the same endpoint you will get duplicate data. Anchored export (storing the last `HKQueryAnchor` and resuming from there) is the correct fix and is straightforward to add in `HealthKitSampleStreamer`.

**Foreground only.** The export task is tied to the app's foreground lifetime. If the app is backgrounded mid-export, iOS will eventually suspend it. For large exports on slow connections this is a real problem. Background `URLSession` uploads would address the network side; background HealthKit access would be needed for the query side.

**No per-type read-denial detection.** HealthKit does not tell the app which individual read types the user denied (by design, for privacy). A user who denies only steps will silently get zero step samples rather than a permission error for that type. This is a HealthKit platform constraint.

---

## Adding a new HealthKit type

1. Add a case to `HealthKitExportType` in `HealthKitTypeCatalog.swift`:

```swift
case respiratoryRate = "Respiratory Rate"
```

2. Add the `hkQuantityType` switch arm:

```swift
case .respiratoryRate: return HKQuantityType(.respiratoryRate)
```

3. Add the `defaultUnit` switch arm:

```swift
case .respiratoryRate: return HKUnit(from: "count/min")
```

That's it. `HealthKitTypeCatalog.all` derives from `CaseIterable`; the coordinator, permission service, and UI pick it up automatically.

Non-quantity types (`HKCategorySample`, `HKWorkout`) need an additional branch in `FlatSample.init?(from:exportType:)` to extract a meaningful value and unit.
