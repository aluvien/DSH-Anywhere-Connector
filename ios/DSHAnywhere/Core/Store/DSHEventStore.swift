import Foundation

public struct DSHStoreState: Codable, Sendable, Equatable {
    public var sessions: [DSHSessionSummary] = []
    /// Prevents the home screen from showing an empty-state flash while the
    /// first authoritative snapshot is still travelling over the socket.
    public var hasLoadedSessions = false
    public var messagesBySession: [String: [DSHChatMessage]] = [:]
    public var toolsBySession: [String: [DSHToolActivity]] = [:]
    public var pendingApprovals: [DSHApprovalRequest] = []
    public var pendingQuestions: [DSHQuestionRequest] = []
    public var decisionVersion: DSHDecisionVersion?
    public var retiredDecisionEpochs: [String]?
    public var planBySession: [String: DSHPlanState]?
    public var planProjections: [String: DSHPlanProjection]?
    public var retiredPlanEpochs: [String: [String]]?
    public var todoBySession: [String: DSHTodoState]?
    public var workflowsBySession: [String: [DSHWorkflowRun]]?
    public var executionBySession: [String: [DSHExecutionRecord]]?
    public var historyCoverage: [String: DSHHistoryCoverage]?
    public var schedulesBySession: [String: DSHScheduleProjection]?
    public var retiredScheduleEpochs: [String: [String]]?
    public var feedbackBySession: [String: DSHFeedbackState]?
    public var feedbackReceipts: [String: DSHFeedbackReceipt]?
    public var jobsBySession: [String: DSHJobsState]?
    public var serverQueues: [String: DSHServerQueue]?
    public var queueReceipts: [String: DSHQueueUpdated]?
    public var subagentCatalogs: [String: DSHSubagentCatalog]?
    public var subagentReceipts: [String: DSHSubagentReceipt]?
    public var forksByRequestID: [String: DSHSessionForked]?
    public var commandCatalogs: [String: DSHCommandCatalog]?
    public var goalBySession: [String: DSHGoalState]?
    public var liveGoalSessions: Set<String>?
    public var goalReceipts: [String: DSHGoalUpdated]?
    public var turnStateBySession: [String: String] = [:]
    public var modelCatalog: DSHModelCatalog?
    /// Workspace and mode catalogs are complete, remote-owned lists. They are
    /// separate from session snapshots so empty workspaces still render.
    public var workspaceCatalog: [DSHWorkspaceOption] = []
    public var modeCatalog: DSHModeCatalog?
    public var directoryListing: DSHDirectoryListing?
    public var usageBySession: [String: DSHSessionUsage] = [:]
    public var permissionBySession: [String: DSHPermissionUpdate] = [:]
    public var metadataBySession: [String: DSHSessionMetadataUpdate] = [:]
    public var modelChangesBySession: [String: [DSHModelChangeNotice]] = [:]
    public var commandResultsBySession: [String: [DSHCommandResult]] = [:]
    public var attachmentsBySession: [String: [DSHUploadedAttachment]] = [:]
    /// Errors are keyed by the request id carried as the error envelope's
    /// message id.  Commands that wait for a correlated reply can fail fast.
    public var protocolErrorsByRequestID: [String: String] = [:]
    /// Transcript rows set aside when a history replay starts.  The replay
    /// rebuilds the session arrays in stored order; on completion the
    /// carried-over rows that the replay did not contain (unpersisted live
    /// output) are appended back.  Keyed by session id.
    public var historyCarryOverBySession: [String: DSHHistoryCarryOver] = [:]
    public var unknownEvents: [DSHEnvelope] = []
    public var lastSequence: Int64 = 0
    /// The socket to the public Relay and the presence of the Mac Connector
    /// are independent. Keeping both prevents a healthy Relay from making an
    /// offline Mac look reachable.
    public var transportState: DSHConnectionState = .disconnected
    public var machineOnline: Bool = false
    /// nil until this Relay connection has supplied authoritative presence.
    public var confirmedMachinePresence: Bool?
    /// `nil` means the Connector is present but the local Harness bridge has
    /// not answered yet. Existing protocol events prove whether it is usable.
    public var bridgeReachable: Bool?
    public var connectionState: DSHConnectionState = .disconnected

    public var isAwaitingInitialSessions: Bool {
        guard !hasLoadedSessions else { return false }
        switch transportState {
        case .failed: return false
        case .connecting, .reconnecting: return true
        case .disconnected, .connected:
            return confirmedMachinePresence != false && bridgeReachable != false
        }
    }

    public init() {}
}

/// Transcript rows held aside while one history replay batch streams.  The
/// replay rebuilds the session arrays in stored order; rows the replay did
/// not contain are unpersisted live output and belong after it.
public struct DSHHistoryCarryOver: Codable, Sendable, Equatable {
    public var batchId: String
    public var messages: [DSHChatMessage] = []
    public var tools: [DSHToolActivity] = []
    public var commandResults: [DSHCommandResult] = []
    public var modelChanges: [DSHModelChangeNotice] = []
    public var replayedTodo: DSHTodoState?
    public var receivedLiveTodo: Bool?

    public init(batchId: String) { self.batchId = batchId }
}

/// Pure, deterministic event reducer.  Keeping this separate from the
/// observable store makes all event ordering and duplicate handling testable.
public struct DSHEventReducer: Sendable {
    public init() {}

