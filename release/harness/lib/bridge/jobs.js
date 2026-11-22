import { JobsChangedPayloadSchema } from '../protocol/index.js';
function record(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : {};
}
export class JobControlMirror {
    publish;
    sessions = new Map();
    constructor(publish) {
        this.publish = publish;
    }
    snapshot() { return [...this.sessions.values()]; }
    apply(value) {
        const frame = record(value);
        if (frame.type === 'jobs' && typeof frame.sessionId === 'string') {
            this.replace(frame.sessionId, frame.jobs);
        }
        else if (frame.type === 'baseline') {
            const baseline = record(frame.value);
            if (baseline.jobs === null || typeof baseline.jobs !== 'object' || Array.isArray(baseline.jobs))
                return;
            const jobs = record(baseline.jobs);
            for (const sessionId of this.sessions.keys()) {
                if (!Object.hasOwn(jobs, sessionId))
                    this.replace(sessionId, []);
            }
            for (const [sessionId, rows] of Object.entries(jobs))
                this.replace(sessionId, rows);
        }
    }
    disconnect() {
        for (const [sessionId, state] of this.sessions) {
            const unavailable = { ...state, available: false };
            this.sessions.set(sessionId, unavailable);
            this.publish(unavailable);
        }
    }
    replace(sessionId, jobs) {
        const parsed = JobsChangedPayloadSchema.safeParse({ sessionId, jobs, available: true });
        if (!parsed.success)
            return;
        this.sessions.set(sessionId, parsed.data);
        this.publish(parsed.data);
    }
}
