import type { SyncedHostUsageSection, SyncedUsageRecord } from '@shared/sync/protocol'
import type { UsageDeviceIds } from './device-key'

/** Maps previous storage keys to today's id, even before the first local export. */
export function usageAliases(
  records: SyncedUsageRecord[],
  self: UsageDeviceIds,
): Map<string, string> {
  const aliases = new Map<string, string>()
  if (self.previousDeviceId) aliases.set(self.previousDeviceId, self.deviceId)
  for (const { host, deviceId } of records) {
    const previous = host?.previousDeviceId
    if (deviceId === self.deviceId || deviceId === self.previousDeviceId) continue
    if (
      typeof previous === 'string' &&
      /^[0-9a-f]{16}$/.test(previous) &&
      previous !== deviceId &&
      previous !== self.deviceId &&
      previous !== self.previousDeviceId
    ) {
      aliases.set(previous, deviceId)
    }
  }
  return aliases
}

export function mergeUsageRecords(
  local: SyncedUsageRecord | undefined,
  remote: SyncedUsageRecord,
): SyncedUsageRecord {
  if (!local) return remote
  const island =
    local.island && remote.island
      ? local.island.updatedAt >= remote.island.updatedAt
        ? local.island
        : remote.island
      : (local.island ?? remote.island)
  const host =
    local.host && remote.host
      ? local.host.updatedAt >= remote.host.updatedAt
        ? local.host
        : remote.host
      : (local.host ?? remote.host)
  return {
    v: 1,
    deviceId: remote.deviceId,
    deviceName: remote.updatedAt >= local.updatedAt ? remote.deviceName : local.deviceName,
    updatedAt: Math.max(local.updatedAt, remote.updatedAt),
    ...(island ? { island } : {}),
    ...(host ? { host } : {}),
  }
}

export function logicalUsageRecords(
  records: SyncedUsageRecord[],
  self: UsageDeviceIds,
): SyncedUsageRecord[] {
  const aliases = usageAliases(records, self)
  const byId = new Map(records.filter((r) => !aliases.has(r.deviceId)).map((r) => [r.deviceId, r]))
  for (const record of records) {
    const id = aliases.get(record.deviceId)
    if (id) byId.set(id, mergeUsageRecords(byId.get(id), { ...record, deviceId: id }))
  }
  return [...byId.values()]
}

export function remoteUsageHosts(
  records: SyncedUsageRecord[],
  self: UsageDeviceIds,
): Record<string, SyncedHostUsageSection> {
  const hosts: Record<string, SyncedHostUsageSection> = Object.create(null)
  for (const { deviceId, deviceName, host } of logicalUsageRecords(records, self)) {
    if (deviceId !== self.deviceId && host) hosts[deviceId] = { ...host, deviceName }
  }
  return hosts
}
