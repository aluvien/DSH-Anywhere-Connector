import { describe, expect, it } from 'vitest'
import { ReplayBuffer } from './replay.js'

describe('ReplayBuffer', () => {
  it('assigns monotonic sequences and replays after a cursor', () => {
    const buffer = new ReplayBuffer<string>(3)
    buffer.append('a')
    buffer.append('b')
    buffer.append('c')
    buffer.append('d')
    expect(buffer.after(1)).toEqual([
      { sequence: 2, event: 'b' },
      { sequence: 3, event: 'c' },
      { sequence: 4, event: 'd' },
    ])
    expect(buffer.after(3)).toEqual([{ sequence: 4, event: 'd' }])
  })
})
