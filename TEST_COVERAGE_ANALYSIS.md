# Test Coverage Analysis — Lookout iOS

## Executive Summary

The Lookout codebase currently has **zero automated test coverage**. There are no XCTest targets, no unit tests, no integration tests, and no UI tests. The only test-related file is `MockGlassesTestView.swift`, a `#if DEBUG` manual testing UI for simulating Meta Ray-Ban glasses hardware.

The codebase contains **41 Swift source files** with approximately **11,900 lines of code** spanning services, skills, view models, views, and models. The architecture is well-suited for testing — protocols, clear service boundaries, and separable business logic — but none of it is exercised by automated tests today.

Below is a prioritized breakdown of where tests would provide the most value.

---

## Priority 1 — Pure Logic with High Complexity (Unit Tests)

These areas contain complex decision-making logic that is fully testable without mocking Apple frameworks.

### 1. `PreScanRouter.predictCategory()` — Category prediction heuristics
**File:** `Lookout/PreScanRouter.swift:192-285` (93 lines)
**Risk:** This function determines which skill runs speculatively. A wrong prediction wastes a parallel API call and adds latency on the re-route.

**What to test:**
- Animal detection override routes to `.plant` at 0.85 confidence
- Each keyword set (plant, vehicle, flight, landmark, product) triggers the correct category
- Confidence boosting logic (`min(topConfidence + 0.1, 0.9)`)
- Text-heavy images (>3 texts) fall back to `.landmark` at 0.5 confidence
- Fallback to `.unknown` when nothing matches
- `cleanIdentifier()` properly converts `"palm_tree"` → `"Palm Tree"`

**Estimated test cases:** 25–35

---

### 2. `UserContextStore` — Product normalization, pet matching, repeat counting
**File:** `Lookout/Services/UserContextStore.swift` (411 lines)

**What to test:**

| Method | Why it matters |
|--------|---------------|
| `normalizeProductKey()` | Strips size patterns (`"12 oz"`, `"500 ml"`, `"24 pack"`) so the same product scanned in different sizes is recognized as one item. Regex correctness is critical. |
| `normalizeScanTitle()` | Removes punctuation and collapses whitespace for repeat-count matching. Edge cases: empty strings, unicode, mixed case. |
| `repeatCount(forTitle:category:)` | Drives the "you've scanned this N times" narration. Wrong counts cause hallucinated familiarity claims. |
| `matchPet(species:description:)` | Keyword-overlap matching at 40% threshold or 3+ keyword override. False positives would misidentify animals. |
| `extractKeywords(from:)` | Stop-word removal and tokenization. |
| `learnProduct(title:details:)` | Increments counts, learns sizes, updates brands. |
| `buildContextPrompt()` | Assembles the AI context string. Wrong output changes AI behavior. |

**Estimated test cases:** 30–40

---

### 3. `FaceMemoryService.compareFaces()` — Weighted similarity scoring
**File:** `Lookout/Services/FaceMemoryService 2.swift:337-378` (41 lines)

**What to test:**
- Feature print cosine similarity contributes 75% weight when available
- Perceptual hash Hamming distance contributes 15% (with feature print) or 60% (without)
- Landmark vector cosine similarity contributes 10% or 40%
- Weight normalization (divides by total weights)
- Edge cases: empty hash, mismatched vector lengths, all-zero vectors
- `cosineSimilarity()` — orthogonal vectors → 0, identical → 1, opposite → -1
- `normalizeVector()` — zero-magnitude vector, single-element vector
- Match threshold at 0.80

**Estimated test cases:** 20–30

---

### 4. `PriceLookupService` — HTML parsing, heuristic pricing, caching
**File:** `Lookout/Services/PriceLookupService.swift` (468 lines)

**What to test:**

| Method | Why it matters |
|--------|---------------|
| `parseGoogleShoppingResults(html:)` | Regex-based HTML parsing is inherently fragile. Tests protect against regressions when Google changes their markup. |
| `heuristicPriceEstimate(name:brand:category:)` | 60+ lines of hardcoded price ranges. Easy to break when adding new products. |
| `isKnownRetailer()` | Substring matching against 30+ retailer names. |
| `cleanRetailerName()` | Trailing punctuation removal + capitalization mapping. |
| `buildPriceSummary()` | Formatting logic for single vs. multiple retailers, price ranges, ratings. |
| `averageRating()` | Edge case: no ratings → nil, single rating, multiple ratings. |
| Barcode cache TTL | Verify 5-minute expiry works correctly. |

**Estimated test cases:** 25–35

---

### 5. `SkillModels` — Data model integrity
**File:** `Lookout/Models/SkillModels.swift` (134 lines)

