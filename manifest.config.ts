import { defineManifest } from '@crxjs/vite-plugin'
import pkg from './package.json'

export default defineManifest({
  manifest_version: 3,
  name: 'Yoink',
  description: 'Detect and download video streams from almost any website.',
  version: pkg.version,
  key: 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmp6Ir92kVPsgfNWoL6LJOWqz53ZBVkVmgDOGwnrqvnG6wnb7Wv64zTqdRRhHs+XIpIcONpqQDSjPebo5Y1PIZzcesQpB0mEZXO+72ImKEW9yn/q3JymIbwcbxPSDkIrxYgRvSPP6+xHvtrdrbESfv0DoKQcOZUL5CZz2QHKTSqzKO2Z/sGD79BEk76RmHO7q22TiLNhQfSAYKb9ePF6BABBSg77F8O9NFH4YeAesDQbJG6URINOxq3CMua4lB+F263YN30lYkAxnVuy+j66EeoBatg+O6N+ybjnOLMlV81ur4MOa/tcGCETvuDgKaPORudx8Yd7RmRR0DX+Ajy7JFQIDAQAB',
  minimum_chrome_version: '116',
  icons: {
    16: 'public/icons/icon16.png',
    48: 'public/icons/icon48.png',
    128: 'public/icons/icon128.png',
  },
  action: {
    default_popup: 'src/popup/index.html',
    default_icon: {
      16: 'public/icons/icon16.png',
      48: 'public/icons/icon48.png',
      128: 'public/icons/icon128.png',
    },
  },
  options_ui: {
    page: 'src/options/index.html',
    open_in_tab: true,
  },
  background: {
    service_worker: 'src/background/index.ts',
    type: 'module',
  },
  content_scripts: [
    {
      matches: ['<all_urls>'],
      js: ['src/content/index.ts'],
      all_frames: true,
      match_about_blank: true,
      run_at: 'document_idle',
    },
  ],
  permissions: ['activeTab', 'webRequest', 'webNavigation', 'downloads', 'storage', 'scripting', 'tabs', 'offscreen', 'debugger', 'nativeMessaging', 'alarms'],
  host_permissions: ['<all_urls>'],
})
