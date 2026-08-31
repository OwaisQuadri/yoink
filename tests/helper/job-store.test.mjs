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
})
