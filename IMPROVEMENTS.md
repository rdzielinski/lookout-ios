# HybridCoach — Identified Improvements

Comprehensive code review of all 59 Swift files (~5,467 LOC). Issues are categorized
by severity and type.

---

## 1. Bugs & Potential Crashes

### 1.1 Force-unwrap in `BluetoothManager.findCharacteristics()` (line 241)

```swift
let peripheral = connectedPeripheral!
```

`connectedPeripheral` is force-unwrapped after checking only `writeCharacteristic`
and `notifyCharacteristic`. If the peripheral was disconnected between the guard and
this line, the app crashes.

**Fix:** Add `connectedPeripheral` to the existing guard-let or use optional binding.

### 1.2 Duplicate `DrivingDataStore` instances

`HybridCoachApp.swift` creates `@State private var dataStore = DrivingDataStore()`
(line 33), and `AppDelegate` also creates its own `let dataStore = DrivingDataStore()`
(line 7). The CarPlay scene reads from `AppDelegate.dataStore`, while the phone UI
uses the `@State` instance. These are **different objects** — live OBD data never
reaches CarPlay.

**Fix:** Use a single shared instance. Either inject from AppDelegate into the
SwiftUI environment, or use a shared singleton.

### 1.3 `TripRecorder.update()` hardcodes time deltas (line 84–97)

```swift
trip.evModeSeconds += 0.25  // "approximate: each update is ~0.25s"
let timeDelta: Double = 0.25
```

The actual time between calls depends on the OBD polling rate, Timer interval, and
system load. This compounds inaccuracies — a 30-minute drive could be off by several
minutes of EV time and measurable distance error.

**Fix:** Track `lastUpdateTime` and compute actual elapsed time with
`Date().timeIntervalSince(lastUpdate)`.

### 1.4 `ELM327Adapter.responseContinuation` race condition

`sendCommand` stores a single `responseContinuation` (line 165). If `sendCommand` is
called concurrently (e.g., two PIDs polled in rapid succession), the second call
overwrites the first continuation, which is **never resumed** — leaking a suspended
Task.

**Fix:** Use a serial queue or actor-based command serialization to ensure only one
command is in-flight at a time, or use an `AsyncStream` for response dispatching.

### 1.5 `AutoPhixAdapter.didReceiveData` returns partial data

```swift
responseContinuation?.resume(returning: responseBuffer)
responseBuffer = Data()
responseContinuation = nil
```

This resumes immediately on the first BLE notification chunk. If the adapter sends
multi-packet responses, only the first fragment is returned. The ELM327Adapter
correctly waits for the `>` prompt; AutoPhix has no equivalent framing logic.

### 1.6 `OBDService.pollInterval` written but never read

`OBDService` has an adaptive `pollInterval` (line 24) that increases on errors
(line 123: `pollInterval = min(pollInterval * 1.5, 2.0)`), but the polling loop uses
a **hardcoded** `targetCycleTime = 0.25` (line 86) instead of `pollInterval`. The
adaptive slowdown on errors **never takes effect**.

**Fix:** Replace `targetCycleTime` with `pollInterval` in the polling loop.

### 1.7 `EfficiencyAnalyzer` climate check uses 0°C as "no data" sentinel

```swift
guard data.ambientTemp != 0 else { return }  // line 231
```

0°C is a valid temperature. The initial value is `-40` (DrivingDataStore line 14), so
the guard should check `data.ambientTemp > -39` or use an Optional.

**Fix:** Use the initial sentinel value (`-40`) or an Optional to distinguish "no
reading" from "actually 0 degrees".

### 1.8 `CoachingView` route matching uses start coords for both start and end

```swift
// CoachingView.swift lines 53-58
routeStore.matchingCluster(
    startLat: startLat, startLon: startLon,
    endLat: startLat, endLon: startLon  // BUG: same as start!
)
```

The current GPS position is passed as both start and end coordinates. This will
never match a cluster where start and end locations differ. Route-specific coaching
tips are effectively broken.

**Fix:** Pass the trip's starting coordinates as start and current position as end
(or vice versa depending on intent).

### 1.9 `GaugeView` division by zero when `maxValue` is 0

`GaugeView.swift` line 9 computes `value / maxValue` with no guard. If a caller
passes `maxValue: 0`, the app crashes with a division-by-zero.

### 1.10 `OBDService.start()` doesn't cancel previous polling task

If `start()` is called twice (e.g., adapter reconnects), the previous `pollingTask`
is overwritten without cancellation. The old Task continues polling indefinitely as a
leaked background task.

