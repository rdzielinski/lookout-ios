# Lookout × J.A.R.V.I.S. 👁️

**A personal AI assistant that can see.**

This repository is the combination of two projects: **Jarvis**, a voice assistant
built on Claude and ElevenLabs, and **Lookout**, a camera app that identifies what
you're pointing at and routes it to the right service. Jarvis had a voice and a
memory but no eyes. Lookout had eyes but no conversation that outlived a single
photo. Now they're one app.

Say its name. Ask it anything. If the question needs eyes, it takes a look.

```
    "Jarvis, what's that plane?"
              │
     wake word (on-device)
              │
        intent router ─────── needs eyes? ───┐
              │                              │
              │ no                      yes  │
              ▼                              ▼
      brain (/chat/stream)          camera or Ray-Ban glasses
      weather · calendar · memory    AI vision → skill router
              │                              │
              └──────────┬───────────────────┘
                         ▼
            one conversation, one voice
         streaming TTS, sentence by sentence
```

## What it does

**Ask it about the world.** "What's the weather?", "What's on my schedule?",
"When do the Brewers play?" — routed to the brain, answered with live context.

**Ask it about what's in front of you.** "What is this?", "What kind of tree is
that?", "Read this label", "What plane is that?" — it captures a frame from your
phone or your Meta Ray-Bans, runs the vision pipeline, and answers.

**Keep talking.** The scan and the six follow-up questions after it live in one
transcript. "How tall is it?" works right after "What's that building?" because
the assistant remembers what it just saw for three minutes.

**Hands-free, genuinely.** Wake word listening runs on-device. With the glasses
connected, the whole loop — trigger, capture, answer — never touches the phone.

## Skills

The vision pipeline picks a skill based on what it sees:

| Skill | Source | Key needed |
|---|---|---|
| ✈️ Flight tracking | FlightRadar24, OpenSky fallback | FR24 optional |
| 🏛️ Landmarks | Wikipedia + Google Places | Google optional |
| 🎵 Music ID | ShazamKit | No |
| 🌿 Plants & nature | AI vision | No |
| 🚗 Vehicles | NHTSA | No |
| 🏷️ Barcodes & prices | Product lookup | No |
| 👤 Faces & places | On-device memory | No |

Offline, an on-device Vision model still gives you an answer.

## Setup

**Requirements:** Xcode 16+, an iOS 18 device (the camera won't work in the
Simulator), and a Claude or OpenAI API key.

1. Open `Lookout.xcodeproj`, set your team and bundle identifier, build to your phone.
2. **Settings → API Keys** — add a Claude or OpenAI key. That's the minimum.
3. **Settings → Assistant** — name it, turn on the wake word.
4. Optional: **Settings → Brain** — deploy [`worker/`](worker/README.md) for
   persistent memory plus weather and calendar. Without it the assistant runs
   directly against your Claude key and forgets between sessions.
5. Optional: **Settings → Voice Output** — add an ElevenLabs key for a real voice.
6. Optional: **Settings → Meta Ray-Ban Glasses** — pair and connect.

Every optional piece degrades independently. None of them block the others.

## Architecture

```
Lookout/
├── Assistant/                      ← the merge lives here
│   ├── AssistantEngine.swift        wake word → listen → decide → answer
│   ├── IntentRouter.swift           does this question need eyes?
│   ├── BrainService.swift           Worker client + direct-Claude fallback
│   ├── WakeWordDetector.swift       continuous on-device listening
│   ├── AudioSessionCoordinator.swift  one mic, five consumers, no fights
│   ├── AssistantHost.swift          owns the single instance of each half
│   ├── LookoutViewModel+Assistant.swift  the camera, as the assistant sees it
│   └── Views/{OrbView, AssistantView}.swift
├── ViewModels/LookoutViewModel.swift   capture → analyze → route pipeline
├── Services/                        vision, speech, glasses, memory, skills
├── Skills/                          one file per skill
└── Views/ContentView.swift          the camera screen, now a mode

worker/                             ← Cloudflare Worker brain (optional)
├── src/personality.js               the system prompt — the file worth tuning
├── src/integrations.js              weather, Google Calendar
├── src/memory.js                    sessions + long-term notes in KV
└── src/index.js                     routes, auth, SSE streaming
```

### How the two halves stay out of each other's way

The hard part of the merge wasn't features, it was contention. Both projects
wanted the microphone and the speaker.

- **`AudioSessionCoordinator`** gives the mic to exactly one consumer at a time,
  with priorities (dictation > vision capture > playback > glasses trigger >
  wake word). Preempted consumers tear down their audio tap before the new owner
  installs one. When everything releases, wake-word listening resumes on its own.
- **One `SpeechService`, one `VoiceInputService`, one `LookoutViewModel`.**
  `AssistantHost` constructs them; nothing else may. Two speech synthesizers talk
  over each other; two capture sessions fight for the camera.
- **The assistant owns the voice.** `runVisionScan` runs the same pipeline as the
  camera screen but stays silent and *returns* its result, so only one thing is
  ever speaking.

### Routing: does this question need eyes?

`IntentRouter` classifies on-device before anything hits the network, and it's
deliberately biased toward conversation — a misrouted chat question wastes a
sentence, but a misrouted vision question fires the camera for nothing.

It routes to vision on an explicit phrase ("what am I looking at"), or on a
pointing word plus a camera verb or a skill noun ("what kind of *tree* is *that*").
Knowledge anchors win outright, so "what's the weather like out here" stays a chat
question despite the deictic.

For everything it misses, the brain can ask for eyes itself by replying
`[[CAPTURE]]`. The client takes a photo and asks again with the result attached.

## Adding a skill

1. New file in `Skills/`, conform to `LookoutSkill`.
2. Register it in `SkillRouter.registerSkills()`.
3. Add the case to `SkillCategory`.
4. Add the category to the vision system prompt in `AIVisionService`.
5. Add its nouns to `IntentRouter.skillNouns` so voice questions route to it.

Step 5 is the one that's easy to forget — without it the skill works from the
camera screen but not from "hey, what's that ___".

## Privacy

- Wake-word detection is on-device and continuous when enabled. Nothing is
  recorded or transmitted until you ask something.
- API keys are stored locally. Deploy the Worker if you'd rather your Claude key
  never sat on the phone.
- Face and place memory are on-device only.

## License

Personal project — built for fun and experimentation.
