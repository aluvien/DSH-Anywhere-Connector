import Foundation

public struct DSHStoreState: Codable, Sendable, Equatable {
    public var sessions: [DSHSessionSummary] = []
    public var messagesBySession: [String: [DSHChatMessage]] = [:]
    public var toolsBySession: [String: [DSHToolActivity]] = [:]
    public var pendingApprovals: [DSHApprovalRequest] = []
    public var pendingQuestions: [DSHQuestionRequest] = []
    public var turnStateBySession: [String: String] = [:]
    public var modelCatalog: DSHModelCatalog?
    public var usageBySession: [String: DSHSessionUsage] = [:]
    public var permissionBySession: [String: DSHPermissionUpdate] = [:]
    public var metadataBySession: [String: DSHSessionMetadataUpdate] = [:]
    public var commandResultsBySession: [String: [DSHCommandResult]] = [:]
    public var attachmentsBySession: [String: [DSHUploadedAttachment]] = [:]
    public var unknownEvents: [DSHEnvelope] = []
    public var lastSequence: Int64 = 0
    public var connectionState: DSHConnectionState = .disconnected

    public init() {}
}

/// Pure, deterministic event reducer.  Keeping this separate from the
/// observable store makes all event ordering and duplicate handling testable.
public struct DSHEventReducer: Sendable {
    public init() {}

