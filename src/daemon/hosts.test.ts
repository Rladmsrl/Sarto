import { describe, expect, it } from 'vitest'
import { NO_ORIGIN, RelayTarget } from './hosts'

const CLOUD = 'https://sarto.example'
const OWN = 'https://sync.home.example'

describe('where the remote host finds the relay and the push gateway', () => {
  it('starts a remote host on the server the sync moved it to, with that server’s token', () => {
    const target = new RelayTarget({ relayUrl: CLOUD, pushUrl: CLOUD })
    // The sync of an earlier sign-in says so before the remote host runs, so nothing is posted.
    target.configure({ url: OWN, pushUrl: OWN, enabled: true, token: 'own-token' })

    expect(target.init(true, null)).toEqual({
      url: OWN,
      enabled: true,
      token: 'own-token',
      relayToken: null,
    })
    expect(target.pushUrl).toBe(OWN)
    // And again at each restart of the remote host.
    expect(target.init(true, 'seed')).toMatchObject({ url: OWN, token: 'own-token', key: 'seed' })
  })

  it('never keeps a token for a server it was not given for', () => {
    const target = new RelayTarget({ relayUrl: CLOUD, pushUrl: CLOUD })
    target.configure({
      url: OWN,
      pushUrl: OWN,
      enabled: true,
      token: 'own-token',
      relayToken: 'own-relay',
      discoverable: true,
    })

    expect(target.reset(true)).toEqual({
      type: 'remote-host:relay-config',
      url: CLOUD,
      pushUrl: CLOUD,
      enabled: true,
      token: null,
      relayToken: null,
      discoverable: false,
    })
    expect(target.init(true, null)).toEqual({
      url: CLOUD,
      enabled: true,
      token: null,
      relayToken: null,
    })

    target.setTokens('account-token', 'account-relay')
    target.configure({ url: OWN, pushUrl: OWN, enabled: true, token: 'own-token' })
    expect(target.init(true, null)).toMatchObject({ token: 'own-token', relayToken: null })
  })

  it('goes back to its own relay with the setting, not to an address nothing answers on', () => {
    const target = new RelayTarget({ relayUrl: CLOUD, pushUrl: CLOUD })
    target.configure({ url: OWN, pushUrl: OWN, enabled: true, token: 'own-token' })
    expect(target.reset(false)).toMatchObject({ url: CLOUD, pushUrl: CLOUD, enabled: false })
    expect(target.relayUrl).toBe(CLOUD)
    expect(target.pushUrl).toBe(CLOUD)
  })

  it('has no relay for the run when it is off, wherever a later change points', () => {
    const target = new RelayTarget({ relayUrl: null, pushUrl: CLOUD })
    expect(target.init(true, null)).toBeNull()
    expect(
      target.configure({ url: OWN, pushUrl: OWN, enabled: true, token: 'own-token' }),
    ).toMatchObject({ url: '', enabled: false, pushUrl: OWN })
    expect(target.init(true, null)).toBeNull()
    expect(target.relayUrl).toBeNull()
  })

  it('sends pushes nowhere for the run when the push gateway is off', () => {
    const target = new RelayTarget({ relayUrl: CLOUD, pushUrl: null })
    expect(target.pushUrl).toBe(NO_ORIGIN)
    expect(
      target.configure({ url: OWN, pushUrl: OWN, enabled: true, token: 'own-token' }),
    ).toMatchObject({ url: OWN, pushUrl: NO_ORIGIN })
    expect(target.reset(true)).toMatchObject({ url: CLOUD, pushUrl: NO_ORIGIN })
  })
})