    @discardableResult
    public func reduce(_ event: DSHEvent, into state: inout DSHStoreState) -> Bool {
        // Transport controls are local, out-of-band signals and therefore do
        // not participate in the Connector event sequence/replay window.
        switch event.kind {
        case .transportState(let value):
            state.transportState = value
            if value != .connected {
                state.liveGoalSessions = nil
                for (id, _) in state.planProjections ?? [:] { state.planProjections?[id]?.available = false }
                for id in (state.schedulesBySession ?? [:]).keys { state.schedulesBySession?[id]?.available = false }
                for (id, queue) in state.serverQueues ?? [:] {
                    state.serverQueues?[id] = DSHServerQueue(sessionId: id, available: false, items: queue.items)
                }
                for (sessionId, jobs) in state.jobsBySession ?? [:] {
                    state.jobsBySession?[sessionId] = DSHJobsState(sessionId: sessionId, available: false, jobs: jobs.jobs)
                }
                state.machineOnline = false
                state.confirmedMachinePresence = nil
                state.bridgeReachable = nil
                state.connectionState = value
            }
            return true
        case .machinePresence(let online):
            if !online {
                state.liveGoalSessions = nil
                for (id, _) in state.planProjections ?? [:] { state.planProjections?[id]?.available = false }
                for id in (state.schedulesBySession ?? [:]).keys { state.schedulesBySession?[id]?.available = false }
                for (id, queue) in state.serverQueues ?? [:] {
                    state.serverQueues?[id] = DSHServerQueue(sessionId: id, available: false, items: queue.items)
                }
                for (sessionId, jobs) in state.jobsBySession ?? [:] {
                    state.jobsBySession?[sessionId] = DSHJobsState(sessionId: sessionId, available: false, jobs: jobs.jobs)
                }
            }
            state.confirmedMachinePresence = online
            if !online || !state.machineOnline { state.bridgeReachable = nil }
            state.machineOnline = online
            state.connectionState = online ? .connected : .disconnected
            return true
        case .protocolError(let error) where event.envelope.sequence == 0:
            // Relay validation errors can be request-scoped without consuming
            // a Connector replay sequence. Keep the socket healthy and still
            // surface the error to the matching waiter/alert.
            state.protocolErrorsByRequestID[event.envelope.messageId] = error.message
            return true
        default:
            break
        }

        if event.startsNewSequenceEpoch(comparedTo: state.lastSequence) {
            // A bridge/Connector restart resets its in-memory replay buffer to
            // sequence 1.  `session.snapshot` is a complete, authoritative
            // response to a refresh, so it can establish the new epoch even
            // if the preceding connection.ready was not replayed.
            state.lastSequence = 0
        }
        // Sequence numbers are monotonic at the transport boundary. Replaying
        // an old event must not duplicate a message or roll state backwards.
        guard event.sequence > state.lastSequence else { return false }
        state.lastSequence = event.sequence

        return apply(event, into: &state)
    }

