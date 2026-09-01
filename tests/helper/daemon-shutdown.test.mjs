import { spawn } from 'node:child_process'
import { mkdtemp, stat } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { shutdownDaemon } from '../../helper/daemon-client.mjs'

async function waitForSocket(path) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await stat(path)
      return
    } catch {
      await new Promise((resolveWait) => setTimeout(resolveWait, 25))
    }
  }
  throw new Error('Daemon socket did not appear.')
}

describe('helper daemon shutdown', () => {
  it('closes idle clients and removes the socket before returning', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-daemon-'))
    const socketPath = join(root, 'daemon.sock')
    const child = spawn(process.execPath, [resolve('helper/daemon.mjs')], {
      env: { ...process.env, YOINK_APP_ROOT: root },
      stdio: ['ignore', 'ignore', 'ignore'],
    })
    await waitForSocket(socketPath)
    const idleClient = createConnection(socketPath)
    await new Promise((resolveConnect, reject) => {
      idleClient.once('connect', resolveConnect)
      idleClient.once('error', reject)
    })

    const exited = new Promise((resolveExit) => child.once('exit', resolveExit))
    await expect(shutdownDaemon(socketPath)).resolves.toBe(true)
    const exitCode = await exited
    expect(exitCode).toBe(0)
  }, 10_000)
})