**What to test:**
- `AIVisionResponse.skillCategory` correctly maps all raw values, including unknown/invalid strings → `.unknown`
- `SkillCategory` computed properties (`displayName`, `badgeName`, `iconName`) return expected values for all cases
- `LookoutQuery.QueryStatus.displayText` covers all states
- `SkillResult` and `DetailItem` identity (UUID generation)

**Estimated test cases:** 15–20

---

## Priority 2 — Service Integration Logic (Requires Mocking)

These components interact with external APIs or Apple frameworks. Tests require protocol abstractions or mock HTTP responses.

### 6. `SkillRouter.processImage()` — The Turbo Pipeline
**File:** `Lookout/SkillRouter.swift:56-216` (160 lines)

This is the most critical code path in the app. It orchestrates the entire capture → analyze → route → result pipeline across three modes:

| Path | Condition | Behavior |
|------|-----------|----------|
| **Fast path** | Pre-scan finds barcode | Skip AI entirely, run `BarcodeSkill` |
| **Parallel path** | Pre-scan confidence ≥ 0.6 (non-music) | Run skill + AI concurrently, merge |
| **Sequential path** | Low confidence or music | AI first, then skill |

**What to test:**
- Fast path triggers on barcode detection, skips AI call entirely
- Parallel path: AI agrees with pre-scan → returns speculative result (HIT)
- Parallel path: AI disagrees → re-routes to correct skill (MISS)
- Parallel path: AI fails but speculative result exists → uses fallback
- Parallel path: AI fails and no speculative result → throws
- Sequential path triggers on low confidence (<0.6)
- Sequential path triggers for music category (even if high confidence)
- Price enrichment only runs for `.product` category
- Face detection runs in parallel with pre-scan
- `recordScan()` is called in all paths

**Prerequisites:** Extract protocols for `AIVisionService`, `PreScanRouter`, and skill dependencies to enable injection of test doubles.

**Estimated test cases:** 20–30

---

### 7. `AIVisionService` — Dual AI provider integration
**File:** `Lookout/Services/AIVisionService.swift` (~394 lines)

**What to test:**
- Claude API request construction (system prompt, base64 image encoding, model selection)
- OpenAI API request construction (message format differences)
- JSON response parsing into `AIVisionResponse`
- Error mapping: 401 → invalid key, 429 → rate limit, 500+ → server error
- Malformed JSON handling (partial response, missing fields)
- Streaming response parsing (line-by-line SSE format)
- Provider switching based on `SettingsManager.aiProvider`

**Prerequisites:** Protocol for `URLSession` or use a mock HTTP layer.

**Estimated test cases:** 15–25

---

### 8. Individual Skills — API integration and response parsing
Each skill implements the `LookoutSkill` protocol, making them independently testable.

| Skill | File | Key test areas |
|-------|------|----------------|
| `FlightSkill` | `Skills/FlightSkill.swift` (540 lines) | Three-source fallback chain (FlightRadar24 → OpenSky → ADS-B Exchange), distance calculation, JSON parsing from each API |
| `BarcodeSkill` | `Skills/BarcodeSkill.swift` (217 lines) | OpenFoodFacts API parsing, barcode detection via Vision, cache behavior |
| `LandmarkSkill` | `Skills/LandmarkSkill.swift` (227 lines) | Google Places vs Wikipedia fallback, HTML stripping, coordinate extraction |
| `VehicleSkill` | `Skills/VehicleSkill.swift` (210 lines) | Query parsing (make/model/year regex extraction), NHTSA API response parsing |
| `PlantSkill` | `Skills/PlantSkill.swift` (175 lines) | iNaturalist API parsing, animal vs plant classification, conservation status |
| `MusicSkill` | `Skills/MusicSkill.swift` (135 lines) | ShazamKit integration, 5-second audio capture, delegation pattern |

**Estimated test cases:** 10–15 per skill (60–90 total)

---

### 9. `SmartNarrationService` — Context-aware speech generation
**File:** `Lookout/Services/SmartNarrationService.swift` (~248 lines)

**What to test:**
- Face recognition context is included when faces are matched
- Repeat-count rules: only claims familiarity when count ≥ 2
- Relationship information is surfaced for recognized faces
- Different skill categories produce category-appropriate narrations
- User context (preferences, history) is incorporated correctly

**Estimated test cases:** 15–20

---

## Priority 3 — State Management and Persistence

### 10. `PlaceMemoryService` — Location-based memory
**File:** `Lookout/Services/PlaceMemoryService.swift` (~204 lines)