### 1.11 `EVGoalStore` streak calculation ignores calendar gaps

The "current streak" logic iterates sorted daily stats and counts consecutive
`metGoal == true` entries, but doesn't verify the dates are consecutive calendar days.
If a user met their goal on Monday and Wednesday but missed Tuesday, the streak
incorrectly reports 2 because Tuesday has no entry at all.

### 1.12 `RouteDetailView` falls back to empty `Trip()` on lookup failure

```swift
tripRecorder.pastTrips.first(where: { $0.id == record.tripID }) ?? Trip()
```

If the trip lookup fails, a default-constructed Trip with zero values and epoch
timestamp is shown instead of handling the missing data gracefully.

---

## 2. Thread Safety Issues

### 2.1 `OBDService` — `@unchecked Sendable` with unprotected mutable state

`OBDService` (line 10) is marked `@unchecked Sendable` but reads/writes
`pollInterval`, `cycleCount`, `isPolling`, and `errorCount` from both the polling
Task and MainActor without synchronization. `errorCount` is read on line 122
(background Task) right after being written on line 117 (MainActor.run).

**Fix:** Either make `OBDService` an actor, or ensure all state access is
MainActor-isolated.

### 2.2 `BluetoothManager` — `@unchecked Sendable` with mutable state

`BluetoothManager` is `@unchecked Sendable` (line 11) but all its mutable properties
are accessed from both the main queue (CBCentralManager delegates) and arbitrary
callers. The `@Observable` macro doesn't provide thread safety.

**Fix:** Add `@MainActor` isolation or use an actor.

### 2.3 `ELM327Adapter` / `AutoPhixAdapter` — `@unchecked Sendable`

Both adapters store mutable state (`responseBuffer`, `responseContinuation`,
`peripheral`, etc.) and are marked `@unchecked Sendable` without actual
synchronization guarantees.

### 2.4 `LocationTracker` delegate race with `@MainActor`

`LocationTracker` is `@MainActor` but CLLocationManagerDelegate methods are
`nonisolated` and dispatch back via `Task { @MainActor in ... }`. Between delegate
fire and Task execution, `stopTracking()` could be called — appending points to the
buffer after it was already returned and cleared.

### 2.5 `DrivingDataStore` has no actor isolation

Not marked `@MainActor`, updated via `MainActor.run` in OBDService but read from
Timer callbacks using `MainActor.assumeIsolated`. Any non-main-thread access creates
a data race.

---

## 3. Architecture Issues

### 3.1 NotificationCenter for BLE data forwarding

`BluetoothManager.peripheral(_:didUpdateValueFor:)` uses `NotificationCenter` with a
string-based notification name (`"OBDDataReceived"`) to forward data to adapters
(line 368–372). Both `ELM327Adapter` and `AutoPhixAdapter` register observers for
this same notification.

**Problems:**
- Type-unsafe (string-based coupling)
- Both adapters receive each other's data when connected
- No scoping by peripheral or characteristic
- Notification observers are process-global

**Fix:** Use a direct delegate/closure pattern. Pass a data callback into the adapter,
or have BluetoothManager call `adapter.didReceiveData()` directly.

### 3.2 No dependency injection — all stores created inline

`HybridCoachApp` creates 11 `@State` objects directly (lines 33–43). This makes
testing impossible and tightly couples the composition root.

**Fix:** Use an `AppDependencies` container or protocol-based injection.

### 3.3 `AppSettings` doesn't reactively update `EfficiencyAnalyzer`

`setupCallbacks()` sets `analyzer.intensityMultiplier` once on appear (lines 92–96).
If the user changes coaching intensity in Settings, the multiplier doesn't update
until the app is relaunched.

**Fix:** Use `onChange(of: settings.coachingIntensity)` to reactively update the
multiplier.

### 3.4 Timer-based analysis loop instead of reactive pipeline

`startAnalysisLoop()` uses `Timer.scheduledTimer` with
`MainActor.assumeIsolated` (lines 129–139). This is fragile — `assumeIsolated`
crashes if called off the main thread, and Timer retains a strong reference to its
closure. Using `nonisolated(unsafe)` to capture `analyzer` and `dataStore` suppresses
compiler warnings but doesn't guarantee safety.

**Fix:** Use a `Task` with `AsyncStream` or Combine publisher to drive the analysis
loop with proper concurrency.

### 3.5 `onDisappear` unreliable for app lifecycle cleanup

`HybridCoachApp` uses `.onDisappear` on the root WindowGroup view (line 65) for
cleanup (stopping timers, saving trips). `onDisappear` is **not reliably called**
when the app is terminated or backgrounded on iOS.

