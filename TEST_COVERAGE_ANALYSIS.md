# Test Coverage Analysis — Lookout iOS

## Executive Summary

The Lookout codebase has **zero automated test coverage**. There are no XCTest targets, no unit tests, no integration tests, and no UI tests across 49 Swift files totaling ~15,300 lines of code. The only test-adjacent artifact is `MockGlassesTestView.swift`, a `#if DEBUG` manual UI for simulating Meta Ray-Ban glasses.

This analysis catalogs every source file, identifies high-value testable methods, assesses architectural testability blockers, and proposes a prioritized testing roadmap with estimated test case counts.

---

## Codebase Inventory

| Layer | Files | LOC | Test Coverage |
|-------|------:|----:|:------------:|
| **Skills** | 14 | 3,095 | 0% |
| **Services** | 16 | 5,519 | 0% |
| **ViewModels** | 1 | 1,848 | 0% |
| **Models** | 3 | 285 | 0% |
| **Views** | 10 | 3,438 | 0% |
| **Root-level** | 5 | 1,147 | 0% |
| **Total** | **49** | **~15,332** | **0%** |

---

## Priority 1 — Pure Logic, High Impact (No Mocks Required)

These components contain deterministic, framework-free logic suitable for straightforward unit tests.

### 1.1 `PreScanRouter.predictCategory()` — Routing heuristics

**File:** `Lookout/PreScanRouter.swift:198-361` (163 lines)
**Risk:** Wrong predictions waste a parallel API call and add latency on re-route. The turbo pipeline's speed advantage depends on prediction accuracy.

**Testable logic:**
| Behavior | Lines | Test Cases |
|----------|------:|:----------:|
| Animal detection → `.plant` at confidence 0.85 | 211-214 | 3 |
| Plant keyword matching → `.plant` with boosted confidence | 217-226 | 5 |
| Vehicle keyword matching → `.vehicle` | 229-238 | 5 |
| Flight keyword matching → `.flight` | 241-248 | 4 |
| Landmark keyword matching with text context | 251-263 | 5 |
| Food keyword matching → `.food` | 266-276 | 4 |
| Drink keyword matching with label text | 279-289 | 4 |
| Medication keywords + text hints (dual signal) | 292-301 | 6 |
| Book keywords + text hints (dual signal) | 304-312 | 6 |
| Receipt text-hint counting (≥2 matches) | 315-320 | 5 |
| Business card text patterns (2+ hints, 3-15 texts) | 323-328 | 6 |
| Product keyword matching → `.product` | 331-344 | 4 |
| Translation detection (≥2 non-ASCII texts) | 347-351 | 4 |
| Text-heavy fallback (>3 texts → `.landmark`) | 354-357 | 3 |
| Unknown fallback with confidence floor | 360-361 | 3 |
| Confidence boosting (`min(topConfidence + 0.1, 0.9)`) | various | 4 |
| `cleanIdentifier()` helper | 366-370 | 4 |

**Also testable in `preScan()`:**
| Behavior | Test Cases |
|----------|:----------:|
| QR code barcode routing (`http`, `WIFI:`, `BEGIN:VCARD`, `://`) | 6 |
| Product barcode routing (non-QR barcodes) | 3 |

**Estimated total: ~80 test cases**

**Testing approach:** Make `predictCategory()` and `Classification` internal (or add `@testable import`). Pass synthetic classification/text arrays directly — no Vision framework involvement.

```swift
// Example test
func testAnimalDetectionRoutesToPlant() {
    let result = router.predictCategory(
        classifications: [Classification(label: "golden_retriever", confidence: 0.9)],
        texts: [],
        hasAnimal: true,
        animalLabels: ["Dog"]
    )
    XCTAssertEqual(result.category, .plant)
    XCTAssertEqual(result.confidence, 0.85)
    XCTAssertEqual(result.query, "Dog")
}
```

---

### 1.2 `UserContextStore` — Product normalization, pet matching, context building

