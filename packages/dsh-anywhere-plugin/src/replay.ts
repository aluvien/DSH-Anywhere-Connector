export interface SequencedEvent<T = unknown> {
  readonly sequence: number
  readonly event: T
}

export class ReplayBuffer<T> {
  private readonly entries: SequencedEvent<T>[] = []
  private nextSequence = 1

  constructor(private readonly capacity: number) {
    if (!Number.isSafeInteger(capacity) || capacity < 1) {
      throw new TypeError('ReplayBuffer capacity must be a positive safe integer')
    }
  }

  append(event: T, retain = true): SequencedEvent<T> {
    const entry = { sequence: this.nextSequence++, event }
    if (retain) {
      this.entries.push(entry)
      if (this.entries.length > this.capacity) this.entries.shift()
    }
    return entry
  }

  after(sequence: number): readonly SequencedEvent<T>[] {
    if (!Number.isSafeInteger(sequence) || sequence < 0) return []
    return this.entries.filter(entry => entry.sequence > sequence)
  }

  get latestSequence(): number {
    return this.nextSequence - 1
  }
}
