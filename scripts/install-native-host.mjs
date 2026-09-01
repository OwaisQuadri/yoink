#!/usr/bin/env node
import { chmod, mkdir, writeFile } from 'node:fs/promises'
import { accessSync, constants } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { shutdownDaemon } from '../helper/daemon-client.mjs'

const HOST_NAME = 'com.owaisquadri.yoink'
const EXTENSION_ID = 'jojmbolliopfkecelobmepihmhlppceb'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const appRoot = join(homedir(), 'Library', 'Application Support', 'Yoink')
const binDir = join(appRoot, 'bin')
const wrapperPath = join(binDir, 'yoink-native-host')
const manifestDirs = [
  join(homedir(), 'Library', 'Application Support', 'Google', 'Chrome', 'NativeMessagingHosts'),
  join(homedir(), 'Library', 'Application Support', 'Google', 'Chrome for Testing', 'NativeMessagingHosts'),
]
const manifestPaths = manifestDirs.map((directory) => join(directory, `${HOST_NAME}.json`))

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

if (process.platform !== 'darwin') throw new Error('The Yoink helper installer currently supports macOS only.')
accessSync(join(root, 'helper', 'native-host.mjs'), constants.R_OK)
accessSync(chromium.executablePath(), constants.X_OK)

await shutdownDaemon(join(appRoot, 'daemon.sock'))
await mkdir(binDir, { recursive: true, mode: 0o700 })
await Promise.all(manifestDirs.map((directory) => mkdir(directory, { recursive: true, mode: 0o700 })))
const wrapper = `#!/bin/sh\nexec ${shellQuote(process.execPath)} ${shellQuote(join(root, 'helper', 'native-host.mjs'))} "$@"\n`
await writeFile(wrapperPath, wrapper, { mode: 0o700 })
await chmod(wrapperPath, 0o700)
const manifest = `${JSON.stringify({
  name: HOST_NAME,
  description: 'Yoink local headless download helper',
  path: wrapperPath,
  type: 'stdio',
  allowed_origins: [`chrome-extension://${EXTENSION_ID}/`],
}, null, 2)}\n`
await Promise.all(manifestPaths.map((path) => writeFile(path, manifest, { mode: 0o600 })))

process.stdout.write([
  'Yoink helper installed.',
  `Extension ID: ${EXTENSION_ID}`,
  `Load unpacked: ${join(root, 'dist')}`,
  ...manifestPaths.map((path) => `Native host: ${path}`),
].join('\n') + '\n')
