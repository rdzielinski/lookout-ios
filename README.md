# Lookout 👁️

**Contextual AI Orchestration for iOS**

Point your camera at anything. Lookout identifies what you're looking at using AI vision, then automatically routes to the right service to give you the information you want — all hands-free with voice output.

## How It Works

```
📸 Camera Capture → 🤖 AI Vision Analysis → 🔀 Skill Router → 📊 Result + 🔊 Voice
```

1. **Capture** — Tap the eye button or (future: voice trigger)
2. **Analyze** — Claude or GPT-4o identifies the object and categorizes it
3. **Route** — The app automatically picks the right "skill" (API/service) to query
4. **Deliver** — Results displayed as a card overlay + spoken aloud

## Active Skills

| Skill | Source | API Key Needed? |
|-------|--------|----------------|
| ✈️ Flight Tracking | OpenSky Network | No (free) |
| 🏛️ Landmark ID | Wikipedia + Google Places | Google key optional |
| 🎵 Music ID | ShazamKit | No (built into iOS) |

## Setup

### Prerequisites
- Xcode 16+
- iOS 18+ device (camera required — won't work in Simulator)
- Apple Developer account (free or paid)

### API Keys
1. **Claude API Key** — Get from [console.anthropic.com](https://console.anthropic.com)
2. **OpenAI API Key** — Get from [platform.openai.com](https://platform.openai.com)
3. **Google Places API Key** (optional) — Get from [Google Cloud Console](https://console.cloud.google.com)

### Running
1. Open `Lookout.xcodeproj` in Xcode
2. Update the bundle identifier to match your team
3. Select your iPhone 17 Pro as the target device
4. Build and run (⌘R)
5. Open Settings in the app → enter at least one AI provider API key
6. Point at something and tap the eye!

## Architecture

```
Lookout/
├── LookoutApp.swift              # Entry point
├── Models/
│   ├── SettingsManager.swift      # API keys, provider selection
│   └── SkillModels.swift          # Skill protocol, routing models
├── Views/
│   ├── ContentView.swift          # Main camera viewfinder UI
│   ├── CameraPreview.swift        # AVCaptureSession UIViewRepresentable
│   ├── ResultCardView.swift       # Skill result display card
│   ├── SettingsView.swift         # API key management
│   └── HistoryView.swift          # Past query results
├── ViewModels/
│   └── LookoutViewModel.swift     # Capture → Analyze → Route pipeline
├── Services/
│   ├── AIVisionService.swift      # Claude & OpenAI vision API calls
│   ├── SkillRouter.swift          # Routes AI response to correct skill
│   ├── LocationManager.swift      # GPS for nearby lookups
│   └── SpeechService.swift        # AVSpeechSynthesizer voice output
└── Skills/
    ├── FlightSkill.swift          # OpenSky Network ADS-B lookup
    ├── LandmarkSkill.swift        # Wikipedia + Google Places
    └── MusicSkill.swift           # ShazamKit integration
```

## Adding New Skills

1. Create a new file in `Skills/`
2. Conform to `LookoutSkill` protocol
3. Register in `SkillRouter.registerSkills()`
4. Add the category to `SkillCategory` enum
5. Update the AI system prompt in `AIVisionService` to include the new category

## Future Ideas

- Voice activation ("Hey Lookout, what is that?")
- Continuous camera mode (auto-detect without tapping)
- Smart glasses integration (Meta Ray-Ban, Apple Vision Pro passthrough)
- More skills: Plant ID (iNaturalist), Vehicle lookup (NHTSA), Product scanning
- Siri Shortcuts integration for hands-free triggering
- Widget for quick access

## License
Personal project — built for fun and experimentation.
