// Direct TCP socket transport for connecting to a host's direct address.

import { connect, type Socket } from 'node:net'
import type { DirectAddress } from '@shared/remote/protocol'
import type { Transport } from '@shared/remote/transport'
import { CLOSE_GRACE_MS } from './limits'
import { streamTransport } from './stream-transport'

/** TCP keepalive, so the session of a host that left the network without a word ends. */
const KEEPALIVE_MS = 30_000

const SOCKET_OPTIONS = { noDelay: true, keepAlive: true, keepAliveInitialDelay: KEEPALIVE_MS }

/** A socket's transport, whose close gives up on an end that does not close in turn. */
function socketTransport(socket: Socket): Transport {
  const transport = streamTransport(socket)
  return {
    ...transport,
    close: () => {
      transport.close()
      setTimeout(() => socket.destroy(), CLOSE_GRACE_MS).unref()
    },
  }
}

/**
 * Connects to a host's direct address; it rejects when the connection cannot be made, or when
 * `signal` aborts before it is.
 */
export function connectTransport(address: DirectAddress, signal?: AbortSignal): Promise<Transport> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason)
    const socket = connect({ host: address.host, port: address.port, ...SOCKET_OPTIONS })
    const abort = (): void => {
      socket.destroy()
      reject(signal!.reason)
    }
    const failed = (error: Error): void => {
      signal?.removeEventListener('abort', abort)
      reject(error)
    }
    signal?.addEventListener('abort', abort, { once: true })
    socket.once('error', failed)
    socket.once('connect', () => {
      signal?.removeEventListener('abort', abort)
      socket.off('error', failed)
      resolve(socketTransport(socket))
    })
  })
}
