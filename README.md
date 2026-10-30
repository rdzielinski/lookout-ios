# Lookout

An iPhone app that identifies whatever your camera, or a pair of Meta Ray-Ban smart glasses, is pointed at, sends it to the right "skill", and speaks the answer hands-free.

## How it works

Capture → AI vision → skill router → result card + voice

Skills include flights overhead, landmarks, music (Shazam), plants, food, drinks, books, vehicles, barcodes and QR codes, receipts, business cards, and translating foreign-language text.

## Tech

- Swift, SwiftUI, AVFoundation camera pipeline
- AI vision through Claude or OpenAI, with an on-device fallback using Vision and Core ML
- ShazamKit, Speech (voice commands), AVSpeechSynthesizer (spoken answers), CoreHaptics
- Meta Wearables SDK for glasses camera streaming, with a mock-device test view
- App Intents for Siri and Shortcuts, CoreLocation for nearby lookups

## Running it

Open `Lookout.xcodeproj`, build to a real iPhone (camera required), then add at least one AI provider key in Settings. Keys are entered in the app, never committed.
