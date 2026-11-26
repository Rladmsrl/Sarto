import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { DEFAULT_SETTINGS, type SettingsFile } from '@shared/settings'
import { writeFileAtomic } from '../core/json-file'
import { applyUsageDefault, claimUsageDefault, sartoDefaultsPath } from './usage-default'

let data: string
beforeEach(() => {
  data = mkdtempSync(path.join(tmpdir(), 'sarto-defaults-'))
})
afterEach(() => rmSync(data, { recursive: true, force: true }))

function settings(fromComputer: boolean) {
  let current: SettingsFile = {
    ...DEFAULT_SETTINGS,
    usage: { ...DEFAULT_SETTINGS.usage, fromComputer },
  }
  return {
    get: () => current,
    update(patch: { usage: { fromComputer: boolean } }) {
      current = { ...current, usage: { ...current.usage, ...patch.usage } }
    },
  }
}

/** One daemon start: claims the default, then applies it if this run may. */
async function start(store: ReturnType<typeof settings>): Promise<boolean> {
  return (await claimUsageDefault(data)) && applyUsageDefault(store)
}

describe("Sarto's default for Usage on this computer", () => {
  it('turns it on once for a folder that had it off, and never again after it is turned off', async () => {
    const store = settings(false)
    expect(await start(store)).toBe(true)
    expect(store.get().usage.fromComputer).toBe(true)
    expect(JSON.parse(readFileSync(sartoDefaultsPath(data), 'utf8'))).toEqual({
      version: 1,
      applied: ['usage.fromComputer'],
    })
    store.update({ usage: { fromComputer: false } })
    expect(await start(store)).toBe(false)
    expect(store.get().usage.fromComputer).toBe(false)
  })

  it('records the default for a folder that has it on already, so a later off stays', async () => {
    const store = settings(true)
    expect(await start(store)).toBe(false)
    store.update({ usage: { fromComputer: false } })
    expect(await start(store)).toBe(false)
    expect(store.get().usage.fromComputer).toBe(false)
  })

  it('keeps the other defaults a newer daemon recorded, and an odd file counts as none', async () => {
    await writeFileAtomic(
      sartoDefaultsPath(data),
      JSON.stringify({ version: 1, applied: ['something.else'] }),
    )
    expect(await claimUsageDefault(data)).toBe(true)
    expect(JSON.parse(readFileSync(sartoDefaultsPath(data), 'utf8')).applied).toEqual([
      'something.else',
      'usage.fromComputer',
    ])
    await writeFileAtomic(sartoDefaultsPath(data), 'not json')
    expect(await claimUsageDefault(data)).toBe(true)
  })
})
