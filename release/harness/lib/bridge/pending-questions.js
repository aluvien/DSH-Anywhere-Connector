import { randomBytes } from 'node:crypto';
/** The host user-question seam restores this wire-safe error into its own
 * UserQuestionError instance, preserving the plan tool's ASK_CANCELLED path. */
export class QuestionCancelledError extends Error {
    code = 'ASK_CANCELLED';
    constructor() { super('The user dismissed the question to continue the conversation'); this.name = 'UserQuestionError'; }
}
export function isQuestionCancellation(value) {
    return value instanceof Error && value.name === 'UserQuestionError' &&
        'code' in value && value.code === 'ASK_CANCELLED';
}
/**
 * Mirrors PendingApprovals: the answerer publishes a question to the paired
 * device and parks the model's tool call until the phone answers, the request
 * is aborted, or the deadline passes. Every question must settle, because the
 * `ask_user_question` tool awaits this promise before it can continue.
 */
export class PendingQuestions {
    pending = new Map();
    create(timeoutMs, signal) {
        const id = `question_${randomBytes(12).toString('base64url')}`;
        let settle;
        let fail;
        const result = new Promise((resolve, reject) => {
            settle = resolve;
            fail = reject;
        });
        const timer = setTimeout(() => this.reject(id, new Error('the user did not answer before the question expired')), timeoutMs);
        const onAbort = signal === undefined
            ? undefined
            : () => this.reject(id, new Error('the question was cancelled before the user answered'));
        signal?.addEventListener('abort', onAbort, { once: true });
        this.pending.set(id, {
            resolve: settle,
            reject: fail,
            timer,
            ...(signal === undefined ? {} : { signal }),
            ...(onAbort === undefined ? {} : { onAbort }),
        });
        return { id, result };
    }
    answer(id, answers) {
        const item = this.take(id);
        if (item === undefined)
            return false;
        item.resolve(answers);
        return true;
    }
    reject(id, error) {
        const item = this.take(id);
        if (item === undefined)
            return false;
        item.reject(error);
        return true;
    }
    cancel(id) { return this.reject(id, new QuestionCancelledError()); }
    rejectAll(error) {
        for (const id of [...this.pending.keys()])
            this.reject(id, error);
    }
    /**
     * Releases a question without settling it, for when another surface answered
     * first. The phone's card is dismissed by `question.resolved`, and a late tap
     * on it then fails the `answer()` lookup instead of resolving a dead promise.
     */
    discard(id) {
        this.take(id);
    }
    take(id) {
        const item = this.pending.get(id);
        if (item === undefined)
            return undefined;
        this.pending.delete(id);
        clearTimeout(item.timer);
        if (item.signal !== undefined && item.onAbort !== undefined) {
            item.signal.removeEventListener('abort', item.onAbort);
        }
        return item;
    }
}
/**
 * Resolves with the first surface that actually produces an answer.
 *
 * Both the phone and the browser UI are offered the same question, and a
 * surface that has nobody listening must not end the wait on its own:
 *
 * - the phone resolves `undefined` when the question expires or is aborted;
 * - the browser rejects when no UI answerer is registered at all (nobody has
 *   the Harness page open), and also rejects when the request is aborted.
 *
 * Only when both surfaces have gone quiet is the question genuinely
 * unanswerable, which is the one case this resolves `undefined` for. In
 * particular, a browser that rejects immediately must not cut short a phone
 * that is still able to answer.
 */
export async function firstAnswered(phone, browser, isAnswer = () => true) {
    return await new Promise((resolve, reject) => {
        let phoneOpen = true;
        let browserOpen = true;
        const resolveIfBothClosed = () => {
            if (!phoneOpen && !browserOpen)
                resolve(undefined);
        };
        phone.then((answer) => {
            phoneOpen = false;
            if (answer === undefined || !isAnswer(answer))
                resolveIfBothClosed();
            else
                resolve(answer);
        }, (error) => {
            if (isQuestionCancellation(error)) {
                reject(error);
                return;
            }
            phoneOpen = false;
            resolveIfBothClosed();
        });
        browser.then((answer) => {
            browserOpen = false;
            if (isAnswer(answer))
                resolve(answer);
            else
                resolveIfBothClosed();
        }, (error) => {
            if (isQuestionCancellation(error)) {
                reject(error);
                return;
            }
            browserOpen = false;
            resolveIfBothClosed();
        });
    });
}
