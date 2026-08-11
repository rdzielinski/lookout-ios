// index.js
// Routes for the assistant brain.
//
// Contract consumed by BrainService.swift:
//   POST /chat                { message, sessionId, clientContext, visionContext, assistantName }
//                          -> { response, sessionId, action? }
//   POST /chat/stream         same body, server-sent events with sentence-level chunks
//   POST /session/clear       { sessionId }
//   GET  /health
//   GET  /context             debug: what the brain currently knows
//   GET|POST /memory          long-term notes
//   GET  /auth/google/start   OAuth kickoff
//   GET  /auth/google/callback
//   GET  /auth/google/status  -> { connected }

import { buildSystemPrompt, isCaptureRequest } from './personality.js'
import {
  gatherContext,
  buildAuthURL,
  exchangeCode,
  calendarConnected,
  calendarConfigured,
} from './integrations.js'
import {
  loadSession,
  saveSession,
  clearSession,
  loadNotes,
  addNote,
  clearNotes,
} from './memory.js'

const JSON_HEADERS = { 'Content-Type': 'application/json' }

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    const path = url.pathname

    if (request.method === 'OPTIONS') return corsPreflight()

    try {
      // Public routes — no bearer token. The OAuth callback can't carry one
      // (Google performs the redirect), and /health is a liveness probe.
      if (path === '/health') {
        return json({ ok: true, calendar: calendarConfigured(env) })
      }
      if (path === '/auth/google/start') return handleAuthStart(request, env)
      if (path === '/auth/google/callback') return handleAuthCallback(request, env)

      // Everything below requires the bearer token.
      const denied = requireAuth(request, env)
      if (denied) return denied

      switch (path) {
        case '/chat':
          return handleChat(request, env)
        case '/chat/stream':
          return handleChatStream(request, env, ctx)
        case '/session/clear':
          return handleClearSession(request, env)
        case '/context':
          return handleContext(request, env)
        case '/memory':
          return handleMemory(request, env)
        case '/auth/google/status':
          return json({ connected: await calendarConnected(env) })
        default:
          return json({ error: 'Not found' }, 404)
      }
    } catch (error) {
      return json({ error: error.message || 'Internal error' }, 500)
    }
  },
}

// MARK: - Auth

function requireAuth(request, env) {
  // Trimmed: a secret set by pasting into a prompt, or piped in from a file or
  // `echo`, easily carries a trailing newline. Comparing untrimmed makes that a
  // 401 with nothing to distinguish it from a genuinely wrong token — which
  // costs far more debugging time than the whitespace is worth defending.
  // Bearer tokens have no meaningful leading or trailing whitespace.
  const expected = (env.JARVIS_API_TOKEN || '').trim()

  // Fail closed. An unset token must not mean "open to the internet" — this
  // endpoint spends the owner's Claude credits.
  if (!expected) return json({ error: 'Server missing JARVIS_API_TOKEN' }, 500)

  const header = request.headers.get('Authorization') || ''
  const provided = header.startsWith('Bearer ') ? header.slice(7).trim() : ''

  if (!timingSafeEqual(provided, expected)) {
    return json({ error: 'Unauthorized' }, 401)
  }
  return null
}

/// Constant-time compare so token verification can't be probed byte by byte.
function timingSafeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  }
  return diff === 0
}

// MARK: - Chat

async function handleChat(request, env) {
  const body = await request.json()
  const { message, sessionId, clientContext, visionContext, assistantName } = body

  if (!message) return json({ error: 'message is required' }, 400)

  const [context, notes, history] = await Promise.all([
    gatherContext(env, clientContext),
    loadNotes(env),
    loadSession(env, sessionId),
  ])

  const system = buildSystemPrompt({
    assistantName: assistantName || 'Jarvis',
    context,
    vision: visionContext || null,
    notes,
    canRequestVision: !visionContext,
  })

  const messages = [...history, { role: 'user', content: message }]
  const text = await callClaude(env, system, messages)

  if (isCaptureRequest(text)) {
    // Don't persist the directive — the client will come straight back with a
    // vision payload, and a transcript full of [[CAPTURE]] teaches the model to
    // emit it more often.
    return json({
      response: '',
      sessionId,
      action: { type: 'capture', reason: 'needs a look' },
    })
  }

  messages.push({ role: 'assistant', content: text })
  await saveSession(env, sessionId, messages)

  return json({ response: text, sessionId })
}