**File:** `Lookout/Services/UserContextStore.swift` (411 lines)
**Risk:** `normalizeProductKey()` regex errors cause duplicate product entries. `matchPet()` false positives misidentify animals. `repeatCount()` errors cause hallucinated familiarity claims in narration.

**Testable methods:**

| Method | Description | Test Cases |
|--------|-------------|:----------:|
| `normalizeProductKey()` | Strips size patterns (`"12 oz"`, `"500 ml"`, `"24 pack"`, `"8 fl oz"`, `"10 ct"`) | 12 |
| `normalizeScanTitle()` | Lowercases, strips punctuation, collapses whitespace | 8 |
| `repeatCount(forTitle:category:)` | Counts matching titles with optional category filter | 8 |
| `matchPet(species:description:)` | 40% keyword overlap or 3+ keyword match | 10 |
| `extractKeywords(from:)` | Tokenizes, removes stop words, filters short words | 6 |
| `learnProduct(title:details:)` | Increments counts, tracks sizes, updates brands | 8 |
| `productMemory(for:)` | Normalized key lookup | 4 |
| `preferredSize(for:)` | Returns most-scanned size | 4 |
| `buildContextPrompt(...)` | Assembles full AI context string from all sources | 10 |
| `recordScan()` | Category counts, recent-scans capping at 50 | 5 |
| Codable round-trip: `UserContext`, `ScanHistoryItem`, `ProductMemory`, `PetMemory` | Encode/decode fidelity | 4 |

**Estimated total: ~79 test cases**

**Testing approach:** Instantiate `UserContextStore` with a temporary directory (override `storageURL`) to avoid polluting real data. Pre-populate `context` directly for lookup tests.

---

### 1.3 `SkillRouter.adjustForEnvironment()` — Environment-adjusted confidence

**File:** `Lookout/Services/SkillRouter.swift:294-328` (34 lines)
**Risk:** Incorrect adjustments send high-confidence predictions to the wrong pipeline path, either wasting speculative work or missing the turbo fast path.

**Testable logic:**
| Behavior | Test Cases |
|----------|:----------:|
| Music venue → lower confidence for unknown/landmark | 3 |
| Loud ambient (>-20 dB) → lower confidence for unknown | 3 |
| Retail area → boost product confidence | 3 |
| No environment → pass-through | 2 |
| Nil preScan → returns (.unknown, 0.0) | 1 |
| Confidence bounds (never < 0.0, never > 0.95) | 3 |

**Estimated total: ~15 test cases**

**Testing approach:** This is a private method, but it could be extracted to internal scope or tested indirectly via `processImage()` flow. Alternatively, extract to a freestanding pure function.

---

### 1.4 `SkillRouter.executingStatus()` — Category-to-status mapping

**File:** `Lookout/Services/SkillRouter.swift:332-350` (static method)
**Risk:** Low, but comprehensive tests prevent regressions when adding new categories.

**Estimated total: 15 test cases** (one per `SkillCategory` case)

---

### 1.5 `SkillModels` — Enum mappings and Codable conformance

**File:** `Lookout/Models/SkillModels.swift` (181 lines)

| What to test | Test Cases |
|-------------|:----------:|
| `SkillCategory.displayName` — 15 cases | 15 |
| `SkillCategory.badgeName` — 15 cases | 15 |
| `SkillCategory.iconName` — 15 cases | 15 |
| `SkillCategory` raw value round-trip | 15 |
| `AIVisionResponse.skillCategory` with valid/invalid strings | 5 |
| `QueryStatus.displayText` — 19 cases | 19 |
| `AIVisionResponse` Codable encode/decode | 3 |

**Estimated total: ~87 test cases**

---

### 1.6 `PriceLookupService` — Heuristic pricing & HTML parsing

**File:** `Lookout/Services/PriceLookupService.swift` (468 lines)