    /// Page rows share one transport receipt but retain independent Native
    /// positions. Never rewind the replay watermark to insert old history.
    @discardableResult
    private func apply(_ event: DSHEvent, into state: inout DSHStoreState) -> Bool {

        switch event.kind {
        case .connectionReady:
            state.transportState = .connected
            state.machineOnline = true
            state.confirmedMachinePresence = true
            state.bridgeReachable = true
            state.connectionState = .connected
        case .sessionSnapshot(let sessions):
            state.bridgeReachable = true
            // Only touch the array when the content actually changed. The
            // Connector pushes a snapshot often — on reconnect, on every
            // explicit refresh — and most carry the same sessions. Reassigning
            // anyway made SwiftUI re-diff every row on the home screen, which is
            // what showed up as flicker each time data refreshed.
            if sessions != state.sessions { state.sessions = sessions }
            for session in sessions {
                guard let running = session.running else { continue }
                if running {
                    state.turnStateBySession[session.id] = "running"
                } else if state.turnStateBySession[session.id]?.lowercased() == "running" {
                    state.turnStateBySession[session.id] = "idle"
                }
            }
            state.hasLoadedSessions = true
        case .sessionCreated(let session):
            upsert(session, into: &state.sessions)
        case .userMessageAccepted(let message):
            var stamped = message
            let existingMessage: DSHChatMessage? = event.envelope.sessionId.flatMap { sessionId in
                state.messagesBySession[sessionId]?.first(where: { $0.id == message.id })
            }
            // Attachment thumbnails are supplemented locally immediately
            // after a prompt is accepted.  A later replay of the same row may
            // carry no attachment metadata, so replacing the row wholesale
            // would erase the local files on every refresh.  Prefer
            // authoritative server metadata when it is present; otherwise
            // retain the local supplement.
            if stamped.attachments.isEmpty, let existingMessage,
               !existingMessage.attachments.isEmpty {
                stamped.attachments = existingMessage.attachments
            }
            // First sighting wins: replays (re-open, refresh, reconnect
            // backfill) update content in place but must not renumber the
            // row ahead of live output that followed it.
            if let existing = existingMessage, let existingSequence = existing.sequence {
                stamped.sequence = existingSequence
            } else if stamped.sequence == nil {
                stamped.sequence = event.envelope.sequence
            }
            if let existing = existingMessage, let existingTimestamp = existing.timestamp {
                stamped.timestamp = existingTimestamp
            } else if stamped.timestamp == nil {
                stamped.timestamp = event.envelope.timestamp
            }
            appendOrReplace(stamped, in: &state.messagesBySession, sessionId: event.envelope.sessionId)
        case .assistantMessageCompleted(let message):
            let sessionId = event.envelope.sessionId ?? ""
            let messages = state.messagesBySession[sessionId, default: []]
            let canonical = messages.first { $0.id == message.id }
            let partial = message.replacesMessageId.flatMap { id in messages.first { $0.id == id } }
            let first = [canonical, partial].compactMap { $0 }
                .min { ($0.sequence ?? Int64.max) < ($1.sequence ?? Int64.max) }
            var completed = message
            completed.reasoning = message.reasoning ?? canonical?.reasoning ?? partial?.reasoning
            completed.sequence = first?.sequence ?? event.envelope.sequence
            completed.timestamp = first?.timestamp ?? event.envelope.timestamp
            completed.completedAt = canonical?.completedAt ?? partial?.completedAt
                ?? (event.envelope.historyBatchId == nil ? event.envelope.timestamp : nil)
            completed.taskCompletedAt = canonical?.taskCompletedAt ?? partial?.taskCompletedAt
            if let replaced = message.replacesMessageId, replaced != message.id {
                state.messagesBySession[sessionId]?.removeAll { $0.id == replaced }
                state.historyCarryOverBySession[sessionId]?.messages.removeAll { $0.id == replaced }
            }
            appendOrReplace(completed, in: &state.messagesBySession, sessionId: sessionId)
        case .assistantMessageDiscarded(let discarded):
            let sessionId = event.envelope.sessionId ?? ""
            state.messagesBySession[sessionId]?.removeAll { $0.id == discarded.messageId }
            state.historyCarryOverBySession[sessionId]?.messages.removeAll { $0.id == discarded.messageId }
        case .assistantReasoning(let reasoning):
            let sessionId = event.envelope.sessionId ?? ""
            var messages = state.messagesBySession[sessionId, default: []]
            if let index = messages.firstIndex(where: { $0.id == reasoning.messageId }) {
                messages[index].reasoning = reasoning.text
            } else {
                messages.append(DSHChatMessage(id: reasoning.messageId, role: .assistant,
                                               markdown: "", reasoning: reasoning.text,
                                               sequence: event.envelope.sequence,
                                               timestamp: event.envelope.timestamp))
            }
            state.messagesBySession[sessionId] = messages
        case .assistantMessageDelta(let delta):
            let sessionId = event.envelope.sessionId ?? ""
            var messages = state.messagesBySession[sessionId, default: []]
            if let index = messages.firstIndex(where: { $0.id == delta.messageId }) {
                messages[index].markdown += delta.text
            } else {
                messages.append(DSHChatMessage(id: delta.messageId, role: .assistant, markdown: delta.text,
                                                sequence: event.envelope.sequence,
                                                timestamp: event.envelope.timestamp))
            }
            state.messagesBySession[sessionId] = messages
        case .referenceCandidates:
            break // Discovery replies live only in their requesting picker.
        case .searchResults:
            break
        case .configurationResult, .configurationUpdated, .configurationInvalidated, .configurationModels:
            break // Ephemeral, redacted configuration belongs to its requesting view.
        case .historyWindow(let window):
            guard window.isValid, event.envelope.sessionId == window.sessionId else { break }
            if state.historyCoverage == nil { state.historyCoverage = [:] }
            state.historyCoverage?[window.sessionId, default: .init()].include(window)
        case .historyPage(let page):
            guard let events = page.events(in: event.envelope) else { break }
            for row in events { apply(row, into: &state) }
            state.messagesBySession[page.sessionId] = dshHistoryOrder(state.messagesBySession[page.sessionId] ?? [], native: { $0.nativeSequence })
            if state.historyCoverage == nil { state.historyCoverage = [:] }
            state.historyCoverage?[page.sessionId, default: .init()].include(page.window)
        case .feedbackState(let snapshot):
            guard snapshot.nativeSequence >= (state.feedbackBySession?[snapshot.sessionId]?.nativeSequence ?? -1) else { break }
            if state.feedbackBySession == nil { state.feedbackBySession = [:] }
            state.feedbackBySession?[snapshot.sessionId] = snapshot
        case .feedbackChanged(let change):
            guard change.item == nil || change.item?.messageId == change.messageId else { break }
            var snapshot = state.feedbackBySession?[change.sessionId] ?? DSHFeedbackState(sessionId: change.sessionId, items: [], nativeSequence: -1)
            guard change.nativeSequence > snapshot.nativeSequence else { break }
            snapshot.items.removeAll { $0.messageId == change.messageId }
            if let item = change.item { snapshot.items.append(item) }
            snapshot.nativeSequence = change.nativeSequence
            if state.feedbackBySession == nil { state.feedbackBySession = [:] }
            state.feedbackBySession?[change.sessionId] = snapshot
        case .feedbackUpdated(let receipt):
            if state.feedbackReceipts == nil { state.feedbackReceipts = [:] }
            state.feedbackReceipts?[receipt.requestId] = receipt
        case .toolStarted(let tool):
            var stamped = tool
            if let existing = event.envelope.sessionId.flatMap({ state.toolsBySession[$0]?.first { $0.id == tool.id } }), existing.status != "running" {
                stamped = existing
                if stamped.arguments == nil { stamped.arguments = tool.detail }
                if stamped.startedAt == nil { stamped.startedAt = tool.startedAt }
                if let native = tool.nativeSequence { stamped.nativeSequence = min(stamped.nativeSequence ?? native, native) }
                appendOrReplace(stamped, in: &state.toolsBySession, sessionId: event.envelope.sessionId)
                break
            }
            // The start payload's detail carries the call arguments: keep a
            // copy so the row title ("读取 · path") survives the completion,
            // which replaces detail with the result text.
            if stamped.arguments == nil { stamped.arguments = stamped.detail }
            // Same first-sighting rule as messages: a replayed start must not
            // push its call below live rows that arrived after the first sighting.
            if let sessionId = event.envelope.sessionId,
               let existing = state.toolsBySession[sessionId]?.first(where: { $0.id == tool.id }),
               let existingSequence = existing.sequence {
                stamped.sequence = existingSequence
            } else if stamped.sequence == nil {
                stamped.sequence = event.envelope.sequence
            }
            appendOrReplace(stamped, in: &state.toolsBySession, sessionId: event.envelope.sessionId)
        case .toolCompleted(let tool):
            var stamped = tool
            // Keep the arrival order of the call itself: a completion carries a
            // later sequence but must not jump ahead of calls made after it.
            let existing = event.envelope.sessionId.flatMap { state.toolsBySession[$0] }?
                .first { $0.id == tool.id }
            if let existing {
                stamped.sequence = existing.sequence
                if let native = existing.nativeSequence { stamped.nativeSequence = min(stamped.nativeSequence ?? native, native) }
                // The completion replaces detail with the result text; carry
                // the call arguments forward for the row title.
                if stamped.arguments == nil { stamped.arguments = existing.arguments }
                if stamped.startedAt == nil { stamped.startedAt = existing.startedAt }
                if stamped.parentCallId == nil { stamped.parentCallId = existing.parentCallId }
                if stamped.rootCallId == nil { stamped.rootCallId = existing.rootCallId }
                if stamped.finishedAt == nil { stamped.finishedAt = existing.finishedAt }
                if stamped.resultMeta == nil { stamped.resultMeta = existing.resultMeta }
                if stamped.resultContent == nil { stamped.resultContent = existing.resultContent }
                if stamped.error == nil { stamped.error = existing.error }
                if stamped.attachments == nil { stamped.attachments = existing.attachments }
            } else {
                stamped.sequence = event.envelope.sequence
            }
            appendOrReplace(stamped, in: &state.toolsBySession, sessionId: event.envelope.sessionId)
        case .approvalRequested(let approval):
            guard acceptDecisionVersion(approval.stateVersion, into: &state) else { return false }
            if !state.pendingApprovals.contains(where: { $0.id == approval.id }) {
                state.pendingApprovals.append(approval)
            }
        case .approvalResolved(let resolution):
            guard acceptDecisionVersion(resolution.stateVersion, into: &state) else { return false }
            state.pendingApprovals.removeAll { $0.id == resolution.id }
        case .questionAsked(let request):
            guard acceptDecisionVersion(request.stateVersion, into: &state) else { return false }
            if !state.pendingQuestions.contains(where: { $0.id == request.id }) {
                state.pendingQuestions.append(request)
            }
        case .questionResolved(let resolution):
            guard acceptDecisionVersion(resolution.stateVersion, into: &state) else { return false }
            state.pendingQuestions.removeAll { $0.id == resolution.id }
        case .decisionsSnapshot(let snapshot):
            guard acceptDecisionVersion(snapshot.stateVersion, into: &state) else { return false }
            state.pendingApprovals = snapshot.approvals
            state.pendingQuestions = snapshot.questions
        case .turnStateChanged(let turn):
            // History replays describe a stored terminal state, not the
            // current live turn.  Applying it here can make a running turn
            // look completed while an old transcript is being opened.  The
            // bridge tags every replay event explicitly, so only untagged
            // live events update the projection.
            if event.envelope.historyBatchId == nil {
                let previous = state.turnStateBySession[turn.sessionId]
                state.turnStateBySession[turn.sessionId] = turn.state
                if previous == "running", turn.state != "running",
                   var messages = state.messagesBySession[turn.sessionId],
                   let last = messages.indices.last(where: { messages[$0].role == .assistant }),
                   last > (messages.indices.last(where: { messages[$0].role == .user }) ?? -1) {
                    messages[last].taskCompletedAt = messages[last].taskCompletedAt ?? event.envelope.timestamp
                    state.messagesBySession[turn.sessionId] = messages
                }
            }
        case .modelCatalog(let catalog):
            state.modelCatalog = catalog
        case .workspaceCatalog(let workspaces):
            state.workspaceCatalog = workspaces
        case .workspaceCreated:
            // The create acknowledgement is not a local source of truth. The
            // Connector follows it with workspace.catalog, which replaces the
            // list atomically and includes any server-side normalization.
            break
        case .modeCatalog(let catalog):
            state.modeCatalog = catalog
        case .directoryListing(let listing):
            state.directoryListing = listing
        case .usageUpdated(let update):
            state.usageBySession[update.sessionId] = update.usage
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                state.sessions[index].usage = update.usage
            }
        case .permissionUpdated(let update):
            // Historical replay carries the permission that was in effect
            // for an older turn. It is useful to the history renderer but
            // must never roll the current session's live safety indicator
            // back after the user changed it.
            guard event.envelope.historyBatchId == nil else { break }
            state.permissionBySession[update.sessionId] = update
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                state.sessions[index].permissionMode = update.mode
            }
        case .sessionMetadataUpdated(let update):
            // As with permission, history metadata describes the old turn,
            // not the current provider/model selection.
            guard event.envelope.historyBatchId == nil else { break }
            state.metadataBySession[update.sessionId] = update
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                if let provider = update.provider { state.sessions[index].provider = provider }
                if let model = update.model { state.sessions[index].model = model }
                if let effort = update.reasoningEffort { state.sessions[index].reasoningEffort = effort }
            }
        case .modelChanged(let change):
            var stamped = change
            // 0 means "no sequence yet" for this non-optional field; same
            // first-sighting rule as everything else.
            if let existing = state.modelChangesBySession[change.sessionId]?.first(where: { $0.id == change.id }),
               existing.sequence != 0 {
                stamped.sequence = existing.sequence
            } else if stamped.sequence == 0 {
                stamped.sequence = event.envelope.sequence
            }
            stamped.timestamp = event.envelope.timestamp
            var notices = state.modelChangesBySession[change.sessionId, default: []]
            // History events receive fresh envelope sequence numbers, while
            // their payload describes the same old model change. A matching
            // notice already carried into the replay is therefore the durable
            // identity here; appending it again would also erase a newer,
            // unsent draft when the pre-send batch is collapsed below.
            if notices.contains(where: { $0.id == stamped.id })
                || state.historyCarryOverBySession[change.sessionId]?.modelChanges
                    .contains(where: { sameModelChange($0, stamped) }) == true {
                break
            }
            // A user can try several models while composing one message. Keep
            // only the final choice for that pending send, but preserve older
            // choices once a user message has been accepted so each later turn
            // can still explain the model it used.
            let sendBoundary = state.messagesBySession[change.sessionId, default: []]
                .filter { $0.role == .user }
                .compactMap(\.sequence)
                .max() ?? 0
            notices.removeAll { $0.sequence > sendBoundary }
            notices.append(stamped)
            state.modelChangesBySession[change.sessionId] = notices
        case .commandResult(let result):
            // The command.result payload intentionally stays small and does
            // not carry transport metadata. Stamp the enclosing event's
            // sequence here so the transcript can place the acknowledgement
            // where it happened instead of appending it after every message.
            // Replays keep the first stamp (see userMessageAccepted).
            var stamped = result
            if let existing = state.commandResultsBySession[stamped.sessionId]?.first(where: { $0.id == result.id }),
               let existingSequence = existing.sequence {
                stamped.sequence = existingSequence
            } else if stamped.sequence == nil {
                stamped.sequence = event.envelope.sequence
            }
            // A successful app-initiated permission update has a dedicated
            // `permission.updated` event. Old history batches can still carry
            // its native `/permission` acknowledgement; omit that known
            // success marker from the transcript, while keeping failures
            // visible to the person who made the change.
            guard !isSilentPermissionSetupSuccess(stamped) else { break }
            var values = state.commandResultsBySession[stamped.sessionId, default: []]
            if let index = values.firstIndex(where: { $0.id == stamped.id }) { values[index] = stamped }
            else { values.append(stamped) }
            state.commandResultsBySession[stamped.sessionId] = values
        case .planChanged(let plan):
            if state.planBySession == nil { state.planBySession = [:] }
            state.planBySession?[plan.sessionId] = plan
        case .planProjection(let plan):
            if state.retiredPlanEpochs?[plan.sessionId]?.contains(plan.epoch) == true { return false }
            if let current = state.planProjections?[plan.sessionId] {
                if current.epoch == plan.epoch, current.seq > plan.seq { return false }
                if current.epoch != plan.epoch {
                    if state.retiredPlanEpochs == nil { state.retiredPlanEpochs = [:] }
                    let retired = Array(((state.retiredPlanEpochs?[plan.sessionId] ?? []) + [current.epoch]).suffix(32))
                    state.retiredPlanEpochs?[plan.sessionId] = retired
                }
            }
            if state.planProjections == nil { state.planProjections = [:] }
            state.planProjections?[plan.sessionId] = plan
        case .scheduleProjection(let snapshot):
            if state.retiredScheduleEpochs?[snapshot.sessionId]?.contains(snapshot.epoch) == true { break }
            if let current = state.schedulesBySession?[snapshot.sessionId] {
                if current.epoch == snapshot.epoch, current.seq > snapshot.seq { break }
                if current.epoch != snapshot.epoch {
                    if state.retiredScheduleEpochs == nil { state.retiredScheduleEpochs = [:] }
                    let retired = Array(((state.retiredScheduleEpochs?[snapshot.sessionId] ?? []) + [current.epoch]).suffix(32))
                    state.retiredScheduleEpochs?[snapshot.sessionId] = retired
                }
            }
            if state.schedulesBySession == nil { state.schedulesBySession = [:] }
            state.schedulesBySession?[snapshot.sessionId] = snapshot
        case .todoChanged(let todo):
            if event.envelope.historyBatchId != nil {
                // Historical edits describe one final dock state, not a live
                // animation of every past task list. Late replay rows cannot
                // replace a newer live update or a completed batch.
                if var carry = state.historyCarryOverBySession[todo.sessionId] {
                    carry.replayedTodo = todo
                    state.historyCarryOverBySession[todo.sessionId] = carry
                }
                break
            }
            if state.historyCarryOverBySession[todo.sessionId] != nil {
                state.historyCarryOverBySession[todo.sessionId]?.receivedLiveTodo = true
            }
            if state.todoBySession == nil { state.todoBySession = [:] }
            state.todoBySession?[todo.sessionId] = todo
        case .executionRecorded(let update):
            mergeExecution([update.record], sessionID: update.sessionId,
                           sequence: update.inTranscript == false ? nil : event.sequence, into: &state)
        case .executionPage(let page):
            mergeExecution(page.records, sessionID: page.sessionId, sequence: nil, into: &state)
        case .workflowChanged(let update):
            var runs = state.workflowsBySession?[update.sessionId] ?? []
            let index = runs.firstIndex(where: { $0.id == update.run.id })
            var run = update.run
            run.sequence = index.flatMap { runs[$0].sequence }
            if update.inTranscript != false, run.sequence == nil { run.sequence = event.envelope.sequence }
            if let index, let currentSeq = runs[index].updatedNativeSequence,
               currentSeq > (update.run.updatedNativeSequence ?? -1) {
                if runs[index].sequence == nil, let sequence = run.sequence { runs[index].sequence = sequence }
            } else if let index { runs[index] = run }
            else { runs.append(run) }
            if state.workflowsBySession == nil { state.workflowsBySession = [:] }
            state.workflowsBySession?[update.sessionId] = runs
        case .jobsChanged(let jobs):
            if state.jobsBySession == nil { state.jobsBySession = [:] }
            state.jobsBySession?[jobs.sessionId] = jobs
        case .queueChanged(let queue):
            if state.serverQueues == nil { state.serverQueues = [:] }
            state.serverQueues?[queue.sessionId] = queue
        case .queueUpdated(let receipt):
            if state.queueReceipts == nil { state.queueReceipts = [:] }
            state.queueReceipts?[receipt.requestId] = receipt
        case .subagentCatalog(let catalog):
            if state.subagentCatalogs == nil { state.subagentCatalogs = [:] }
            state.subagentCatalogs?[catalog.parentSessionId] = catalog
        case .subagentCatalogInvalidated:
            break // Keep the list visible while the model refreshes its authoritative catalog.
        case .subagentReceipt(let receipt):
            if state.subagentReceipts == nil { state.subagentReceipts = [:] }
            state.subagentReceipts?[receipt.requestId] = receipt
        case .sessionForked(let fork):
            if state.forksByRequestID == nil { state.forksByRequestID = [:] }
            state.forksByRequestID?[fork.requestId] = fork
        case .commandCatalog(let catalog):
            if state.commandCatalogs == nil { state.commandCatalogs = [:] }
            state.commandCatalogs?[catalog.sessionId] = catalog
        case .commandCatalogInvalidated(let update):
            if let sessionID = update.sessionId { state.commandCatalogs?.removeValue(forKey: sessionID) }
            else { state.commandCatalogs = nil }
        case .goalChanged(let goal):
            if event.envelope.historyBatchId != nil, state.liveGoalSessions?.contains(goal.sessionId) == true { break }
            if event.envelope.historyBatchId == nil {
                if state.liveGoalSessions == nil { state.liveGoalSessions = [] }
                state.liveGoalSessions?.insert(goal.sessionId)
            }
            applyGoal(goal, into: &state)
        case .goalState(let goal):
            if state.liveGoalSessions == nil { state.liveGoalSessions = [] }
            state.liveGoalSessions?.insert(goal.sessionId)
            applyGoal(goal, into: &state)
        case .goalUpdated(let receipt):
            if state.goalReceipts == nil { state.goalReceipts = [:] }
            state.goalReceipts?[receipt.requestId] = receipt
        case .goalActivation(let update):
            if state.goalBySession?[update.sessionId]?.goal?.id == update.id,
               state.goalBySession?[update.sessionId]?.goal?.revision == update.revision {
                state.goalBySession?[update.sessionId]?.activation = update.activation
                if event.envelope.historyBatchId == nil {
                    if state.liveGoalSessions == nil { state.liveGoalSessions = [] }
                    state.liveGoalSessions?.insert(update.sessionId)
                }
            }
        case .goalRound(let update):
            if var current = state.goalBySession?[update.sessionId], current.goal?.id == update.id {
                current.roundsStarted = max(current.roundsStarted, update.round)
                state.goalBySession?[update.sessionId] = current
            }
        case .attachmentUploaded(let attachment):
            var values = state.attachmentsBySession[attachment.sessionId, default: []]
            if !values.contains(where: { $0.id == attachment.id }) { values.append(attachment) }
            state.attachmentsBySession[attachment.sessionId] = values
        case .promptAccepted:
            // Request receipts are consumed by DSHAppModel to settle the
            // composer; they are not transcript rows.
            break
        case .protocolError(let error):
            state.protocolErrorsByRequestID[event.envelope.messageId] = error.message
            if error.code == "bridge-request-failed", error.retryable { state.bridgeReachable = false }
        case .historyStarted(let batch):
            state.planBySession?.removeValue(forKey: batch.sessionId)
            if state.liveGoalSessions?.contains(batch.sessionId) != true { state.goalBySession?.removeValue(forKey: batch.sessionId) }
            // A replay rebuilds this session's transcript in stored order.
            // Set the rows seen so far aside (unpersisted live output) and
            // start from empty so replayed rows cannot renumber them.
            // Overlapping replays (a second open while the first still
            // streams) FOLD into the open carry instead of replacing it:
            // replacing discards rows the replay window does not cover, and
            // the first completion then drops them forever. The carry keeps
            // the first batch id, so the first completion merges and later
            // ones become harmless no-ops.
            // The arrays are deliberately NOT cleared: replayed rows merge by
            // id (dupes are no-ops), first-sighting keeps their order, and the
            // render sorts by sequence — so a replay paints over identical
            // rows instead of blanking the screen and popping rows in one by
            // one (the enter-page flicker). The carry remains purely a safety
            // net for rows outside the replay window.
            let sessionId = batch.sessionId
            if var carry = state.historyCarryOverBySession[sessionId] {
                appendMissing(state.messagesBySession[sessionId, default: []], to: &carry.messages)
                appendMissing(state.toolsBySession[sessionId, default: []], to: &carry.tools)
                appendMissing(state.commandResultsBySession[sessionId, default: []], to: &carry.commandResults)
                appendMissing(state.modelChangesBySession[sessionId, default: []], to: &carry.modelChanges)
                state.historyCarryOverBySession[sessionId] = carry
            } else {
                var carry = DSHHistoryCarryOver(batchId: batch.batchId)
                carry.messages = state.messagesBySession[sessionId, default: []]
                carry.tools = state.toolsBySession[sessionId, default: []]
                carry.commandResults = state.commandResultsBySession[sessionId, default: []]
                carry.modelChanges = state.modelChangesBySession[sessionId, default: []]
                state.historyCarryOverBySession[sessionId] = carry
            }
        case .historyCompleted(let batch):
            completeHistory(sessionId: batch.sessionId, batchId: batch.batchId, into: &state)
        case .transportState, .machinePresence, .workspaceFiles, .workspaceBytes:
            break
        case .unknown:
            state.unknownEvents.append(event.envelope)
        }
        return true
    }

    private func mergeExecution(_ records: [DSHExecutionRecord], sessionID: String, sequence: Int64?, into state: inout DSHStoreState) {
        var existing = state.executionBySession?[sessionID] ?? []
        var indexes = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
        for var record in records {
            if let index = indexes[record.id] {
                // Native durable records are immutable. A paged copy can add
                // missing history, but cannot rewrite a live record's content.
                if existing[index].sequence == nil { existing[index].sequence = sequence }
            } else {
                record.sequence = sequence
                indexes[record.id] = existing.count
                existing.append(record)
            }
        }
        existing.sort { $0.nativeSequence < $1.nativeSequence }
        if state.executionBySession == nil { state.executionBySession = [:] }
        state.executionBySession?[sessionID] = existing
    }

    private func acceptDecisionVersion(_ version: DSHDecisionVersion?, into state: inout DSHStoreState) -> Bool {
        guard let version else { return state.decisionVersion == nil }
        if state.retiredDecisionEpochs?.contains(version.epoch) == true { return false }
        if let current = state.decisionVersion {
            if current.epoch == version.epoch {
                guard version.revision >= current.revision else { return false }
            } else {
                state.retiredDecisionEpochs = Array(((state.retiredDecisionEpochs ?? []) + [current.epoch]).suffix(32))
                state.pendingApprovals.removeAll()
                state.pendingQuestions.removeAll()
            }
        }
        state.decisionVersion = version
        return true
    }

    private func applyGoal(_ goal: DSHGoalState, into state: inout DSHStoreState) {
        var next = goal
        if let current = state.goalBySession?[goal.sessionId], current.goal?.id == goal.goal?.id {
            if let currentRevision = current.goal?.revision, let nextRevision = goal.goal?.revision,
               currentRevision > nextRevision { return }
            next.roundsStarted = max(current.roundsStarted, next.roundsStarted)
            if current.goal?.revision == next.goal?.revision, next.activation == nil { next.activation = current.activation }
        }
        if state.goalBySession == nil { state.goalBySession = [:] }
        state.goalBySession?[goal.sessionId] = next
    }

    private func upsert(_ session: DSHSessionSummary, into sessions: inout [DSHSessionSummary]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.append(session) }
    }

    /// Atomically finishes one history replay batch: the live arrays now hold
    /// exactly the replayed rows in stream (stored) order.  Rows the replay
    /// did not contain are unpersisted live output seen before the batch and
    /// belong after it.  A completion for a batch that is no longer open
    /// (overlapping replays) is ignored; pass `batchId: nil` to force-merge
    /// whatever is open, which is what the app-level timeout does when the
    /// closing bracket never arrives.
    public func completeHistory(sessionId: String, batchId: String?, into state: inout DSHStoreState) {
        guard let carry = state.historyCarryOverBySession[sessionId] else { return }
        if let batchId, carry.batchId != batchId { return }
        state.historyCarryOverBySession.removeValue(forKey: sessionId)
        if batchId != nil, carry.receivedLiveTodo != true {
            if let todo = carry.replayedTodo {
                if state.todoBySession == nil { state.todoBySession = [:] }
                state.todoBySession?[sessionId] = todo
            } else {
                state.todoBySession?.removeValue(forKey: sessionId)
            }
        }
        appendMissing(carry.messages, to: &state.messagesBySession[sessionId, default: []])
        appendMissing(carry.tools, to: &state.toolsBySession[sessionId, default: []])
        appendMissing(carry.commandResults, to: &state.commandResultsBySession[sessionId, default: []])
        appendMissingModelChanges(carry.modelChanges, to: &state.modelChangesBySession[sessionId, default: []])
    }

    private func appendMissing<T: Identifiable>(_ values: [T], to store: inout [T]) where T.ID: Equatable {
        for value in values where !store.contains(where: { $0.id == value.id }) {
            store.append(value)
        }
    }

    private func appendMissingModelChanges(_ values: [DSHModelChangeNotice],
                                           to store: inout [DSHModelChangeNotice]) {
        for value in values where !store.contains(where: {
            $0.id == value.id || sameModelChange($0, value)
        }) {
            store.append(value)
        }
    }

    private func sameModelChange(_ left: DSHModelChangeNotice,
                                 _ right: DSHModelChangeNotice) -> Bool {
        left.previous == right.previous && left.current == right.current
    }

    private func isSilentPermissionSetupSuccess(_ result: DSHCommandResult) -> Bool {
        guard result.kind?.lowercased() != "error",
              let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else {
            return false
        }
        return [
            "preset read-only",
            "preset workspace-write",
            "preset danger-full-access",
        ].contains(text)
    }

    private func appendOrReplace<T: Identifiable & Equatable>(_ value: T,
                                                               in store: inout [String: [T]],
                                                               sessionId: String?) where T.ID: Equatable {
        let key = sessionId ?? ""
        var values = store[key, default: []]
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
        store[key] = values
    }
}

