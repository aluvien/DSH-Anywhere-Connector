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
    /// `nil` means the Connector is present but the local Harness bridge has
    /// not answered yet. Existing protocol events prove whether it is usable.
    public var bridgeReachable: Bool?
    public var connectionState: DSHConnectionState = .disconnected

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
                state.machineOnline = false
                state.bridgeReachable = nil
                state.connectionState = value
            }
            return true
        case .machinePresence(let online):
            if !online || !state.machineOnline { state.bridgeReachable = nil }
            state.machineOnline = online
            state.connectionState = online ? .connected : .disconnected
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

        switch event.kind {
        case .connectionReady:
            state.transportState = .connected
            state.machineOnline = true
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
            state.hasLoadedSessions = true
        case .sessionCreated(let session):
            upsert(session, into: &state.sessions)
        case .userMessageAccepted(let message):
            var stamped = message
            // First sighting wins: replays (re-open, refresh, reconnect
            // backfill) update content in place but must not renumber the
            // row ahead of live output that followed it.
            if let sessionId = event.envelope.sessionId,
               let existing = state.messagesBySession[sessionId]?.first(where: { $0.id == message.id }),
               let existingSequence = existing.sequence {
                stamped.sequence = existingSequence
            } else if stamped.sequence == nil {
                stamped.sequence = event.envelope.sequence
            }
            if let sessionId = event.envelope.sessionId,
               let existing = state.messagesBySession[sessionId]?.first(where: { $0.id == message.id }),
               let existingTimestamp = existing.timestamp {
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
        case .toolStarted(let tool):
            var stamped = tool
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
                // The completion replaces detail with the result text; carry
                // the call arguments forward for the row title.
                if stamped.arguments == nil { stamped.arguments = existing.arguments }
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
            if error.code == "bridge-request-failed" { state.bridgeReachable = false }
        case .historyStarted(let batch):
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
        case .transportState, .machinePresence:
            break
        case .unknown:
            state.unknownEvents.append(event.envelope)
        }
        return true
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