| Method | Description | Test Cases |
|--------|-------------|:----------:|
| `heuristicPriceEstimate()` | Category-based price ranges for ~30 product types | 20 |
| `parseGoogleShoppingResults()` | Regex-based HTML price/retailer extraction | 10 |
| `isKnownRetailer()` | Matching against retailer list | 8 |
| `cleanRetailerName()` | Trailing punctuation removal, proper capitalization | 10 |
| `buildPriceSummary()` | Single-price, multi-price, with/without ratings | 6 |
| `averageRating()` | Empty, single, multiple ratings | 3 |
| `ProductPricing.bestPrice` | Computed property, lowest price | 3 |
| Barcode cache TTL logic | Fresh vs. expired entries | 3 |

**Estimated total: ~63 test cases**

**Testing approach:** `heuristicPriceEstimate()`, `parseGoogleShoppingResults()`, `cleanRetailerName()`, `buildPriceSummary()` are all testable without network access. Feed sample HTML strings to the parser.

---

### 1.7 `FlightSkill` — Result building & helpers

**File:** `Lookout/Skills/FlightSkill.swift` (538 lines)

| Method | Description | Test Cases |
|--------|-------------|:----------:|
| `buildResult(from:)` | Maps `NearbyAircraft` → `SkillResult` with conditional fields | 12 |
| `headingToCardinal()` | 0°→N, 90°→E, 180°→S, 270°→W, boundaries | 8 |
| `asDouble()` | Int, Double, NSNumber, nil, NSNull | 5 |
| `createFallbackResult()` | Correct structure and messaging | 2 |
| Title generation (flight number vs. callsign vs. default) | 3 |
| Subtitle generation (airline+route, airline+alt, country+alt, default) | 4 |
| Deep link URL construction | 3 |

**Estimated total: ~37 test cases**

---

## Priority 2 — Service Logic Requiring Dependency Injection

These services have valuable logic but require protocol-based mocks for their dependencies.

### 2.1 `AIVisionService` — Caching, image optimization, provider routing

**File:** `Lookout/Services/AIVisionService.swift` (451 lines)

**Testable with mocks:**
| Method | What to Test | Test Cases |
|--------|-------------|:----------:|
| `optimizedBase64()` | Image scaling (>1024px → downscaled, ≤1024px → unchanged) | 4 |
| `cachedResponse()` | Fresh cache hit, expired miss, missing key | 4 |
| `cacheResponse()` | Eviction when count > 20, TTL enforcement | 3 |
| `analyzeImage()` | Cache hit fast-path, provider routing (Claude vs. OpenAI) | 4 |
| `buildUserMessageText()` | With question, without question, empty/whitespace question | 3 |
| Error handling | 401, 429, 5xx, parsing failure | 6 |

**Estimated total: ~24 test cases**

**Blocker:** `SettingsManager` uses `@AppStorage` (direct `UserDefaults`). Needs a protocol wrapper or test-specific `UserDefaults` suite.

---

### 2.2 `SkillRouter.processImage()` — Turbo pipeline orchestration

**File:** `Lookout/Services/SkillRouter.swift:61-290` (229 lines)
**Risk:** The core business logic of the app. Three pipeline paths (QR fast-path, barcode fast-path, parallel speculative, sequential fallback) with branching on confidence thresholds.

**Testable flows (integration-level):**
| Pipeline Path | Trigger | Test Cases |
|--------------|---------|:----------:|
| QR code fast-path | preScan finds QR with confidence 1.0 | 3 |
| Barcode fast-path | preScan finds product barcode | 3 |
| Parallel speculative (HIT) | preScan ≥0.6 confidence, AI agrees | 4 |
| Parallel speculative (MISS) | preScan ≥0.6, AI disagrees → re-route | 4 |
| AI failure with speculative fallback | AI throws, preScan has result | 3 |
| Sequential pipeline | preScan < 0.6 or music category | 3 |
| Status callback sequence | Correct order per path | 4 |
| Price enrichment for products | Products get price lookup | 2 |
| Scan recording | userContext, faceMemory, placeMemory updated | 3 |

**Estimated total: ~29 test cases**