**Fix:** Use `scenePhase` changes (`.background` / `.inactive`) or
`UIApplication.willTerminateNotification` for cleanup.

### 3.6 Unsupported PIDs poison the error counter and stop all polling

If the vehicle doesn't support a PID (e.g., `0x49` Accelerator Pedal Position),
`OBDService` counts each failed poll toward the 50-error threshold that stops **all**
polling (line 127). A single unsupported PID will eventually halt monitoring entirely.

**Fix:** Query PID `0x0100` / `0x0120` at startup to discover supported PIDs, then
only poll those. Or maintain per-PID error counts and disable individual PIDs.

### 3.7 `TripImprovementAnalyzer` ignores coaching intensity setting

`TripImprovementAnalyzer` hardcodes all thresholds (RPM 3000, speed 55 mph, etc.)
and never references `AppSettings.CoachingIntensity`. The relaxed/normal/aggressive
setting only affects 2 of 8 rules in `EfficiencyAnalyzer` and is completely ignored
in trip improvement analysis.

---

## 4. Data Integrity Issues

### 4.1 No data validation on OBD sensor values

`DrivingDataStore.update()` directly assigns `response.value` without range
validation. A corrupt OBD response could set `engineRPM` to 100,000 or
`vehicleSpeedKmh` to negative values, propagating bad data through the coaching
engine and trip recorder.

**Fix:** Clamp values to valid PID ranges (e.g., RPM: 0–16383, speed: 0–255 km/h).

### 4.2 Trip persistence is fire-and-forget

`TripRecorder.saveTrips()` catches errors and prints to console (line 148). If saving
fails (disk full, permission error), the user loses all trip data without any UI
indication.

**Fix:** Surface persistence errors to the UI, and consider periodic autosave during
recording (not just on trip end).

### 4.3 No data migration strategy

JSON persistence (`trips.json`, `routes.json`, `route_clusters.json`) has no
versioning. If the `Trip`, `RouteRecord`, or `RouteCluster` models change, existing
data silently fails to decode and is replaced with empty arrays (e.g.,
`TripRecorder.loadTrips()` line 157).

**Fix:** Add a schema version to persisted files and implement migration logic.

---

## 5. Performance Issues

### 5.1 `haversineDistance` called repeatedly in hot paths

`RouteStore.findMatchingCluster()`, `backfillPlannedRouteData()`, and
`matchingCluster()` all iterate through all clusters/routes calling
`haversineDistance` per item. With many routes/clusters, this is O(n) per query.

**Fix:** Use a spatial index (grid hash or R-tree) for cluster lookups if the route
count grows beyond ~100.

### 5.2 `buildSpeedLimitProfile` sorts speeds in inner loop

In `RouteStore.buildSpeedLimitProfile()`, `segmentSpeeds.sorted()` is called for
every 500m segment. While segment size is small, using a running percentile or
selecting the nth element (O(n) with `nthElement`) would be more efficient.

### 5.3 Full route data loaded into memory on every launch

`RouteStore.load()` deserializes all routes + clusters at init time. For users with
hundreds of recorded routes, this could cause noticeable launch delay and memory
pressure.

**Fix:** Consider lazy loading or pagination, or migrate to SwiftData/CoreData for
indexed querying.

### 5.4 `DateFormatter` allocated in hot loops

`EVGoalStore.dateKey()`, `TripAggregator.weeklyAverages()`, and
`TripAggregator.monthlyAverages()` all create new `DateFormatter()` instances on
every call. `DateFormatter` allocation is notoriously expensive on iOS. These are
called from SwiftUI render cycles.

**Fix:** Use `static let` cached formatters.

### 5.5 `RouteDetailView` recomputes coaching tips on every render

`RouteDetailView` has computed properties that call
`RouteCoachingEngine.generateTips()` on every SwiftUI re-render. This involves
iterating polylines, computing haversine distances, and detecting hills/turns.

**Fix:** Cache results in `@State` or compute once via `.task` modifier.

### 5.6 Unbounded trip snapshot arrays

`TripRecorder` appends a snapshot every 5 seconds with no upper bound. A 4-hour trip
accumulates 2,880 snapshots, all serialized to JSON. `TripChartView` renders all of
them without downsampling.

**Fix:** Add a maximum snapshot count or downsample for display.

### 5.7 `DrivingDataStore` history uses `removeFirst()` — O(n) per update

```swift
if buffer.count > historySize { buffer.removeFirst() }
```

