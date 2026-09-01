#!/usr/bin/env node
import { spawn } from 'node:child_process'
import { createConnection } from 'node:net'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { SOCKET_PATH, ensureAppRoot } from './config.mjs'

const MAX_EXTENSION_MESSAGE = 64 * 1024 * 1024
const MAX_HOST_MESSAGE = 1024 * 1024
const DAEMON_PATH = join(dirname(fileURLToPath(import.meta.url)), 'daemon.mjs')
const EXPECTED_ORIGIN = 'chrome-extension://jojmbolliopfkecelobmepihmhlppceb/'
const callerOrigin = process.argv[2]
if (callerOrigin !== EXPECTED_ORIGIN && process.env.YOINK_ALLOW_DIRECT_HOST !== '1') {
  process.stderr.write('Rejected an unexpected Native Messaging caller.\n')
  process.exit(1)
}
let input = Buffer.alloc(0)
let forwarding = Promise.resolve()

function sendNativeMessage(value) {
  const payload = Buffer.from(JSON.stringify(value))
  if (payload.length > MAX_HOST_MESSAGE) throw new Error('Native response exceeds Chrome limit.')
  const header = Buffer.alloc(4)
  header.writeUInt32LE(payload.length, 0)
  process.stdout.write(Buffer.concat([header, payload]))
}

function socketRequest(request) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET_PATH)
    socket.setEncoding('utf8')
    let buffer = ''
    socket.once('error', reject)
    socket.once('connect', () => socket.write(`${JSON.stringify(request)}\n`))
    socket.on('data', (chunk) => {
      buffer += chunk
      if (buffer.length > MAX_HOST_MESSAGE) {
        socket.destroy()
        reject(new Error('Helper response is too large.'))
        return
      }
      const newline = buffer.indexOf('\n')
      if (newline < 0) return
      socket.end()
      try {
        resolve(JSON.parse(buffer.slice(0, newline)))
      } catch (error) {
        reject(error)
      }
    })
  })
}

async function ensureDaemon() {
  try {
    await socketRequest({ v: 1, id: 'health', op: 'ping' })
    return
  } catch {
    await ensureAppRoot()
  }
  spawn(process.execPath, [DAEMON_PATH], {
    detached: true,
    stdio: 'ignore',
    env: process.env,
  }).unref()
  const deadline = Date.now() + 10_000
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100))
    try {
      await socketRequest({ v: 1, id: 'health', op: 'ping' })
      return
    } catch {
      // Wait for the detached daemon to create its socket.
    }
  }
  throw new Error('The Yoink helper did not start.')
}

async function forward(request) {
  try {
    await ensureDaemon()
    sendNativeMessage(await socketRequest(request))
  } catch (error) {
    sendNativeMessage({
      v: 1,
      id: request?.id ?? 'invalid',
      ok: false,
      revision: 0,
      error: { code: 'HELPER_OFFLINE', message: error instanceof Error ? error.message : String(error) },
    })
  }
}

function consumeInput() {
  while (input.length >= 4) {
    const length = input.readUInt32LE(0)
    if (length > MAX_EXTENSION_MESSAGE) {
      process.stderr.write('Native request exceeds Chrome limit.\n')
      process.exit(1)
    }
    if (input.length < 4 + length) return
    const payload = input.subarray(4, 4 + length)
    input = input.subarray(4 + length)
    let request
    try {
      request = JSON.parse(payload.toString('utf8'))
    } catch {
      request = { id: 'invalid' }
    }
    forwarding = forwarding.then(() => forward(request))
  }
}

process.stdin.on('data', (chunk) => {
  input = Buffer.concat([input, chunk])
  consumeInput()
})
process.stdin.on('error', (error) => {
  process.stderr.write(`${error.message}\n`)
  process.exit(1)
})
