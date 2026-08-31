import { execFile } from 'node:child_process'
import { access, stat } from 'node:fs/promises'
import { constants } from 'node:fs'
import { basename, resolve } from 'node:path'
import { promisify } from 'node:util'
import { readConfig, writeConfig } from './config.mjs'

const execFileAsync = promisify(execFile)

export async function folderMetadata() {
  const config = await readConfig()
  if (!config.outputFolder) return { configured: false }
  const path = resolve(config.outputFolder)
  try {
    const info = await stat(path)
    await access(path, constants.W_OK)
    return { configured: info.isDirectory(), writable: info.isDirectory(), name: basename(path) }
  } catch {
    return { configured: true, writable: false, name: basename(path) }
  }
}

export async function chooseFolder() {
  if (process.platform !== 'darwin') throw new Error('The folder picker currently supports macOS only.')
  const script = 'POSIX path of (choose folder with prompt "Choose where Yoink saves videos")'
  const { stdout } = await execFileAsync('/usr/bin/osascript', ['-e', script], { timeout: 120_000 })
  const outputFolder = resolve(stdout.trim())
  const info = await stat(outputFolder)
  if (!info.isDirectory()) throw new Error('The selected location is not a folder.')
  await access(outputFolder, constants.W_OK)
  await writeConfig({ outputFolder })
  return folderMetadata()
}
