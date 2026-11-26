import { describe, expect, it } from 'vitest'
import { FrameFanout, type StreamFrame } from './stream'

const data = new Uint8Array(1)

function fanout(window: number) {
  const sent: StreamFrame[] = []
  let wanted = 0
  const frames = new FrameFanout(
    (_port, frame) => sent.push(frame),
    () => wanted++,
    window,
  )
  return {
    frames,
    sent,
    kinds: () => sent.map((frame) => frame.kind),
    wanted: () => wanted,
    ackAll: () => frames.ack('port', sent.at(-1)!.seq),
  }
}

describe('frame fan-out', () => {
  it('skips ahead for a port that falls behind and resumes at the next keyframe', () => {
    const stream = fanout(2)
    stream.frames.push('description', data)
    stream.frames.push('key', data)
    stream.frames.add('port')
    expect(stream.kinds()).toEqual(['description', 'key'])

    // Nothing acknowledged: the port is behind after two frames, and many pass it by.
    for (let i = 0; i < 50; i++) stream.frames.push('delta', data)
    expect(stream.kinds()).toEqual(['description', 'key', 'delta', 'delta'])
    expect(stream.wanted()).toBeGreaterThan(0)

    stream.ackAll()
    expect(stream.frames.starved).toBe(true)
    // The frames it was never sent are not held against it when the stream starts again.
    stream.frames.push('description', data)
    stream.frames.push('key', data)
    expect(stream.kinds().slice(4)).toEqual(['description', 'key'])
    expect(stream.frames.starved).toBe(false)

    stream.ackAll()
    stream.frames.push('delta', data)
    expect(stream.kinds().at(-1)).toBe('delta')
  })

  it('is not starved while a waiting port still has frames to acknowledge', () => {
    const stream = fanout(2)
    stream.frames.push('description', data)
    stream.frames.push('key', data)
    stream.frames.add('port')
    for (let i = 0; i < 3; i++) stream.frames.push('delta', data)
    expect(stream.frames.starved).toBe(false)
  })

  it('drops the replay group once it exceeds the replay limit', () => {
    const stream = fanout(4)
    stream.frames.push('description', data)
    stream.frames.push('seed', data)
    stream.frames.push('key', data)
    for (let i = 0; i < 239; i++) stream.frames.push('delta', data)
    // At exactly 240 frames (1 key + 239 deltas), a joining port replays the group.
    stream.frames.add('within')
    expect(stream.sent).toHaveLength(241)
    expect(stream.wanted()).toBe(0)

    stream.sent.length = 0
    // One more delta passes the replay limit, clearing the group so deltas do not accumulate.
    for (let i = 0; i < 100; i++) stream.frames.push('delta', data)
    stream.sent.length = 0
    const wantedBefore = stream.wanted()
    stream.frames.add('late')
    expect(stream.kinds()).toEqual(['description', 'seed'])
    expect(stream.wanted()).toBe(wantedBefore + 1)
  })
})
