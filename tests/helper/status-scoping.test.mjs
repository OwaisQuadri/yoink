import { spawn } from 'node:child_process'
import { mkdtemp, mkdir, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { requestDaemon, shutdownDaemon } from '../../helper/daemon-client.mjs'
import { JobStore } from '../../helper/job-store.mjs'

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

// Reproduces the reported bug: after finishing "Episode 2" in one tab, the
// popup on a fresh "Episode 3" tab must not be told that episode 2's
// completed job is *its* status \u2014 that stale "Saved episode 2 already"
// state is what read to the user as the download being blocked.
describe('helper daemon status scoping', () => {
  let child

  afterEach(async () => {
    if (child) child.kill('SIGKILL')
  })

  it('reports no job for a tab that never started one, even with a completed job elsewhere', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-status-scope-'))
    await mkdir(join(root, 'jobs'), { recursive: true })
    const socketPath = join(root, 'daemon.sock')

    const store = new JobStore(join(root, 'jobs'))
    await store.create({
      jobId: 'episode-2',
      phase: 'queued',
      sourceUrl: 'https://site.test/episode-2',
      sourceTitle: 'Episode 2',
      tabId: 101,
      progress: { bytesWritten: 0 },
    })
    await store.update('episode-2', { phase: 'completed', outputFilename: 'episode-2.mp4' })

    child = spawn(process.execPath, [resolve('helper/daemon.mjs')], {
      env: { ...process.env, YOINK_APP_ROOT: root },
      stdio: ['ignore', 'ignore', 'ignore'],
    })
    await waitForSocket(socketPath)

    // Episode 3's tab (102) asks for its own status with no jobId, the way
    // the popup does on a fresh open. It must come back empty, not with
    // episode 2's "completed" snapshot.
    const forNewTab = await requestDaemon(socketPath, { v: 1, id: 'a', op: 'status', tabId: 102 })
    expect(forNewTab.ok).toBe(true)
    expect(forNewTab.snapshot).toBeUndefined()

    // Episode 2's own tab still sees its completed job when asked directly.
    const forOldTab = await requestDaemon(socketPath, { v: 1, id: 'b', op: 'status', tabId: 101 })
    expect(forOldTab.snapshot).toMatchObject({ jobId: 'episode-2', phase: 'completed' })

    await shutdownDaemon(socketPath)
  }, 10_000)
})