**Blocker:** Requires mock implementations of `PreScanRouter`, `AIVisionService`, `LookoutSkill`, `FaceMemoryService`, `PlaceMemoryService`, `UserContextStore`, `HapticService`. Currently, `HapticService.shared` is called as a singleton — would need a protocol + injection.

---

### 2.3 `SmartNarrationService` — Prompt construction

**File:** `Lookout/Services/SmartNarrationService.swift` (258 lines)

| Method | What to Test | Test Cases |
|--------|-------------|:----------:|
| `buildNarrationPrompt()` | Includes all context parts: category, title, subtitle, faces, place, user context, question | 10 |
| Recognized faces with relationships | Relationship formatting | 3 |
| Unknown face count inclusion | Count > 0 vs. 0 | 2 |
| User question integration | With/without question | 2 |
| `systemPrompt` | Correct content (regression) | 1 |

**Estimated total: ~18 test cases**

**Testing approach:** `buildNarrationPrompt()` is private but pure. Could be made internal, or tested via a debug method that exposes the prompt.

---

### 2.4 Skills Layer — Common pattern across 14 skills

All 14 skills follow the same structure: `execute(query:location:) -> SkillResult`. Their testability varies:

| Skill | Pure Logic to Test | External Dependencies | Test Cases |
|-------|-------------------|----------------------|:----------:|
| **FlightSkill** | `buildResult()`, `headingToCardinal()`, `asDouble()` | 3 flight APIs | 37 |
| **LandmarkSkill** | Result construction | Wikipedia, Google Places | 6 |
| **MusicSkill** | Result construction | ShazamKit | 4 |
| **PlantSkill** | Result construction | AI API | 5 |
| **VehicleSkill** | Result construction | AI API | 5 |
| **BarcodeSkill** | Barcode cleaning (`query.filter { $0.isNumber }`), cache logic | Open Food Facts | 8 |
| **TranslationSkill** | Result construction | AI API | 5 |
| **FoodSkill** | `NutritionResponse` parsing, detail construction | AI API | 6 |
| **DrinkSkill** | Response parsing, detail construction | AI API | 6 |
| **ReceiptSkill** | Expense parsing, detail construction | AI API | 6 |
| **MedicationSkill** | Drug info parsing, detail construction | AI API | 5 |
| **BookSkill** | Title/author parsing, detail construction | AI API | 5 |
| **BusinessCardSkill** | Contact field parsing, detail construction | AI API | 6 |
| **QRCodeSkill** | URL parsing, WiFi config parsing, vCard parsing | None (parser-only) | 10 |

**Estimated total: ~114 test cases**

**Common testing approach:** 8 of 14 skills delegate to AI (Claude/OpenAI) for structured JSON responses. Testing these requires either (a) mocking the HTTP layer, or (b) extracting the JSON→SkillResult mapping into a testable function that accepts a pre-parsed response struct.

---

## Priority 3 — ViewModel & Remaining Services

### 3.1 `LookoutViewModel` — Main orchestration

**File:** `Lookout/ViewModels/LookoutViewModel.swift` (1,848 lines)
**Risk:** Highest-complexity file. Contains scan orchestration, glasses integration, conversation management, camera lifecycle, and state machine logic.

**Currently untestable without major refactoring.** Key blockers:

1. **No dependency injection** — Services are initialized inline:
   ```swift
   let locationManager = LocationManager()
   let speechService = SpeechService()
   // ... 9 more services instantiated as properties
   ```
2. **No service protocols** — Can't substitute test doubles
3. **Singleton usage** — `HapticService.shared` called directly
4. **26 `@Published` properties** with complex interdependencies
5. **Multiple concurrent Tasks** (`continuousScanTask`, `cameraAutoSleepTask`, etc.)

**If refactored for testability, high-value tests would include:**
| Area | Test Cases |
|------|:----------:|
| `captureAndAnalyze()` state transitions | 8 |
| `processGlassesPhoto()` flow | 5 |
| Glasses flow state machine (7 states) | 10 |
| `gatherEnvironmentSignals()` | 4 |
| Permission checking logic | 4 |
| Conversation turn management | 6 |
| Camera sleep/wake lifecycle | 5 |

