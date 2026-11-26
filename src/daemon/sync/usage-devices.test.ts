import { expect, it } from 'vitest'
import type { SyncedUsageRecord } from '@shared/sync/protocol'
import { usageDeviceIds } from './device-key'
import { remoteUsageHosts } from './usage-devices'

const current = '1234567890abcdef'
const previous = 'fedcba0987654321'
const mini = '0123456789abcdef'

function record(deviceId: string, updatedAt: number, previousDeviceId?: string): SyncedUsageRecord {
  return {
    v: 1,
    deviceId,
    deviceName: 'Mac',
    updatedAt,
    host: { updatedAt, computerSources: {}, fromComputer: true, buckets: [], previousDeviceId },
  }
}

it('derives both generations of usage id from the same hardware UUID', () => {
  expect(usageDeviceIds('hardware-uuid', 'sync-key')).toEqual({
    deviceId: '2b197fb254b2563b',
    previousDeviceId: '5d67beee6746cbce',
  })
})

it('excludes both local ids even before the first export, keeping a same-name peer', () => {
  expect(
    Object.keys(
      remoteUsageHosts([record(previous, 1), record(mini, 2)], {
        deviceId: current,
        previousDeviceId: previous,
      }),
    ),
  ).toEqual([mini])
})

it('uses the freshest host snapshot of a peer across a change of id', () => {
  for (const oldTime of [1, 3]) {
    const records = [record(previous, oldTime), record(current, 2, previous), record(mini, 3)]
    for (const ordered of [records, [...records].reverse()]) {
      const hosts = remoteUsageHosts(ordered, { deviceId: mini })
      expect(Object.keys(hosts)).toEqual([current])
      expect(hosts[current]?.updatedAt).toBe(Math.max(oldTime, 2))
    }
  }
})
