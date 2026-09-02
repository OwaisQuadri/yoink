import { mkdir, open, readFile, readdir, rename } from 'node:fs/promises'
import { dirname, join } from 'node:path'

function safeJobId(jobId) {
  if (typeof jobId !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(jobId)) throw new Error('Invalid job id.')
  return jobId
}

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'))
}

async function writeAtomic(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.tmp`
  const file = await open(temporary, 'w', 0o600)
  try {
    await file.writeFile(`${JSON.stringify(value, null, 2)}\n`)
    await file.sync()
  } finally {
    await file.close()
  }
  await rename(temporary, path)
  const directory = await open(dirname(path), 'r')
  try {
    await directory.sync()
  } finally {
    await directory.close()
  }
}

export class JobStore {
  constructor(root) {
    this.root = root
  }

  path(jobId) {
    return join(this.root, safeJobId(jobId), 'job.json')
  }

  workDirectory(jobId) {
    return join(this.root, safeJobId(jobId))
  }

  async create(input) {
    const now = Date.now()
    const snapshot = {
      protocolVersion: 1,
      revision: 1,
      progress: { bytesWritten: 0, ...(input.progress ?? {}) },
      createdAt: now,
      updatedAt: now,
      stopRequested: false,
      workDirectory: this.workDirectory(input.jobId),
      ...input,
    }
    await writeAtomic(this.path(input.jobId), snapshot)
    return snapshot
  }

  async read(jobId) {
    try {
      return await readJson(this.path(jobId))
    } catch (error) {
      if (error && typeof error === 'object' && error.code === 'ENOENT') return undefined
      throw error
    }
  }

  async update(jobId, patch) {
    const current = await this.read(jobId)
    if (!current) throw new Error('Job not found.')
    const next = {
      ...current,
      ...patch,
      progress: patch.progress ? { ...current.progress, ...patch.progress } : current.progress,
      revision: current.revision + 1,
      updatedAt: Date.now(),
    }
    await writeAtomic(this.path(jobId), next)
    return next
  }

  async allJobs() {
    let entries
    try {
      entries = await readdir(this.root, { withFileTypes: true })
    } catch (error) {
      if (error && typeof error === 'object' && error.code === 'ENOENT') return []
      throw error
    }
    const jobs = (await Promise.all(entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => this.read(entry.name))))
      .filter(Boolean)
    return jobs.sort((a, b) => b.updatedAt - a.updatedAt || b.revision - a.revision)
  }

  async latest() {
    return (await this.allJobs())[0]
  }

  // Scopes "the current job" to the browser tab that started it, so a
  // completed/active download on one site's tab never bleeds into the
  // status shown for a different tab (see popup HELPER_STATUS handling).
  async latestForTab(tabId) {
    return (await this.allJobs()).find((job) => job.tabId === tabId)
  }
}

export { writeAtomic }
