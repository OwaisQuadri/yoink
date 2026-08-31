import { homedir } from 'node:os'
import { join } from 'node:path'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'

export const APP_ROOT = process.env.YOINK_APP_ROOT
  ?? join(homedir(), 'Library', 'Application Support', 'Yoink')
export const SOCKET_PATH = join(APP_ROOT, 'daemon.sock')
export const JOBS_ROOT = join(APP_ROOT, 'jobs')
export const CONFIG_PATH = join(APP_ROOT, 'config.json')

export async function ensureAppRoot() {
  await mkdir(APP_ROOT, { recursive: true, mode: 0o700 })
  await mkdir(JOBS_ROOT, { recursive: true, mode: 0o700 })
}

export async function readConfig() {
  try {
    const value = JSON.parse(await readFile(CONFIG_PATH, 'utf8'))
    return value?.version === 1 ? value : { version: 1 }
  } catch (error) {
    if (error && typeof error === 'object' && error.code === 'ENOENT') return { version: 1 }
    throw error
  }
}

export async function writeConfig(config) {
  await ensureAppRoot()
  const temporary = `${CONFIG_PATH}.tmp`
  await writeFile(temporary, `${JSON.stringify({ version: 1, ...config }, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, CONFIG_PATH)
}