// MARK: - Streaming Chat

async function handleChatStream(request, env, ctx) {
  const body = await request.json()
  const { message, sessionId, clientContext, visionContext, assistantName } = body

  if (!message) return json({ error: 'message is required' }, 400)

  const [context, notes, history] = await Promise.all([
    gatherContext(env, clientContext),
    loadNotes(env),
    loadSession(env, sessionId),
  ])

  const system = buildSystemPrompt({
    assistantName: assistantName || 'Jarvis',
    context,
    vision: visionContext || null,
    notes,
    canRequestVision: !visionContext,
  })

  const messages = [...history, { role: 'user', content: message }]

  const { readable, writable } = new TransformStream()
  const writer = writable.getWriter()
  const encoder = new TextEncoder()

  const send = (payload) =>
    writer.write(encoder.encode(`data: ${JSON.stringify(payload)}\n\n`))

  const pump = async () => {
    let full = ''
    let pending = ''
    let sentenceIndex = 0

    try {
      const upstream = await claudeStream(env, system, messages)

      for await (const delta of upstream) {
        full += delta
        pending += delta

        // Emit whole sentences as they complete. Speaking sentence-by-sentence
        // is what takes perceived latency from "waiting" to "conversational" —
        // the first words are audible while the model is still writing.
        let boundary
        while ((boundary = findSentenceEnd(pending)) !== -1) {
          const sentence = pending.slice(0, boundary + 1).trim()
          pending = pending.slice(boundary + 1)
          if (sentence) {
            await send({ sentence, sentenceIndex: sentenceIndex++ })
          }
        }
      }

      const tail = pending.trim()

      if (isCaptureRequest(full)) {
        await send({ action: { type: 'capture', reason: 'needs a look' } })
        await send({ done: true, fullResponse: '', sessionId })
        return
      }

      if (tail) {
        await send({ sentence: tail, sentenceIndex: sentenceIndex++ })
      }

      messages.push({ role: 'assistant', content: full })
      await saveSession(env, sessionId, messages)

      await send({ done: true, fullResponse: full, sessionId })
    } catch (error) {
      await send({ error: error.message || 'stream failed', done: true, fullResponse: full })
    } finally {
      await writer.close()
    }
  }

  // waitUntil keeps the Worker alive for the whole stream; without it the
  // response can be cut off once fetch() returns.
  ctx.waitUntil(pump())

  return new Response(readable, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      ...corsHeaders(),
    },
  })
}

/**
 * Index of the last character of the first complete sentence in `text`, or -1.
 *
 * Requires the terminator to be followed by whitespace, which keeps decimals
 * ("3.5 miles") and abbreviations from being split mid-thought and spoken as
 * two separate utterances.
 */
function findSentenceEnd(text) {
  for (let i = 0; i < text.length - 1; i++) {
    const char = text[i]
    if (char !== '.' && char !== '!' && char !== '?') continue
    if (!/\s/.test(text[i + 1])) continue
    // Don't split "3.5" or "Dr. Smith".
    if (char === '.' && /\d/.test(text[i - 1] ?? '') && /\d/.test(text[i + 2] ?? '')) continue
    return i
  }
  return -1
}

// MARK: - Claude