    public func reduce(_ event: DSHEvent, into state: inout DSHStoreState) {
        if event.startsNewSequenceEpoch(comparedTo: state.lastSequence) {
            // A bridge/Connector restart resets its in-memory replay buffer to
            // sequence 1.  `session.snapshot` is a complete, authoritative
            // response to a refresh, so it can establish the new epoch even
            // if the preceding connection.ready was not replayed.
            state.lastSequence = 0
        }
        // Sequence numbers are monotonic at the transport boundary. Replaying
        // an old event must not duplicate a message or roll state backwards.
        guard event.sequence > state.lastSequence else { return }
        state.lastSequence = event.sequence

        switch event.kind {
        case .connectionReady:
            state.connectionState = .connected
        case .sessionSnapshot(let sessions):
            state.sessions = sessions
        case .sessionCreated(let session):
            upsert(session, into: &state.sessions)
        case .userMessageAccepted(let message):
            var stamped = message
            stamped.sequence = event.envelope.sequence
            appendOrReplace(stamped, in: &state.messagesBySession, sessionId: event.envelope.sessionId)
        case .assistantMessageCompleted(let message):
            // A completion replaces the streaming partial, so carry the
            // reasoning that arrived as its own event back onto the message.
            var completed = message
            if let sessionId = event.envelope.sessionId,
               let existing = state.messagesBySession[sessionId]?.first(where: { $0.id == message.id }) {
                completed.reasoning = existing.reasoning
                // Keep where the message started rather than where it finished,
                // so interleaving with tool calls stays chronological.
                completed.sequence = existing.sequence
            } else {
                completed.sequence = event.envelope.sequence
            }
            appendOrReplace(completed, in: &state.messagesBySession, sessionId: event.envelope.sessionId)
        case .assistantReasoning(let reasoning):
            let sessionId = event.envelope.sessionId ?? ""
            var messages = state.messagesBySession[sessionId, default: []]
            if let index = messages.firstIndex(where: { $0.id == reasoning.messageId }) {
                messages[index].reasoning = reasoning.text
            } else {
                messages.append(DSHChatMessage(id: reasoning.messageId, role: .assistant,
                                               markdown: "", reasoning: reasoning.text,
                                               sequence: event.envelope.sequence))
            }
            state.messagesBySession[sessionId] = messages
        case .assistantMessageDelta(let delta):
            let sessionId = event.envelope.sessionId ?? ""
            var messages = state.messagesBySession[sessionId, default: []]
            if let index = messages.firstIndex(where: { $0.id == delta.messageId }) {
                messages[index].markdown += delta.text
            } else {
                messages.append(DSHChatMessage(id: delta.messageId, role: .assistant, markdown: delta.text,
                                               sequence: event.envelope.sequence))
            }
            state.messagesBySession[sessionId] = messages
        case .toolStarted(let tool):
            var stamped = tool
            stamped.sequence = event.envelope.sequence
            appendOrReplace(stamped, in: &state.toolsBySession, sessionId: event.envelope.sessionId)
        case .toolCompleted(let tool):
            var stamped = tool
            // Keep the arrival order of the call itself: a completion carries a
            // later sequence but must not jump ahead of calls made after it.
            let existing = event.envelope.sessionId.flatMap { state.toolsBySession[$0] }?
                .first { $0.id == tool.id }
            if let existing {
                stamped.sequence = existing.sequence
            } else {
                stamped.sequence = event.envelope.sequence
            }
            appendOrReplace(stamped, in: &state.toolsBySession, sessionId: event.envelope.sessionId)
        case .approvalRequested(let approval):
            if !state.pendingApprovals.contains(where: { $0.id == approval.id }) {
                state.pendingApprovals.append(approval)
            }
        case .approvalResolved(let resolution):
            state.pendingApprovals.removeAll { $0.id == resolution.id }
        case .questionAsked(let request):
            if !state.pendingQuestions.contains(where: { $0.id == request.id }) {
                state.pendingQuestions.append(request)
            }
        case .questionResolved(let resolution):
            state.pendingQuestions.removeAll { $0.id == resolution.id }
        case .turnStateChanged(let turn):
            state.turnStateBySession[turn.sessionId] = turn.state
        case .modelCatalog(let catalog):
            state.modelCatalog = catalog
        case .usageUpdated(let update):
            state.usageBySession[update.sessionId] = update.usage
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                state.sessions[index].usage = update.usage
            }
        case .permissionUpdated(let update):
            state.permissionBySession[update.sessionId] = update
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                state.sessions[index].permissionMode = update.mode
            }
        case .sessionMetadataUpdated(let update):
            state.metadataBySession[update.sessionId] = update
            if let index = state.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                if let provider = update.provider { state.sessions[index].provider = provider }
                if let model = update.model { state.sessions[index].model = model }
                if let effort = update.reasoningEffort { state.sessions[index].reasoningEffort = effort }
            }
        case .commandResult(let result):
            var values = state.commandResultsBySession[result.sessionId, default: []]
            if let index = values.firstIndex(where: { $0.id == result.id }) { values[index] = result }
            else { values.append(result) }
            state.commandResultsBySession[result.sessionId] = values
        case .attachmentUploaded(let attachment):
            var values = state.attachmentsBySession[attachment.sessionId, default: []]
            if !values.contains(where: { $0.id == attachment.id }) { values.append(attachment) }
            state.attachmentsBySession[attachment.sessionId] = values
        case .unknown:
            state.unknownEvents.append(event.envelope)
        }
    }

    private func upsert(_ session: DSHSessionSummary, into sessions: inout [DSHSessionSummary]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.append(session) }
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
        switch kind {
        case .connectionReady, .sessionSnapshot:
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
        case .byWorkspace: return "By workspace"
        case .flat: return "Flat list"
        }
    }
}

/// One section of the sessions list.
public struct DSHSessionGroup: Identifiable, Sendable, Equatable {
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
public struct DSHWorkspaceOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
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
            let buckets = Dictionary(grouping: visible) { $0.workspaceName ?? Self.unfiledGroupTitle }
            return buckets.keys.sorted { left, right in
                if left == Self.unfiledGroupTitle { return false }
                if right == Self.unfiledGroupTitle { return true }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            .compactMap { key in
                let sessions = (buckets[key] ?? []).sorted { $0.updatedAt > $1.updatedAt }
                guard !sessions.isEmpty else { return nil }
                // A workspace genuinely named "Other" must not absorb the bucket.
                let unfiled = key == Self.unfiledGroupTitle
                    && sessions.allSatisfy { $0.workspaceName == nil }
                return DSHSessionGroup(
                    id: unfiled ? Self.unfiledGroupID : key,
                    title: key,
                    sessions: sessions,
                    isUnfiled: unfiled
                )
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