`Array.removeFirst()` is O(n) due to element shifting. Called every ~0.25s with
`historySize = 120`. Over a long drive, millions of O(120) shifts occur.

**Fix:** Use a circular buffer or `Deque`.

---

## 6. Missing Error Handling

### 6.1 `LocationTracker` silently swallows errors

`locationManager(_:didFailWithError:)` only prints to console (line 93). The user
gets no feedback when GPS fails — trip routes silently become empty.

### 6.2 `OBDService.pollPID` reads `errorCount` outside MainActor

After incrementing `errorCount` in a `MainActor.run` block (line 117), the code
immediately checks `errorCount > 10` outside that block (line 122). The check may
read a stale value.

### 6.3 No BLE reconnection logic

When a peripheral disconnects unexpectedly (`didDisconnectPeripheral`), the manager
calls `cleanup()` and shows an error message. There's no automatic reconnection
attempt, which is disruptive during active driving.

**Fix:** Implement exponential-backoff reconnection for unexpected disconnects.

### 6.4 `BluetoothManager` ignores `error` in delegate callbacks

`peripheral(_:didDiscoverServices:)` and `peripheral(_:didDiscoverCharacteristicsFor:)`
both receive an `error` parameter but completely ignore it. Service/characteristic
discovery failures are silently swallowed.

### 6.5 `LocationTracker` accepts GPS points with poor accuracy

No filtering on `horizontalAccuracy`. Points with 100m+ accuracy (common indoors or
in urban canyons) are added to route polylines, creating noisy zigzag paths.

**Fix:** Filter out locations where `horizontalAccuracy > 50` meters.

### 6.6 `DTCService.clearDTCs` doesn't confirm success

After sending Mode 04, the method optimistically clears `storedCodes` and
`pendingCodes` without re-reading codes to confirm they were actually cleared.

---

## 7. Missing Features & Gaps

### 7.1 No unit tests

Zero test files, zero test targets. For an app that calculates fuel economy, distance,
and efficiency scores, the core logic in `Units`, `OBDResponse`, `EfficiencyAnalyzer`,
`TripRecorder`, and `RouteCoachingEngine` should have thorough test coverage.

**Priority test targets:**
- `Units` — pure functions, trivial to test
- `OBDResponse` — byte parsing correctness
- `EfficiencyAnalyzer` — coaching rule thresholds
- `ELM327Adapter.parseOBDResponse` — hex parsing edge cases
- `TripRecorder.update` — distance/fuel accumulation accuracy

### 7.2 No CI/CD pipeline

No `.github/workflows/`, no `fastlane/`, no build automation. Manual builds only.

### 7.3 No README or documentation

No `README.md`, no architecture docs, no setup instructions.

### 7.4 Metric unit system partially wired

`AppSettings.unitSystem` exists and `Units` has formatting functions, but many views
use hardcoded imperial strings (e.g., "mph", "MPG", "mi") instead of
`Units.formatSpeed()` etc.

### 7.5 No data export

No way to export trip history or route data. Users lose everything on app
reinstall/device change.

### 7.6 No PID support detection at startup

The OBD-II standard defines PIDs `0x0100`, `0x0120`, `0x0140` that return bitmasks
of which PIDs the vehicle supports. HybridCoach polls a fixed list without checking
support first. Unsupported PIDs generate continuous errors.

### 7.7 `RouteCoachingEngine.detectSharpTurns` returns first 5, not sharpest 5

```swift
return Array(tips.prefix(5))
```

Tips are limited to 5 but taken in route-order (first encountered), not by sharpness.
If the gentlest turns appear first, the sharpest turns are dropped.

**Fix:** Sort by bearing change magnitude before truncating.

### 7.8 `RouteCoachingEngine.detectSpeedZones` ignores historical cross-route data

Despite requiring 2+ routes with data (line 149), only the first route's polyline is
analyzed. The function is meant to detect consistent speed drops across multiple trips
but performs no cross-route analysis.

---

## 8. Code Quality

### 8.1 `segmentCoord` unused in `buildSpeedLimitProfile`

`RouteStore.swift` line 262: `segmentCoord` is assigned but never read.

### 8.2 Duplicated haversine calculation

`haversineDistance` is defined as a free function used across `RouteStore`,
`RouteCoachingEngine`, and likely other files. It should be in `Units` for
discoverability, or verified there's only one definition.

### 8.3 Magic numbers throughout

