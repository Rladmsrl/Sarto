// Synchronizes the active App optical palette (`obsidian` | `warm` | `crystal` | `alabaster`)
// to the signed-in Sarto Cloud account (`PUT /api/v1/me/preferences`) so the web console and
// account pages default to the theme currently active in Sarto.app.

import type { Logger } from '../core/log'
import {
  isCloudAppTheme,
  type CloudAccount,
  type CloudAccountPreferences,
  type CloudAppTheme,
} from './cloud-account'

export interface CloudThemeSyncDeps {
  cloud: CloudAccount
  log: Logger
}

export class CloudThemeSync {
  private pendingTheme: CloudAppTheme | null = null
  private lastSyncedTheme = new Map<string, CloudAppTheme>()
  private inFlight: Promise<void> | null = null
  private stopping = false

  constructor(private readonly deps: CloudThemeSyncDeps) {}

  private signedInAccountId(): string | null {
    return this.deps.cloud.account().signedIn()?.id ?? null
  }

  /** Records the Mac app's active palette and pushes it to the cloud account when signed in. */
  noteAppTheme(raw: unknown): void {
    if (!isCloudAppTheme(raw)) return
    this.pendingTheme = raw
    void this.pushIfNeeded().catch(() => {})
  }

  /** Re-syncs the active palette whenever the account signs in. */
  noteAccountChanged(): void {
    const accountId = this.signedInAccountId()
    if (!accountId) return
    void this.pushIfNeeded().catch(() => {})
  }

  async getPreferences(): Promise<CloudAccountPreferences> {
    const accountId = this.signedInAccountId()
    const prefs = await this.deps.cloud.preferences()
    if (accountId && prefs.appTheme) {
      this.lastSyncedTheme.set(accountId, prefs.appTheme)
    }
    return prefs
  }

  async setAppTheme(appTheme: CloudAppTheme | null): Promise<CloudAccountPreferences> {
    const accountId = this.signedInAccountId()
    const prefs = await this.deps.cloud.updatePreferences({ appTheme })
    if (appTheme) this.pendingTheme = appTheme
    if (accountId) {
      if (prefs.appTheme) this.lastSyncedTheme.set(accountId, prefs.appTheme)
      else this.lastSyncedTheme.delete(accountId)
    }
    return prefs
  }

  async pushIfNeeded(): Promise<void> {
    if (this.stopping) return
    if (this.inFlight) return this.inFlight
    const task = this.flush().finally(() => {
      if (this.inFlight === task) this.inFlight = null
    })
    this.inFlight = task
    return task
  }

  private async flush(): Promise<void> {
    while (!this.stopping) {
      const accountId = this.signedInAccountId()
      const theme = this.pendingTheme
      if (!accountId || !theme) return
      if (this.lastSyncedTheme.get(accountId) === theme) return
      try {
        const updated = await this.deps.cloud.updatePreferences({ appTheme: theme })
        this.lastSyncedTheme.set(accountId, updated.appTheme ?? theme)
      } catch (error) {
        this.deps.log.warn(`Could not sync app theme to cloud: ${(error as Error).message}`)
        return
      }
    }
  }

  stop(): void {
    this.stopping = true
  }
}
