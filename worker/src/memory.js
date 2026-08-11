// memory.js
// Conversation history and long-term notes, both backed by Workers KV.
//
// Two distinct things live here:
//   - Sessions: the rolling transcript of the current conversation. Expires.
//   - Notes:    durable facts the assistant was told to remember. Never expires
//               unless explicitly deleted.

const SESSION_PREFIX = 'session:'
const NOTES_KEY = 'memory:notes'

/// Turns kept in a session. Beyond this the oldest fall off — a voice
/// conversation that runs longer than 20 turns has almost always moved on from
/// whatever was said at the start, and the notes store exists for anything that
/// genuinely needs to persist.
const MAX_TURNS = 20

export async function loadSession(env, sessionId) {
  if (!sessionId) return []
  try {
    const raw = await env.JARVIS_KV.get(SESSION_PREFIX + sessionId)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    // A corrupt session should start a fresh conversation, not 500 the request.
    return []
  }
}

export async function saveSession(env, sessionId, messages) {
  if (!sessionId) return
  const trimmed = messages.slice(-MAX_TURNS)
  const ttl = parseInt(env.SESSION_TTL || '14400', 10)
  await env.JARVIS_KV.put(SESSION_PREFIX + sessionId, JSON.stringify(trimmed), {
    expirationTtl: ttl,
  })
}

export async function clearSession(env, sessionId) {
  if (!sessionId) return
  await env.JARVIS_KV.delete(SESSION_PREFIX + sessionId)
}

// MARK: - Long-term notes

export async function loadNotes(env) {
  try {
    const raw = await env.JARVIS_KV.get(NOTES_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

export async function addNote(env, text) {
  const notes = await loadNotes(env)
  notes.push({ text, at: new Date().toISOString() })
  // Keep the store bounded; the oldest notes are the least likely to matter.
  const bounded = notes.slice(-200)
  await env.JARVIS_KV.put(NOTES_KEY, JSON.stringify(bounded))
  return bounded
}

export async function clearNotes(env) {
  await env.JARVIS_KV.delete(NOTES_KEY)
}
