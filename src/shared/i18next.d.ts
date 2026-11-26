// Types every `t()` call against the English catalog. Add a namespace here when you add its files.

import 'i18next'
import type common from './locales/en/common.json'
import type host from './locales/en/host.json'
import type hosts from './locales/en/hosts.json'
import type island from './locales/en/island.json'
import type main from './locales/en/main.json'
import type session from './locales/en/session.json'
import type settings from './locales/en/settings.json'
import type usage from './locales/en/usage.json'
import type viewers from './locales/en/viewers.json'

declare module 'i18next' {
  interface CustomTypeOptions {
    defaultNS: 'common'
    returnNull: false
    resources: {
      common: typeof common
      host: typeof host
      hosts: typeof hosts
      island: typeof island
      main: typeof main
      session: typeof session
      settings: typeof settings
      usage: typeof usage
      viewers: typeof viewers
    }
  }
}