- `50` RPM threshold for EV mode detection (DrivingDataStore line 24)
- `120` history buffer size (line 45)
- `0.25` assumed cycle time (TripRecorder lines 85, 90, 91)
- `500` meters for cluster threshold (RouteStore line 16)
- `15` mph speed drop for braking detection (EfficiencyAnalyzer line 215)
- `199.9` MPG cap (Units line 38)

These should be named constants to explain their significance and enable tuning.

### 8.4 `print()` used for logging

All error and debug output uses `print()` (e.g., TripRecorder line 148,
LocationTracker line 93, ELM327Adapter lines 49–103). These vanish in production
builds without structured logging.

**Fix:** Use `os.Logger` for structured, filterable logging with appropriate log
levels.

### 8.5 Score color/label mapping duplicated 4 times

The efficiency score to color/label mapping is copy-pasted in `CoachingView`,
`TripDetailView`, `TripHistoryView`, and implicitly in dashboard score bars.

**Fix:** Extract to a shared extension or helper function.

### 8.6 Integer division truncation for average scores

`TripHistoryView` and `TripAggregator` compute average efficiency scores using
integer division: `trips.reduce(0) { $0 + $1.averageEfficiencyScore } / trips.count`.
Scores like [79, 80] average to 79 instead of the correct 80.

**Fix:** Use `Double` division and round.

### 8.7 `TripAggregator` duplicates calculation blocks 3 times

The weekly, monthly, and lifetime aggregation methods contain identical computation
blocks (totalMiles, totalGallons, avgMPG, evPercent, avgScore) copy-pasted three
times with only the date filtering differing.

**Fix:** Extract the common aggregation into a helper function.

### 8.8 `AppSettings` UserDefaults keys have no namespace prefix

Bare keys like `"unitSystem"`, `"simulatorMode"` could collide with system framework
keys or SDK keys.

**Fix:** Prefix keys with `"hybridcoach."`.

---

## 9. Security & Privacy

### 9.1 Background location without user education

`LocationTracker` sets `allowsBackgroundLocationUpdates = true` and
`pausesLocationUpdatesAutomatically = false` unconditionally. This aggressively
tracks location even when the user may not expect it. The Info.plist descriptions
should clearly explain why background tracking is needed.

### 9.2 Trip data stored unencrypted

`trips.json`, `routes.json`, and `route_clusters.json` in the Documents directory
contain detailed location history and driving patterns. On a jailbroken device, this
data is easily accessible.

**Fix:** Consider using `Data.WritingOptions.completeFileProtection` for at-rest
encryption.

---

## 10. Summary — Priority Ranking

| Priority | Issue | Impact |
|----------|-------|--------|
| **P0** | Duplicate DrivingDataStore (CarPlay broken) | CarPlay shows no data |
| **P0** | Continuation race in ELM327Adapter | Leaked Tasks, hangs |
| **P0** | Hardcoded 0.25s time delta in TripRecorder | Inaccurate trip data |
| **P0** | `pollInterval` written but never read in loop | Adaptive slowdown broken |
| **P0** | CoachingView route matching uses start for both coords | Route coaching broken |
| **P1** | Thread safety (OBDService, BluetoothManager, adapters) | Potential crashes |
| **P1** | Unsupported PIDs poison error counter, stop all polling | Monitoring halts |
| **P1** | `OBDService.start()` doesn't cancel previous task | Leaked polling tasks |
| **P1** | No unit tests | No regression safety |
| **P1** | AppSettings doesn't reactively update analyzer | Stale coaching intensity |
| **P1** | No BLE reconnection logic | Session disruption mid-drive |
| **P1** | `onDisappear` unreliable for lifecycle cleanup | Trips not saved |
| **P1** | Climate check treats 0°C as "no data" | False negatives at 0°C |
| **P2** | NotificationCenter for BLE data coupling | Fragile architecture |
| **P2** | No data validation on OBD values | Bad data propagation |
| **P2** | No data migration/versioning | Silent data loss on updates |
| **P2** | Metric units setting completely ignored by views | Incomplete feature |
| **P2** | EVGoalStore streak ignores calendar gaps | Incorrect streaks |
| **P2** | DateFormatter allocated in hot loops | UI jank |
| **P2** | Score color/label duplicated 4x, aggregation 3x | Maintainability |
| **P3** | No CI/CD, no README | Developer experience |
| **P3** | print() logging instead of os.Logger | No production diagnostics |
| **P3** | No data export | User data portability |
| **P3** | No PID support detection at startup | Wasted polling |
| **P3** | Magic numbers throughout | Maintainability |
| **P3** | detectSharpTurns/SpeedZones algorithms incomplete | Suboptimal coaching |
