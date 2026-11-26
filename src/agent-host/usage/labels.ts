// A quota window's name in the host's language, as the plan limits name theirs.

import type { QuotaWindow } from '@shared/usage'
import { t } from '../i18n'

const DAY = 24 * 60

function lengthLabel(minutes: number | null, window: QuotaWindow): string {
  if (minutes === 300) return t('planWindow.five_hour')
  if (minutes === 7 * DAY) return t('planWindow.seven_day')
  if (minutes === DAY) return t('planWindow.daily')
  if (minutes !== null) {
    if (minutes < 60) return t('planWindow.minutes', { count: minutes })
    if (minutes < DAY) return t('planWindow.hours', { count: Math.round(minutes / 60) })
    if (minutes < 7 * DAY) return t('planWindow.days', { count: Math.round(minutes / DAY) })
    return minutes <= 31 * DAY ? t('planWindow.monthly') : t('planWindow.annual')
  }
  if (window.kind === 'session') return t('planWindow.five_hour')
  if (window.kind === 'weekly' || window.kind === 'scoped') return t('planWindow.seven_day')
  return window.id
}

export function windowLabel(window: QuotaWindow): string {
  const length = lengthLabel(window.minutes, window)
  return window.kind === 'scoped' && window.scope
    ? t('planWindow.scoped', { window: length, scope: window.scope })
    : length
}