private extension DSHEvent {
    func startsNewSequenceEpoch(comparedTo lastSequence: Int64) -> Bool {
        guard sequence <= lastSequence else { return false }
        if establishesSequenceEpoch { return true }
        switch kind {
        // A replayed snapshot may arrive after a reconnect with an older
        // sequence. It is not proof the Connector restarted and resetting on
        // it lets stale rows replace a newer authoritative list. Only the
        // Connector's explicit epoch marker is allowed to roll the sequence.
        case .connectionReady:
            return true
        default:
            return false
        }
    }
}

/// How the sessions list arranges what it shows.
public enum DSHSessionGrouping: String, CaseIterable, Sendable {
    case byWorkspace
    case flat

    public var title: String {
        switch self {
        case .byWorkspace: return DSHLocalization.string("By workspace")
        case .flat: return DSHLocalization.string("Flat list")
        }
    }
}

/// One section of the sessions list.
public struct DSHSessionGroup: Identifiable, Sendable, Equatable {
    public static let flatGroupID = "__flat__"
    public let id: String
    public let title: String
    public var sessions: [DSHSessionSummary]
    /// True for the bucket holding sessions that belong to no workspace, which
    /// is sorted last and never merged with a real workspace of the same name.
    public let isUnfiled: Bool

    public init(id: String, title: String, sessions: [DSHSessionSummary], isUnfiled: Bool = false) {
        self.id = id; self.title = title; self.sessions = sessions; self.isUnfiled = isUnfiled
    }
}

