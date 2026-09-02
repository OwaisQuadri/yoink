const OPS = new Set(['ping', 'choose-folder', 'start', 'status', 'stop', 'reveal', 'shutdown'])

function assertObject(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${name} must be an object.`)
}

function assertExactKeys(value, allowed) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`Unknown field: ${key}`)
  }
}

function assertText(value, name, max = 4096) {
  if (typeof value !== 'string' || value.length === 0 || value.length > max) {
    throw new Error(`${name} must be a non-empty string.`)
  }
}

function assertHttpUrl(value) {
  assertText(value, 'sourceUrl', 16_384)
  const url = new URL(value)
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('sourceUrl must use HTTP or HTTPS.')
}

export function parseRequest(input) {
  assertObject(input, 'request')
  if (input.v !== 1) throw new Error('Unsupported protocol version.')
  assertText(input.id, 'id', 256)
  assertText(input.op, 'op', 64)
  if (!OPS.has(input.op)) throw new Error('Unsupported operation.')

  const common = new Set(['v', 'id', 'op'])
  if (input.op === 'ping' || input.op === 'choose-folder' || input.op === 'shutdown') {
    assertExactKeys(input, common)
    return input
  }
  if (input.op === 'status') {
    assertExactKeys(input, new Set([...common, 'jobId', 'afterRevision', 'tabId']))
    if (input.jobId !== undefined) assertText(input.jobId, 'jobId', 256)
    if (input.afterRevision !== undefined && (!Number.isInteger(input.afterRevision) || input.afterRevision < 0)) {
      throw new Error('afterRevision must be a non-negative integer.')
    }
    if (input.tabId !== undefined && (!Number.isInteger(input.tabId) || input.tabId < 0)) {
      throw new Error('tabId must be a non-negative integer.')
    }
    return input
  }
  if (input.op === 'stop' || input.op === 'reveal') {
    assertExactKeys(input, new Set([...common, 'jobId']))
    assertText(input.jobId, 'jobId', 256)
    return input
  }

  assertExactKeys(input, new Set([...common, 'idempotencyKey', 'sourceUrl', 'sourceTitle', 'tabId', 'options']))
  assertText(input.idempotencyKey, 'idempotencyKey', 256)
  assertHttpUrl(input.sourceUrl)
  assertText(input.sourceTitle, 'sourceTitle', 1024)
  if (input.tabId !== undefined && (!Number.isInteger(input.tabId) || input.tabId < 0)) {
    throw new Error('tabId must be a non-negative integer.')
  }
  assertObject(input.options, 'options')
  assertExactKeys(input.options, new Set(['preferResolution', 'preferredSubtitleLanguage']))
  if (input.options.preferResolution !== true) throw new Error('preferResolution must be true.')
  if (input.options.preferredSubtitleLanguage !== 'en') {
    throw new Error('preferredSubtitleLanguage must be en.')
  }
  return input
}

export function redactHeaders(headers) {
  const result = {}
  for (const [name, value] of Object.entries(headers ?? {})) {
    result[name] = /^(cookie|authorization|proxy-authorization|x-api-key)$/i.test(name)
      ? '[redacted]'
      : value
  }
  return result
}

export function response(id, { result, snapshot, error, revision = 0 }) {
  return {
    v: 1,
    id,
    ok: !error,
    revision,
    ...(result === undefined ? {} : { result }),
    ...(snapshot === undefined ? {} : { snapshot }),
    ...(error === undefined ? {} : { error }),
  }
}
