import { stat } from 'node:fs/promises'
import { createConnection } from 'node:net'

export function requestDaemon(socketPath, request, timeoutMs = 2_000) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath)
    socket.setEncoding('utf8')
    socket.setTimeout(timeoutMs)
    let buffer = ''
    socket.once('connect', () => socket.write(`${JSON.stringify(request)}\n`))
    socket.once('error', reject)
    socket.once('timeout', () => socket.destroy(new Error('The Yoink helper did not respond.')))
    socket.on('data', (chunk) => {
      buffer += chunk
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

async function waitForSocketRemoval(socketPath, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      await stat(socketPath)
    } catch (error) {
      if (error && typeof error === 'object' && error.code === 'ENOENT') return
      throw error
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 50))
  }
  throw new Error('The running Yoink helper did not shut down.')
}

export async function shutdownDaemon(socketPath) {
  let response
  try {
    response = await requestDaemon(socketPath, { v: 1, id: 'installer-shutdown', op: 'shutdown' })
  } catch (error) {
    if (error && typeof error === 'object' && ['ENOENT', 'ECONNREFUSED'].includes(error.code)) return false
    throw error
  }
  if (!response?.ok) throw new Error(response?.error?.message ?? 'The running Yoink helper refused to stop.')
  await waitForSocketRemoval(socketPath)
  return true
}