/// A workspace the user can start a session in.
public struct DSHWorkspaceOption: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Absolute path from the paired Mac's workspace registry. Older
    /// Connectors omit it in session snapshots, hence optional.
    public let path: String?

    public init(id: String, name: String, path: String? = nil) {
        self.id = id; self.name = name; self.path = path
    }

    private enum CodingKeys: String, CodingKey { case id, name, title, path }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .title)
        try container.encodeIfPresent(path, forKey: .path)
    }
}

/// A directory returned by the paired Mac. iOS renders this catalog rather
/// than attempting to inspect the Mac filesystem itself.
public struct DSHDirectoryEntry: Codable, Identifiable, Sendable, Equatable {
    public let name: String
    public let path: String
    public var id: String { path }
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public struct DSHDirectoryListing: Codable, Sendable, Equatable {
    public let path: String
    public let parentPath: String?
    public let directories: [DSHDirectoryEntry]
    public init(path: String, parentPath: String? = nil, directories: [DSHDirectoryEntry]) {
        self.path = path; self.parentPath = parentPath; self.directories = directories
    }
}

/// Modes advertised by the paired Mac; their ids pass through to
/// `session.create` so mobile never hard-codes an out-of-date mode list.
public struct DSHModeOption: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public init(id: String, name: String, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }
}

