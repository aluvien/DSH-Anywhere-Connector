import { JobsChangedPayloadSchema } from '@dsh-anywhere/protocol'

// The native control stream owns the complete per-session list. This mirror
// retains only the latest list so a newly connected phone gets a baseline.
type JobState = ReturnType<typeof JobsChangedPayloadSchema.parse>
function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

export class JobControlMirror {
  private readonly sessions = new Map<string, JobState>()
  constructor(private readonly publish: (state: JobState) => void) {}

  snapshot(): readonly JobState[] { return [...this.sessions.values()] }

  apply(value: unknown): void {
    const frame = record(value)
    if (frame.type === 'jobs' && typeof frame.sessionId === 'string') {
      this.replace(frame.sessionId, frame.jobs)
    } else if (frame.type === 'baseline') {
      const baseline = record(frame.value)
      if (baseline.jobs === null || typeof baseline.jobs !== 'object' || Array.isArray(baseline.jobs)) return
      const jobs = record(baseline.jobs)
      for (const sessionId of this.sessions.keys()) {
        if (!Object.hasOwn(jobs, sessionId)) this.replace(sessionId, [])
      }
      for (const [sessionId, rows] of Object.entries(jobs)) this.replace(sessionId, rows)
    }
  }

  disconnect(): void {
    for (const [sessionId, state] of this.sessions) {
      const unavailable = { ...state, available: false }
      this.sessions.set(sessionId, unavailable)
      this.publish(unavailable)
    }
  }

  private replace(sessionId: string, jobs: unknown): void {
    const parsed = JobsChangedPayloadSchema.safeParse({ sessionId, jobs, available: true })
    if (!parsed.success) return
    this.sessions.set(sessionId, parsed.data)
    this.publish(parsed.data)
  }
}
