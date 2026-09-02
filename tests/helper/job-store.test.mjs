import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { JobStore } from '../../helper/job-store.mjs'

describe('atomic job store', () => {
  it('persists monotonic revisions and ignores torn temporary writes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-job-store-'))
    const store = new JobStore(root)
    const created = await store.create({
      jobId: 'job-1',
      phase: 'queued',
      sourceUrl: 'https://example.com/episode',
      sourceTitle: 'Episode',
      progress: { bytesWritten: 0 },
    })
    expect(created.revision).toBe(1)

    const updated = await store.update('job-1', { phase: 'acquiring' })
    expect(updated.revision).toBe(2)

    await writeFile(join(root, 'job-1', 'job.json.tmp'), '{broken')
    expect((await store.read('job-1')).phase).toBe('acquiring')
    expect(JSON.parse(await readFile(join(root, 'job-1', 'job.json'), 'utf8')).revision).toBe(2)
  })

  it('returns the most recently updated job', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-job-store-'))
    const store = new JobStore(root)
    await store.create({ jobId: 'a', phase: 'queued', sourceUrl: 'https://a.test', sourceTitle: 'A', progress: { bytesWritten: 0 } })
    await store.create({ jobId: 'b', phase: 'queued', sourceUrl: 'https://b.test', sourceTitle: 'B', progress: { bytesWritten: 0 } })
    await store.update('a', { phase: 'completed' })
    expect((await store.latest()).jobId).toBe('a')
  })

  it('scopes the current job to the tab that started it', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-job-store-'))
    const store = new JobStore(root)
    // Episode 2, downloaded and completed in tab 1.
    await store.create({
      jobId: 'episode-2', phase: 'queued', sourceUrl: 'https://site.test/ep2',
      sourceTitle: 'Episode 2', tabId: 1, progress: { bytesWritten: 0 },
    })
    await store.update('episode-2', { phase: 'completed' })

    // Tab 2 (episode 3) has never started a job of its own: it must not see
    // tab 1's completed job, or the popup renders "Saved episode 2" on a
    // page that was never downloaded and looks like it's blocking a new one.
    expect(await store.latestForTab(2)).toBeUndefined()
    expect((await store.latestForTab(1)).jobId).toBe('episode-2')

    // Once tab 2 starts its own job, it sees only its own, even though the
    // global "latest" (most recently updated across every tab) is still tab 1.
    await store.create({
      jobId: 'episode-3', phase: 'queued', sourceUrl: 'https://site.test/ep3',
      sourceTitle: 'Episode 3', tabId: 2, progress: { bytesWritten: 0 },
    })
    expect((await store.latestForTab(2)).jobId).toBe('episode-3')
    expect((await store.latestForTab(1)).jobId).toBe('episode-2')
  })

  it('does not match a legacy job that predates the tabId field', async () => {
    const root = await mkdtemp(join(tmpdir(), 'yoink-job-store-'))
    const store = new JobStore(root)
    // Jobs created before this fix shipped have no tabId at all.
    await store.create({
      jobId: 'legacy', phase: 'completed', sourceUrl: 'https://site.test/legacy',
      sourceTitle: 'Legacy episode', progress: { bytesWritten: 0 },
    })
    await expect(store.latestForTab(1)).resolves.toBeUndefined()
    await expect(store.latest()).resolves.toMatchObject({ jobId: 'legacy' })
  })
})