**Estimated total (post-refactor): ~42 test cases**

---

### 3.2 `GlassesConnectionState` — Hardware state machine

**File:** `Lookout/Services/GlassesConnectionState.swift` (1,053 lines)
**Complex state machine** managing Bluetooth pairing, stream sessions, voice triggers, camera permissions with Meta Wearables SDK. Requires SDK mocks.

**Estimated total (post-refactor): ~25 test cases**

---

### 3.3 `SpeechService` — TTS management

**File:** `Lookout/Services/SpeechService.swift` (554 lines)
**Depends on** `AVSpeechSynthesizer`. Testing queue management and interruption logic would require a protocol wrapper.

**Estimated total: ~10 test cases**

---

### 3.4 Other services

| Service | LOC | Estimated Tests | Notes |
|---------|----:|:---------------:|-------|
| `FaceMemoryService 2.swift` | 516 | 15 | Vision framework + CoreImage dependency |
| `PlaceMemoryService.swift` | 250 | 10 | CoreLocation + persistence |
| `OfflineVisionService.swift` | 392 | 8 | Vision framework dependency |
| `ConversationMessage.swift` | 244 | 6 | Data models (Codable tests) |
| `BackgroundKeepAliveService.swift` | 228 | 5 | BGTaskScheduler dependency |
| `VoiceInputService.swift` | 119 | 5 | Speech framework dependency |
| `LocationManager.swift` | 64 | 3 | CLLocationManager dependency |
| `FrameBufferService.swift` | 68 | 4 | Thread-safe buffer logic |
| `HapticService.swift` | 377 | 4 | UIKit haptics (singleton) |

---

## Priority 4 — UI & Design Token Tests

| Component | Type | Test Cases |
|-----------|------|:----------:|
| `LookoutColor.swift` — `SkillCategory.skillColor` mapping | Snapshot/unit | 15 |
| `LookoutShortcutsProvider.swift` — Intent logic | Unit | 6 |
| Views (10 files) | UI/Snapshot | Deferred |

---

## Architectural Testability Assessment

### Current State: **POOR**

| Pattern | Current | Impact on Testability |
|---------|---------|----------------------|
| **Dependency Injection** | None. Services instantiated inline. | Cannot substitute test doubles. |
| **Protocols for Services** | Only `LookoutSkill` protocol exists. | Cannot mock services. |
| **Singletons** | `HapticService.shared` used globally. | Untestable side effects. |
| **`@AppStorage`** | `SettingsManager` uses 40+ `@AppStorage` props. | Tied to real `UserDefaults`. |
| **Static state** | `AIVisionService.responseCache` is static. | Shared state across tests. |
| **Private methods with logic** | `predictCategory()`, `adjustForEnvironment()`, `buildNarrationPrompt()` | Not directly testable. |

### Recommended Refactoring (by Priority)

**1. Extract protocols for core services** (Estimated effort: 4-6 hours)
```swift
protocol VisionAnalyzing {
    func analyzeImage(_ image: UIImage, userQuestion: String?) async throws -> AIVisionResponse
}
protocol SkillExecuting {
    func execute(query: String, location: CLLocation?) async throws -> SkillResult
}
protocol HapticProviding {
    func categorized()
    func barcodeDetected()
}
protocol SettingsProviding {
    var selectedProvider: AIProvider { get }
    var claudeAPIKey: String { get }
    // ... key properties
}
```

**2. Constructor injection in SkillRouter** (Estimated effort: 2-3 hours)
```swift
class SkillRouter {
    init(settings: SettingsProviding,
         visionService: VisionAnalyzing,
         preScanRouter: PreScanRouting,
         haptics: HapticProviding) { ... }
}
```

**3. Make key private methods internal/testable** (Estimated effort: 1 hour)
- `PreScanRouter.predictCategory()` → `internal`
- `PreScanRouter.Classification` → `internal`
- `SkillRouter.adjustForEnvironment()` → extract to a free function
- `SmartNarrationService.buildNarrationPrompt()` → `internal`

