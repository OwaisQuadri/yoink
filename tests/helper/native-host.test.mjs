import { spawn } from 'node:child_process'
import { mkdtemp, mkdir } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

function readNativeMessage(stream) {
  return new Promise((resolve, reject) => {
    let value = Buffer.alloc(0)
    const onData = (chunk) => {
      value = Buffer.concat([value, chunk])
      if (value.length < 4) return
      const size = value.readUInt32LE()
      if (value.length < 4 + size) return
      stream.off('data', onData)
      resolve(JSON.parse(value.subarray(4, 4 + size).toString('utf8')))
    }
    stream.on('data', onData)
    stream.once('error', reject)
  })
}

describe('native messaging bridge', () => {
  it('rejects an unexpected extension origin', async () => {
    const child = spawn(process.execPath, [resolve('helper/native-host.mjs'), 'chrome-extension://bad/'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    const code = await new Promise((resolveExit) => child.once('exit', resolveExit))
    expect(code).toBe(1)
  })

  it('forwards a length-prefixed request through the private socket', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-native-host-'))
    await mkdir(root, { recursive: true })
    const socketPath = join(root, 'daemon.sock')
    const server = createServer((socket) => {
      socket.setEncoding('utf8')
      let value = ''
      socket.on('data', (chunk) => {
        value += chunk
        const newline = value.indexOf('\n')
        if (newline < 0) return
        const request = JSON.parse(value.slice(0, newline))
        socket.end(`${JSON.stringify({ v: 1, id: request.id, ok: true, revision: 0, result: { pong: true } })}\n`)
      })
    })
    await new Promise((resolveListen) => server.listen(socketPath, resolveListen))

    const child = spawn(process.execPath, [resolve('helper/native-host.mjs')], {
      env: { ...process.env, YOINK_APP_ROOT: root, YOINK_ALLOW_DIRECT_HOST: '1' },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    const payload = Buffer.from(JSON.stringify({ v: 1, id: 'request-1', op: 'ping' }))
    const header = Buffer.alloc(4)
    header.writeUInt32LE(payload.length)
    child.stdin.write(Buffer.concat([header, payload]))

    const response = await readNativeMessage(child.stdout)
    expect(response).toMatchObject({ id: 'request-1', ok: true, result: { pong: true } })

    child.stdin.end()
    child.kill('SIGTERM')
    await new Promise((resolveClose) => server.close(resolveClose))
  })
})
