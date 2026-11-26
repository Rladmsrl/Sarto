// How a host is reached, whatever carries it: a utility process's MessagePorts in the desktop app,
// the IPC of `child_process.fork` and a local socket under Node.js.

/** One client's port to a host, carrying plain JSON values both ways. */
export interface PortChannel<Out = unknown> {
  /** Sends a message; a channel that encodes it says how many bytes it wrote. */
  send(message: Out): number | void
  /**
   * How a channel that writes bytes encodes a message, the same function for every channel of its
   * kind, so a message written to many of them is encoded once (`sendEncoded`).
   */
  encode?: (message: Out) => Uint8Array
  /** Writes a message as `encode` encoded it. */
  sendEncoded?(encoded: Uint8Array): void
  /** Messages that arrive before a listener is set wait for it. */
  onMessage(listener: (data: unknown) => void): void
  onClose(listener: () => void): void
  close(): void
}

/** A host's link to the process that started it: that process's messages in, the host's out. */
export interface ControlChannel<In, Out> {
  send(message: Out): void
  onMessage(listener: (message: In) => void): void
}