**What to test:**
- `findNearbyPlace()` radius matching
- `savePlace()` / `markVisited()` persistence
- Multiple places at different distances
- Edge: no places saved, location is nil

**Estimated test cases:** 10–15

---

### 11. `SettingsManager` — AppStorage-backed settings
**File:** `Lookout/Models/SettingsManager.swift` (~66 lines)

**What to test:**
- Default values for all API keys and feature toggles
- Provider selection persistence
- Glasses-specific settings

**Estimated test cases:** 5–10

---

### 12. `GlassesConnectionState` — State machine
**File:** `Lookout/Services/GlassesConnectionState.swift` (1,019 lines)

**What to test:**
- `GlassesFlowState` transitions: idle → scanning → speakingResult → listeningForFollowUp → processingFollowUp → speakingFollowUp → cooldown
- Invalid transitions are prevented
- Timeout handling in each state
- Bluetooth connection state management

**Estimated test cases:** 20–30

---

## Priority 4 — LookoutViewModel decomposition

`LookoutViewModel.swift` at **1,445 lines** is the largest file in the codebase and acts as the central orchestrator. Before it can be effectively tested, it should be decomposed:

**Suggested extraction targets:**
- **CaptureCoordinator** — camera capture session management
- **ConversationManager** — multi-turn conversation threading
- **HistoryManager** — scan history CRUD
- **PermissionManager** — camera, microphone, location, speech permissions
- **GlassesFlowController** — glasses-specific state machine (extract from GlassesConnectionState)

After decomposition, each extracted component becomes independently unit-testable.

---

## Recommended Test Infrastructure

### Test target setup
```
LookoutTests/           (XCTest unit + integration tests)
├── Services/
│   ├── SkillRouterTests.swift
│   ├── PreScanRouterTests.swift
│   ├── UserContextStoreTests.swift
│   ├── FaceMemoryServiceTests.swift
│   ├── PriceLookupServiceTests.swift
│   ├── PlaceMemoryServiceTests.swift
│   ├── AIVisionServiceTests.swift
│   └── SmartNarrationServiceTests.swift
├── Skills/
│   ├── FlightSkillTests.swift
│   ├── BarcodeSkillTests.swift
│   ├── LandmarkSkillTests.swift
│   ├── VehicleSkillTests.swift
│   ├── PlantSkillTests.swift
│   └── MusicSkillTests.swift
├── Models/
│   ├── SkillModelsTests.swift
│   └── SettingsManagerTests.swift
├── Mocks/
│   ├── MockAIVisionService.swift
│   ├── MockPreScanRouter.swift
│   ├── MockURLSession.swift
│   └── MockLookoutSkill.swift
└── Fixtures/
    ├── sample_google_shopping.html
    ├── sample_opensky_response.json
    ├── sample_claude_response.json
    └── sample_upcitemdb_response.json
```

### Protocol extractions needed for testability
These classes currently use concrete dependencies that make injection difficult:

| Class | Dependency to abstract |
|-------|----------------------|
| `SkillRouter` | `AIVisionService`, `PreScanRouter`, `HapticService` |
| `AIVisionService` | `URLSession` |
| `PriceLookupService` | `URLSession` |
| `FaceMemoryService` | `FileManager`, Vision framework |
| `UserContextStore` | `FileManager` |
| `PlaceMemoryService` | `FileManager` |
| `SpeechService` | `AVSpeechSynthesizer`, `AVAudioPlayer` |

---

## Estimated Total Test Suite

| Priority | Area | Est. test cases |
|----------|------|----------------|
| P1 | Pure logic (PreScan, UserContext, Face, Price, Models) | 115–160 |
| P2 | Service integration (SkillRouter, AI, Skills, Narration) | 110–165 |
| P3 | State & persistence (Place, Settings, Glasses) | 35–55 |
| P4 | ViewModel (post-decomposition) | 30–50 |
| **Total** | | **290–430** |

---

## Where to Start

If starting from zero, this is the recommended order:

1. **Add an XCTest target** to `Lookout.xcodeproj`
2. **`UserContextStore` tests** — pure logic, no mocks needed, high impact on narration correctness
3. **`PreScanRouter.predictCategory()` tests** — pure logic, directly controls the turbo pipeline
4. **`PriceLookupService.parseGoogleShoppingResults()` tests** — fragile regex parsing, protects against silent regressions
5. **`FaceMemoryService.compareFaces()` + math utilities** — algorithmic correctness with clear expected outputs
6. **`SkillRouter` tests** (after extracting protocols) — validates the core pipeline orchestration
7. **Individual skill tests** — each skill is isolated behind the `LookoutSkill` protocol
