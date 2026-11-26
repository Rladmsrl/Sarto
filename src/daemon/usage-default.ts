// Sarto counts the agents' own logs by default: its usage overview, quotas and forecasts are the
// daemon's to compute, so a daemon with Usage on this computer off has little to show. Sarto's
// default stays off, so the daemon turns the setting on once per data folder instead, for a new
// install and one from before alike, and records that it did in `state/sarto-defaults.json`;
// turning it off afterwards is never undone.

import path from 'node:path'
import type { SettingsFile } from '@shared/settings'
import { readJsonFile, writeFileAtomic } from '../core/json-file'

const USAGE_DEFAULT = 'usage.fromComputer'

export function sartoDefaultsPath(data: string): string {
  return path.join(data, 'state', 'sarto-defaults.json')
}

/** The Sarto defaults applied to this data folder before; none for a missing or odd file. */
async function appliedDefaults(file: string): Promise<string[]> {
  const read = await readJsonFile(file)
  if (read.kind !== 'ok' || typeof read.value !== 'object' || read.value === null) return []
  const { applied } = read.value as { applied?: unknown }
  return Array.isArray(applied) ? applied.filter((item) => typeof item === 'string') : []
}

/**
 * Whether this run applies the usage default: true once per data folder, recorded before it is
 * applied, so a file that cannot be written leaves the setting alone and a later run never applies
 * it again.
 */
export async function claimUsageDefault(data: string): Promise<boolean> {
  const file = sartoDefaultsPath(data)
  const applied = await appliedDefaults(file)
  if (applied.includes(USAGE_DEFAULT)) return false
  await writeFileAtomic(
    file,
    `${JSON.stringify({ version: 1, applied: [...applied, USAGE_DEFAULT] })}\n`,
    0o600,
  )
  return true
}

export interface DefaultsSettings {
  get(): SettingsFile
  update(patch: { usage: { fromComputer: boolean } }): void
}

/** Turns Usage on this computer on; returns whether it was off. */
export function applyUsageDefault(settings: DefaultsSettings): boolean {
  if (settings.get().usage.fromComputer) return false
  settings.update({ usage: { fromComputer: true } })
  return true
}
