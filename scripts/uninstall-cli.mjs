#!/usr/bin/env node
// Removes the `yoink` command installed by scripts/install-cli.mjs: the
// wrapper script itself plus whichever PATH symlink pointed at it. Only
// unlinks a symlink if it actually points at our wrapper, so an unrelated
// `yoink` command someone else put on PATH is never touched.
import { lstat, readlink, rm, unlink } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

const appRoot = join(homedir(), 'Library', 'Application Support', 'Yoink')
const cliPath = join(appRoot, 'bin', 'yoink')

const candidates = [
  '/opt/homebrew/bin/yoink',
  '/usr/local/bin/yoink',
  join(homedir(), '.local', 'bin', 'yoink'),
]

for (const target of candidates) {
  try {
    const stat = await lstat(target)
    if (stat.isSymbolicLink() && (await readlink(target)) === cliPath) {
      await unlink(target)
      process.stdout.write(`Removed ${target}\n`)
    }
  } catch {
    // Not present, or not ours \u2014 leave it alone either way.
  }
}

await rm(cliPath, { force: true })
process.stdout.write('The `yoink` command was removed.\n')
