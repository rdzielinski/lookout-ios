// integrations.js
// Real-world context the assistant gets for free on every turn: time, weather,
// calendar. Each source degrades independently — a missing OpenWeather key
// costs you weather, not the whole conversation.

const GOOGLE_TOKEN_KEY = 'google:tokens'

// MARK: - Aggregate

/**
 * Gather everything the personality engine can use. Sources run concurrently
 * and every one is individually fault-tolerant, because this sits directly in
 * the path of a voice request where latency is felt.
 */
export async function gatherContext(env, clientContext) {
  const [weather, calendar] = await Promise.all([
    safe(() => getWeather(env, clientContext), null),
    safe(() => getUpcomingEvents(env), null),
  ])

  return {
    time: getTimeContext(clientContext),
    weather,
    calendar,
    client: clientContext || null,
  }
}

async function safe(fn, fallback) {
  try {
    return await fn()
  } catch {
    return fallback
  }
}

// MARK: - Time

export function getTimeContext(clientContext) {
  // Prefer the client's own clock: it knows the user's real timezone, whereas
  // the Worker runs in whatever datacenter took the request.
  if (clientContext?.localTime) {
    return {
      description: clientContext.localTime,
      timeZone: clientContext.timeZone || null,
      partOfDay: partOfDayFrom(clientContext.localTime),
    }
  }

  const now = new Date()
  return {
    description: now.toUTCString(),
    timeZone: 'UTC',
    partOfDay: null,
  }
}

function partOfDayFrom(localTime) {
  const match = /(\d{1,2}):(\d{2})\s*(AM|PM)/i.exec(localTime)
  if (!match) return null

  let hour = parseInt(match[1], 10) % 12
  if (/PM/i.test(match[3])) hour += 12

  if (hour < 5) return 'late night'
  if (hour < 12) return 'morning'
  if (hour < 17) return 'afternoon'
  if (hour < 21) return 'evening'
  return 'night'
}

// MARK: - Weather

export async function getWeather(env, clientContext) {
  const key = env.OPENWEATHER_API_KEY
  if (!key) return null

  const { lat, lon } = resolveCoordinates(env, clientContext)

  const url =
    `https://api.openweathermap.org/data/2.5/weather` +
    `?lat=${lat}&lon=${lon}&units=imperial&appid=${key}`

  const response = await fetch(url)
  if (!response.ok) return null

  const data = await response.json()
  return {
    summary: data.weather?.[0]?.description ?? null,
    temp: Math.round(data.main?.temp ?? 0),
    feelsLike: Math.round(data.main?.feels_like ?? 0),
    high: Math.round(data.main?.temp_max ?? 0),
    low: Math.round(data.main?.temp_min ?? 0),
    wind: Math.round(data.wind?.speed ?? 0),
    place: data.name ?? null,
  }
}

/**
 * The client sends a human-readable place ("Waukesha, WI"), not coordinates —
 * that's all the assistant needs for prose, but OpenWeather needs numbers. Fall
 * back to the configured home location rather than geocoding on every turn.
 */
function resolveCoordinates(env, clientContext) {
  if (
    typeof clientContext?.lat === 'number' &&
    typeof clientContext?.lon === 'number'
  ) {
    return { lat: clientContext.lat, lon: clientContext.lon }
  }
  return {
    lat: env.DEFAULT_LAT || '43.0117',
    lon: env.DEFAULT_LON || '-88.2315',
  }
}

// MARK: - Google Calendar (OAuth2)

export function calendarConfigured(env) {
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET)
}

export function buildAuthURL(env, redirectURI) {
  const params = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectURI,
    response_type: 'code',
    scope: 'https://www.googleapis.com/auth/calendar.readonly',
    // offline + consent is what actually yields a refresh token; without both,
    // Google returns one only on the very first authorization ever.
    access_type: 'offline',
    prompt: 'consent',
  })
  return `https://accounts.google.com/o/oauth2/v2/auth?${params}`
}

export async function exchangeCode(env, code, redirectURI) {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: redirectURI,
      grant_type: 'authorization_code',
    }),
  })

  if (!response.ok) throw new Error(`Token exchange failed: ${response.status}`)

  const tokens = await response.json()
  await storeTokens(env, {
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    expires_at: Date.now() + (tokens.expires_in ?? 3600) * 1000,
  })
  return tokens
}

async function storeTokens(env, tokens) {
  await env.JARVIS_KV.put(GOOGLE_TOKEN_KEY, JSON.stringify(tokens))
}

async function loadTokens(env) {
  const raw = await env.JARVIS_KV.get(GOOGLE_TOKEN_KEY)
  return raw ? JSON.parse(raw) : null
}

export async function calendarConnected(env) {
  if (!calendarConfigured(env)) return false
  const tokens = await loadTokens(env)
  return Boolean(tokens?.refresh_token || tokens?.access_token)
}

/**
 * Return a valid access token, refreshing if it's expired or about to be.
 * The 60s margin avoids the race where a token passes the check and then
 * expires during the calendar request itself.
 */
async function getAccessToken(env) {
  const tokens = await loadTokens(env)
  if (!tokens) return null

  if (tokens.access_token && Date.now() < (tokens.expires_at ?? 0) - 60_000) {
    return tokens.access_token
  }
  if (!tokens.refresh_token) return null

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      refresh_token: tokens.refresh_token,
      grant_type: 'refresh_token',
    }),
  })

  if (!response.ok) return null

  const refreshed = await response.json()
  await storeTokens(env, {
    // Google omits refresh_token on refresh responses — keep the original.
    access_token: refreshed.access_token,
    refresh_token: tokens.refresh_token,
    expires_at: Date.now() + (refreshed.expires_in ?? 3600) * 1000,
  })
  return refreshed.access_token
}

export async function getUpcomingEvents(env, maxResults = 6) {
  if (!calendarConfigured(env)) return null

  const token = await getAccessToken(env)
  if (!token) return null

  const now = new Date()
  const endOfWindow = new Date(now.getTime() + 36 * 60 * 60 * 1000)

  const params = new URLSearchParams({
    timeMin: now.toISOString(),
    timeMax: endOfWindow.toISOString(),
    singleEvents: 'true',
    orderBy: 'startTime',
    maxResults: String(maxResults),
  })

  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`,
    { headers: { Authorization: `Bearer ${token}` } }
  )

  if (!response.ok) return null

  const data = await response.json()
  return (data.items ?? []).map((event) => ({
    title: event.summary ?? 'Untitled',
    start: event.start?.dateTime ?? event.start?.date ?? null,
    allDay: Boolean(event.start?.date && !event.start?.dateTime),
    location: event.location ?? null,
  }))
}