public struct DSHModeCatalog: Codable, Sendable, Equatable {
    public let defaultMode: String?
    public let modes: [DSHModeOption]
    public init(defaultMode: String? = nil, modes: [DSHModeOption]) {
        self.defaultMode = defaultMode; self.modes = modes
    }
}

public extension Array where Element == DSHSessionSummary {
    /// Workspaces offered when starting a session, derived from the sessions on
    /// hand rather than a dedicated endpoint: the wire protocol has no
    /// workspace-list message, and adding one would change the routed command
    /// union — and so force another Relay redeploy — to produce a list that
    /// would almost always match this one.
    func workspaceOptions() -> [DSHWorkspaceOption] {
        var seen = Set<String>()
        return compactMap { session in
            guard let id = session.workspaceId, let name = session.workspaceName else { return nil }
            guard seen.insert(id).inserted else { return nil }
            return DSHWorkspaceOption(id: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension Array where Element == DSHSessionSummary {
    static let unfiledGroupTitle = "Other"
    static let flatGroupID = "__flat__"

    /// Sections the list should render, already filtered and sorted.
    ///
    /// Sessions outside every registered workspace are dropped rather than
    /// collected into an "Other" bucket. That bucket was mostly sessions the
    /// user never opened: delegated subagent runs have no workspace either, and
    /// mixing them with real work made the bottom of the list look like junk.
    /// The Harness sidebar only lists registered workspaces, so this also keeps
    /// the two views agreeing.
    func groupedForList(_ grouping: DSHSessionGrouping, showArchived: Bool) -> [DSHSessionGroup] {
        let visible = filter { showArchived || $0.archived != true }
            .filter { $0.workspaceName != nil }
        let recentFirst = visible.sorted { $0.updatedAt > $1.updatedAt }

        switch grouping {
        case .flat:
            guard !recentFirst.isEmpty else { return [] }
            return [DSHSessionGroup(id: Self.flatGroupID, title: "", sessions: recentFirst)]
        case .byWorkspace:
            // Group by the stable registry id when one is available. The
            // display title is mutable, so using it as an id made a project
            // rename look like a delete plus a new project and broke the menu
            // action that targets the remote WorkspaceRegistry.
            let buckets = Dictionary(grouping: visible) { $0.workspaceId ?? $0.workspaceName ?? Self.unfiledGroupID }
            return buckets.keys.sorted { left, right in
                let leftTitle = buckets[left]?.first?.workspaceName ?? Self.unfiledGroupTitle
                let rightTitle = buckets[right]?.first?.workspaceName ?? Self.unfiledGroupTitle
                if left == Self.unfiledGroupID { return false }
                if right == Self.unfiledGroupID { return true }
                return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
            }
            .compactMap { key in
                let sessions = (buckets[key] ?? []).sorted { $0.updatedAt > $1.updatedAt }
                guard !sessions.isEmpty else { return nil }
                let title = sessions.first?.workspaceName ?? Self.unfiledGroupTitle
                let unfiled = key == Self.unfiledGroupID
                return DSHSessionGroup(id: unfiled ? Self.unfiledGroupID : key,
                                       title: title, sessions: sessions, isUnfiled: unfiled)
            }
        }
    }

    static let unfiledGroupID = "__unfiled__"
}

@MainActor
public final class DSHEventStore {
    public private(set) var state: DSHStoreState
    private let reducer: DSHEventReducer

    public init(initialState: DSHStoreState = .init(), reducer: DSHEventReducer = .init()) {
        self.state = initialState
        self.reducer = reducer
    }

    public func reduce(_ event: DSHEvent) { reducer.reduce(event, into: &state) }
    public func reduce<S: Sequence>(_ events: S) where S.Element == DSHEvent {
        for event in events { reduce(event) }
    }
    public func setConnectionState(_ value: DSHConnectionState) { state.connectionState = value }
}
