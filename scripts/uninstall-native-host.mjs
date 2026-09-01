#!/usr/bin/env node
import { rm } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { shutdownDaemon } from '../helper/daemon-client.mjs'

const appRoot = join(homedir(), 'Library', 'Application Support', 'Yoink')
await shutdownDaemon(join(appRoot, 'daemon.sock'))
const manifestPaths = ['Chrome', 'Chrome for Testing'].map((product) => join(
  homedir(),
  'Library',
  'Application Support',
  'Google',
  product,
  'NativeMessagingHosts',
  'com.owaisquadri.yoink.json',
))
await Promise.all(manifestPaths.map((path) => rm(path, { force: true })))
await rm(join(appRoot, 'bin', 'yoink-native-host'), { force: true })
await rm(join(appRoot, 'daemon.sock'), { force: true })
process.stdout.write('Yoink native host removed. Completed downloads and job history were kept.\n')
