import { describe, expect, it } from 'vitest'
import { parseRequest, redactHeaders } from '../../helper/protocol.mjs'

describe('native helper protocol', () => {
  it('accepts a valid background start request', () => {
    expect(parseRequest({
      v: 1,
      id: 'request-1',
      op: 'start',
      idempotencyKey: 'episode-1',
      sourceUrl: 'https://example.com/episode/1',
      sourceTitle: 'Episode 1',
      options: { preferResolution: true, preferredSubtitleLanguage: 'en' },
    })).toMatchObject({ op: 'start', sourceTitle: 'Episode 1' })
  })

  it.each([
    { v: 2, id: 'x', op: 'ping' },
    { v: 1, id: 'x', op: 'unknown' },
    { v: 1, id: 'x', op: 'start', sourceUrl: 'file:///etc/passwd', sourceTitle: 'x', idempotencyKey: 'x', options: {} },
    { v: 1, id: 'x', op: 'ping', shell: 'rm -rf /' },
  ])('rejects unsupported or unsafe requests', (request) => {
    expect(() => parseRequest(request)).toThrow()
  })

  it('redacts request secrets from diagnostics', () => {
    expect(redactHeaders({
      Cookie: 'session=secret',
      Authorization: 'Bearer secret',
      Referer: 'https://example.com/episode',
      'User-Agent': 'Yoink Test',
    })).toEqual({
      Cookie: '[redacted]',
      Authorization: '[redacted]',
      Referer: 'https://example.com/episode',
      'User-Agent': 'Yoink Test',
    })
  })
})