**4. Wrap SettingsManager in a protocol** (Estimated effort: 2-3 hours)
```swift
protocol SettingsProviding {
    var selectedProvider: AIProvider { get }
    var hasValidAPIKey: Bool { get }
    var claudeAPIKey: String { get }
    var openAIAPIKey: String { get }
    // ...
}
```

**5. Replace HapticService singleton** (Estimated effort: 1-2 hours)
- Inject via protocol into SkillRouter and ViewModel

---

## Test Case Summary

| Priority | Component | Estimated Tests | Requires Mocks? |
|:--------:|-----------|:---------------:|:---------------:|
| **1** | PreScanRouter.predictCategory() | 80 | No |
| **1** | UserContextStore | 79 | No (temp dir) |
| **1** | SkillModels enums | 87 | No |
| **1** | PriceLookupService (pure logic) | 63 | No |
| **1** | FlightSkill (pure logic) | 37 | No |
| **1** | SkillRouter.executingStatus() + adjustForEnvironment() | 30 | No |
| **2** | AIVisionService (cache, routing) | 24 | Settings mock |
| **2** | SkillRouter.processImage() | 29 | Multiple mocks |
| **2** | SmartNarrationService (prompts) | 18 | Minimal |
| **2** | Skills layer (14 skills) | 114 | HTTP/AI mocks |
| **3** | LookoutViewModel (post-refactor) | 42 | Major refactor |
| **3** | GlassesConnectionState | 25 | SDK mock |
| **3** | Other services | 60 | Various |
| **4** | UI & design tokens | 21 | Snapshot infra |

| | **Total Estimated** | **~709** | |

---

## Recommended Starting Order

### Phase 1: Quick wins — no infrastructure changes (Priority 1)
**Target: ~376 tests covering pure logic**

1. Add an XCTest target to `Lookout.xcodeproj`
2. `PreScanRouterTests` — predictCategory(), cleanIdentifier(), barcode routing
3. `UserContextStoreTests` — normalization, matching, context building
4. `SkillModelsTests` — enum mappings, Codable conformance
5. `PriceLookupServiceTests` — heuristics, HTML parsing, retailer helpers
6. `FlightSkillTests` — buildResult(), headingToCardinal(), asDouble()
7. `SkillRouterStaticTests` — executingStatus()

### Phase 2: Protocol extraction + service tests
**Target: ~185 additional tests**

1. Extract `SettingsProviding`, `VisionAnalyzing`, `HapticProviding` protocols
2. `AIVisionServiceTests` — caching, provider routing
3. `SkillRouterPipelineTests` — all pipeline paths with mock services
4. `SmartNarrationServiceTests` — prompt construction
5. Individual skill tests for result parsing (QRCodeSkill first — no external deps)

### Phase 3: ViewModel + hardware services
**Target: ~127 additional tests**

1. Refactor `LookoutViewModel` for constructor injection
2. ViewModel flow tests with full mock service layer
3. `GlassesConnectionState` state machine tests with SDK mocks

### Phase 4: UI snapshot tests
**Target: ~21 tests**

1. Set up snapshot testing infrastructure (swift-snapshot-testing or similar)
2. Design token validation tests
3. Key view snapshot tests

---

## Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|------|:----------:|:------:|------------|
| PreScanRouter prediction regression | High | High | Phase 1 tests |
| Product normalization duplicate entries | Medium | Medium | Phase 1 tests |
| Pet matching false positives | Medium | Low | Phase 1 tests |
| Pipeline path regression (turbo → sequential) | Medium | High | Phase 2 tests |
| AI response parsing failures | Medium | High | Phase 2 tests (mock JSON) |
| Glasses state machine deadlock | Low | Critical | Phase 3 tests |
| Cache eviction edge cases | Low | Low | Phase 1/2 tests |

---

*Analysis performed on 49 Swift source files, ~15,332 LOC. February 2026.*