async function callClaude(env, system, messages) {
  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: env.CLAUDE_MODEL || 'claude-sonnet-5',
      max_tokens: 512,
      // Thinking is on by default on Opus 5, and thinking tokens come out of
      // max_tokens. In a voice loop that buys latency we can't spend and can
      // starve the spoken answer, so turn it off. Only valid at effort <= high
      // (high is the default, so we don't set effort at all).
      thinking: { type: 'disabled' },
      system,
      messages,
    }),
  })

  if (!response.ok) {
    const detail = await response.text()
    throw new Error(`Claude API ${response.status}: ${detail.slice(0, 200)}`)
  }

  const data = await response.json()
  return (data.content ?? [])
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
    .join('')
}

/// Async generator yielding text deltas from Claude's SSE stream.
async function* claudeStream(env, system, messages) {
  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: env.CLAUDE_MODEL || 'claude-sonnet-5',
      max_tokens: 512,
      // See callClaude — thinking off keeps the first spoken sentence early.
      thinking: { type: 'disabled' },
      system,
      messages,
      stream: true,
    }),
  })

  if (!response.ok) {
    const detail = await response.text()
    throw new Error(`Claude API ${response.status}: ${detail.slice(0, 200)}`)
  }

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break

    buffer += decoder.decode(value, { stream: true })

    // SSE frames are newline-delimited; hold the trailing partial line back
    // until the next chunk completes it.
    const lines = buffer.split('\n')
    buffer = lines.pop() ?? ''

    for (const line of lines) {
      if (!line.startsWith('data: ')) continue
      const payload = line.slice(6).trim()
      if (!payload || payload === '[DONE]') continue

      try {
        const event = JSON.parse(payload)
        if (event.type === 'content_block_delta' && event.delta?.type === 'text_delta') {
          yield event.delta.text
        }
      } catch {
        // Ignore malformed frames rather than killing the stream.
      }
    }
  }
}

// MARK: - Session / Context / Memory

async function handleClearSession(request, env) {
  const { sessionId } = await request.json()
  await clearSession(env, sessionId)
  return json({ ok: true })
}

async function handleContext(request, env) {
  const context = await gatherContext(env, null)
  const notes = await loadNotes(env)
  return json({ context, noteCount: notes.length })
}

async function handleMemory(request, env) {
  if (request.method === 'GET') {
    return json({ notes: await loadNotes(env) })
  }
  if (request.method === 'POST') {
    const { note, clear } = await request.json()
    if (clear) {
      await clearNotes(env)
      return json({ ok: true, notes: [] })
    }
    if (!note) return json({ error: 'note is required' }, 400)
    return json({ ok: true, notes: await addNote(env, note) })
  }
  return json({ error: 'Method not allowed' }, 405)
}

// MARK: - Google OAuth

function redirectURI(request) {
  const url = new URL(request.url)
  return `${url.origin}/auth/google/callback`
}

function handleAuthStart(request, env) {
  if (!calendarConfigured(env)) {
    return html('<h1>Calendar not configured</h1><p>Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET.</p>', 400)
  }
  return Response.redirect(buildAuthURL(env, redirectURI(request)), 302)
}

async function handleAuthCallback(request, env) {
  const url = new URL(request.url)
  const code = url.searchParams.get('code')

  if (!code) return html('<h1>Authorization failed</h1><p>No code returned.</p>', 400)

  try {
    await exchangeCode(env, code, redirectURI(request))
    return html(`
      <div style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:60px 24px;background:#0a0d12;color:#e8eef5;min-height:100vh">
        <div style="font-size:52px">&#10003;</div>
        <h1 style="font-weight:600">Calendar connected</h1>
        <p style="opacity:.6">You can close this tab and go back to the app.</p>
      </div>
    `)
  } catch (error) {
    return html(`<h1>Authorization failed</h1><p>${escapeHTML(error.message)}</p>`, 500)
  }
}

// MARK: - Helpers

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...corsHeaders() },
  })
}

function html(body, status = 200) {
  return new Response(`<!doctype html><meta charset="utf-8">${body}`, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  })
}

function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[char]))
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  }
}

function corsPreflight() {
  return new Response(null, { status: 204, headers: corsHeaders() })
}
