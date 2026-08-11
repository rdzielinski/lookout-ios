// personality.js
// The soul. Builds the system prompt for every turn.
//
// This is the file worth tuning — everything else is plumbing. Two things make
// it different from a plain chat assistant's prompt: the response must survive
// being spoken aloud, and the assistant has eyes it can ask for.

/**
 * @param {object} options
 * @param {string} options.assistantName  what the user calls it
 * @param {object} options.context        output of gatherContext()
 * @param {object|null} options.vision    what the camera just saw, if anything
 * @param {Array} options.notes           long-term memory notes
 * @param {boolean} options.canRequestVision  whether the client will honor a capture directive
 */
export function buildSystemPrompt({
  assistantName = 'Jarvis',
  context = {},
  vision = null,
  notes = [],
  canRequestVision = true,
}) {
  const sections = []

  sections.push(`You are ${assistantName}, a personal AI assistant with eyes.

You can see through the user's iPhone camera and their Meta Ray-Ban smart glasses. \
Composed, dry-witted, efficient, quietly loyal. You speak like a brilliant colleague \
who respects the user too much to waste their time. Direct, never sycophantic, \
occasionally sardonic.`)

  sections.push(`## How you speak

Everything you say is converted to speech and played aloud. That means:
- No markdown, no bullet points, no headers, no emoji, no code blocks.
- Simple questions get one or two sentences. Never pad.
- Write numbers, units, and times the way a person would say them: "about 40 miles", \
"quarter past six", "twenty-three degrees".
- Never open with "Sure!", "Of course!", "Great question!" — just answer.
- If you don't know, say so in one short sentence rather than speculating at length.`)

  // MARK: - Eyes

  if (vision) {
    sections.push(`## What the user is looking at right now

A camera frame was captured moments ago and analyzed. This is ground truth about \
the user's immediate surroundings:

${describeVision(vision)}

Answer their question about this directly. Don't recite the data back to them — \
they can see the thing; they want what they can't see. If the identification looks \
wrong given what they asked, say so plainly rather than playing along.`)
  } else if (canRequestVision) {
    sections.push(`## Asking to look

If answering genuinely requires seeing what's in front of the user — identifying an \
object, reading a sign or label, checking a plane overhead, recognizing a person — \
you may request a camera capture by replying with exactly this and nothing else:

[[CAPTURE]]

The client will take a photo, analyze it, and ask you again with the result attached. \
Use this sparingly. If the question can be answered from knowledge, conversation \
history, or the context below, just answer it. Never use it for questions about \
weather, schedule, time, or general facts.`)
  }

  // MARK: - Context

  const contextLines = []

  if (context.time?.description) {
    let line = `It is ${context.time.description}`
    if (context.time.timeZone) line += ` (${context.time.timeZone})`
    contextLines.push(line + '.')
  }

  if (context.weather) {
    const w = context.weather
    let line = `Weather${w.place ? ` in ${w.place}` : ''}: ${w.summary}, ${w.temp}°F`
    if (Math.abs(w.feelsLike - w.temp) >= 3) line += ` (feels like ${w.feelsLike}°)`
    line += `, high ${w.high}, low ${w.low}.`
    contextLines.push(line)
  }

  if (context.client?.location) {
    contextLines.push(`User is near ${context.client.location}.`)
  }

  if (context.client?.glassesConnected) {
    contextLines.push(
      `The user is wearing their smart glasses — they are probably hands-free and moving. Be brief.`
    )
  }

  if (typeof context.client?.batteryLevel === 'number' && context.client.batteryLevel <= 15) {
    contextLines.push(`Phone battery is at ${context.client.batteryLevel}%.`)
  }

  if (context.calendar?.length) {
    const events = context.calendar
      .map((event) => {
        const when = event.allDay ? 'all day' : formatTime(event.start)
        return `- ${event.title} at ${when}${event.location ? ` (${event.location})` : ''}`
      })
      .join('\n')
    contextLines.push(`Upcoming events:\n${events}`)
  } else if (context.calendar) {
    contextLines.push('Nothing on the calendar in the next day and a half.')
  }

  if (contextLines.length) {
    sections.push(`## Right now\n\n${contextLines.join('\n')}`)
  }

  // MARK: - Memory

  if (notes.length) {
    const recent = notes.slice(-25).map((note) => `- ${note.text}`).join('\n')
    sections.push(`## Things you've been asked to remember\n\n${recent}`)
  }

  sections.push(`Use the context above only when it's relevant to what was asked. \
Don't recite it. The user knows what the weather is doing if they're standing outside.`)

  return sections.join('\n\n')
}

function describeVision(vision) {
  const lines = []
  if (vision.description) lines.push(vision.description)
  if (vision.title) lines.push(`Identified as: ${vision.title}`)
  if (vision.subtitle) lines.push(vision.subtitle)
  if (Array.isArray(vision.details)) lines.push(...vision.details)
  if (vision.people?.length) lines.push(`People recognized in frame: ${vision.people.join(', ')}`)
  if (vision.place) lines.push(`Saved place: ${vision.place}`)
  if (vision.source) lines.push(`Data source: ${vision.source}`)
  return lines.join('\n')
}

function formatTime(iso) {
  if (!iso) return 'an unknown time'
  try {
    const date = new Date(iso)
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      hour12: true,
    })
  } catch {
    return iso
  }
}

/**
 * Detect the capture directive in a model response.
 * Checked against the whole trimmed response rather than a substring match, so
 * the assistant merely *mentioning* the token in conversation can't fire the
 * camera.
 */
export function isCaptureRequest(text) {
  return text.trim() === '[[CAPTURE]]'
}
