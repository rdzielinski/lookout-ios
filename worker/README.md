# The Brain

Cloudflare Worker that gives the assistant persistent memory and real-world
context. **Entirely optional** — with no Worker configured, the iOS app talks
straight to the Claude API and simply forgets between sessions.

What you gain by deploying it:

| | Without Worker | With Worker |
|---|---|---|
| Conversation memory | In-app only, lost on relaunch | Persists across devices and restarts |
| Weather context | — | Injected every turn |
| Calendar awareness | — | Google Calendar, next 36 hours |
| Long-term notes | — | "Remember that…" survives forever |
| Claude key on device | Yes | No — stays server-side |

## Deploy

```bash
cd worker
npm install -g wrangler
wrangler login

# Conversation memory + notes
wrangler kv namespace create JARVIS_KV
# paste the returned id into wrangler.toml

wrangler secret put ANTHROPIC_API_KEY    # your Claude key
wrangler secret put JARVIS_API_TOKEN     # openssl rand -hex 32
wrangler secret put OPENWEATHER_API_KEY  # optional

wrangler deploy
```

Then in the app: **Settings → Brain**, enter the Worker URL and the same
`JARVIS_API_TOKEN`.

Verify:

```bash
curl -X POST https://jarvis-brain.YOUR_SUBDOMAIN.workers.dev/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{"message":"Good morning","sessionId":"test","assistantName":"Jarvis"}'
```

## Google Calendar (optional)

1. [Google Cloud Console](https://console.cloud.google.com/) → new project → enable **Google Calendar API**
2. Credentials → OAuth 2.0 Client ID → **Web application**
3. Authorized redirect URI: `https://YOUR_WORKER_URL/auth/google/callback`
4. ```bash
   wrangler secret put GOOGLE_CLIENT_ID
   wrangler secret put GOOGLE_CLIENT_SECRET
   wrangler deploy
   ```
5. Visit `https://YOUR_WORKER_URL/auth/google/start` and grant read access.

The Settings screen shows a calendar indicator once connected.

## Routes

| Route | Auth | Purpose |
|---|---|---|
| `POST /chat` | Bearer | Single-shot reply |
| `POST /chat/stream` | Bearer | SSE, sentence-level chunks for TTS |
| `POST /session/clear` | Bearer | Drop a conversation |
| `GET /context` | Bearer | Debug: what the brain currently knows |
| `GET\|POST /memory` | Bearer | Long-term notes |
| `GET /auth/google/status` | Bearer | `{ connected: bool }` |
| `GET /auth/google/start` | — | OAuth kickoff |
| `GET /auth/google/callback` | — | OAuth return |
| `GET /health` | — | Liveness |

`/auth/google/*` and `/health` are unauthenticated because Google performs the
redirect itself and can't carry a bearer token. Everything that spends Claude
credits requires one, and the Worker **refuses to start serving** those routes
if `JARVIS_API_TOKEN` is unset rather than defaulting to open.

## The capture directive

The intent router on-device catches most "what am I looking at" phrasings before
they ever reach the network. For everything it misses, the brain can ask for eyes
itself: it replies with exactly `[[CAPTURE]]`, the client takes a photo, runs it
through the vision pipeline, and asks again with the result attached.

That round trip costs about a second, so the prompt in `personality.js` tells it
to use the directive sparingly. If the assistant starts reaching for the camera
too eagerly, tighten that section — it's the knob.

## Files

- `src/index.js` — routes, auth, SSE streaming, Claude calls
- `src/personality.js` — the system prompt (**the file worth tuning**)
- `src/integrations.js` — weather, Google Calendar OAuth, time
- `src/memory.js` — sessions and long-term notes in KV
