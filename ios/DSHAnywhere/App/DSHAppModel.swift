import Foundation
import Combine
import UserNotifications

private let dshAttachmentRecoveryWindow: TimeInterval = 30 * 24 * 60 * 60

private enum DSHAttachmentUploadError: LocalizedError {
    case timedOut
    case tooLarge
    case quotaExceeded
    case persistenceUnavailable
    case recoveryExpired

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The attachment upload timed out. Please try again."
        case .tooLarge: return "Attachments must be 10 MiB or smaller."
        case .quotaExceeded: return "待处理附件总量已达到上限，请先取消旧请求后重试。"
        case .persistenceUnavailable: return "待处理请求存储不可用，已停止自动重试。"
        case .recoveryExpired: return "附件恢复期限已过，请重新选择附件后发送。"
        }
    }
}

private struct DSHRemoteCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct DSHPendingInitialMessage: Codable, Sendable {
    let promptRequestID: String
    let text: String
    let attachments: [DSHStagedAttachment]
    var sessionID: String?
    /// Fixed when the independent prompt.send first enters the wire-facing
    /// phase. Recovery must not extend the server dedupe window.
    var dedupeExpiresAt: Date?
    /// Receipt metadata survives a partial upload failure. Retrying the
    /// second file must not upload the first file again.
    var uploadedAttachments: [String: DSHMessageAttachment] = [:]
    /// The Bridge retains attachment identities for this same period. Once it
    /// expires, automatic recovery is stopped rather than reusing an id that
    /// may have been garbage-collected remotely.
    var attachmentRecoveryDeadline: Date?
}

struct DSHInitialMessageFailure: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let sessionID: String
    let text: String
    let detail: String
}

/// A session-create request that was rejected before the Mac emitted its
/// correlated `session.created` acknowledgement. The original command and
/// staged first message remain in the pending maps so a retry can reuse the
/// same request identity instead of silently creating a second session.
struct DSHSessionCreationFailure: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let detail: String
    /// `true` means the request may have reached the Mac but did not produce
    /// an authoritative result.  Such a request must keep its idempotency key
    /// until a correlated `session.created` (or an explicit user decision)
    /// settles it.
    let resultUnknown: Bool
    /// The server-side idempotency records are guaranteed through this point.
    /// Unknown results must not be re-executed after the deadline.
    let retryUntil: Date

    init(id: String, detail: String, resultUnknown: Bool = false,
         retryUntil: Date = .distantFuture) {
        self.id = id
        self.detail = detail
        self.resultUnknown = resultUnknown
        self.retryUntil = retryUntil
    }
}

private struct DSHSessionCreationTransaction: Codable, Sendable {
    let command: DSHCommand
    let initialMessage: DSHPendingInitialMessage?
    let failure: DSHSessionCreationFailure?
    let detached: Bool
    let retryDeadline: Date
}

private enum DSHRemoteMutationDeliveryState: String, Codable, Sendable {
    /// The current durable request has never entered a send attempt that may
    /// have crossed the socket. A local pre-send rejection can safely release
    /// this transaction.
    case neverSent
    /// At least one attempt may have reached Relay. Later errors from a retry
    /// describe only that retry and must not erase the historical tombstone.
    case mayHaveBeenSent
}

/// A non-prompt native mutation whose transport acknowledgement was lost.
/// Keep the complete command (including its request id) so a user retry can
/// safely re-enter Connector/Bridge idempotency instead of minting a second
/// request after the first may already have crossed the socket.
private struct DSHRemoteMutationTransaction: Codable, Sendable {
    let command: DSHCommand
    var failure: String?
    let retryDeadline: Date
    var deliveryState: DSHRemoteMutationDeliveryState

    init(command: DSHCommand, failure: String?, retryDeadline: Date,
         deliveryState: DSHRemoteMutationDeliveryState = .neverSent) {
        self.command = command
        self.failure = failure
        self.retryDeadline = retryDeadline
        self.deliveryState = deliveryState
    }

    private enum CodingKeys: String, CodingKey {
        case command, failure, retryDeadline, deliveryState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(DSHCommand.self, forKey: .command)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        retryDeadline = try container.decode(Date.self, forKey: .retryDeadline)
        // Older journals do not record whether the request ever reached the
        // transport. Preserve the safer ambiguous interpretation rather than
        // allowing a later local error to erase an unknown native mutation.
        deliveryState = try container.decodeIfPresent(
            DSHRemoteMutationDeliveryState.self, forKey: .deliveryState)
            ?? .mayHaveBeenSent
    }
}

private struct DSHInitialMessageTransaction: Codable, Sendable {
    let pending: DSHPendingInitialMessage
    let failure: DSHInitialMessageFailure?
}

private struct DSHStoredAttachment: Codable, Sendable {
    let id: UUID
    let name: String
    let isImage: Bool
    let fileName: String?
    /// Read only for migration from d575855, which embedded Data in JSON.
    let legacyData: Data?

    private enum CodingKeys: String, CodingKey { case id, name, isImage, fileName, data }

    init(id: UUID, name: String, isImage: Bool, fileName: String) {
        self.id = id; self.name = name; self.isImage = isImage
        self.fileName = fileName; self.legacyData = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isImage = try container.decode(Bool.self, forKey: .isImage)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        legacyData = try container.decodeIfPresent(Data.self, forKey: .data)
        if fileName == nil && legacyData == nil { throw DecodingError.dataCorruptedError(
            forKey: .fileName, in: container, debugDescription: "pending attachment has no blob") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isImage, forKey: .isImage)
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
}

private struct DSHStoredInitialMessage: Codable, Sendable {
    let promptRequestID: String
    let text: String
    let attachments: [DSHStoredAttachment]
    let sessionID: String?
    let uploadedAttachments: [String: DSHMessageAttachment]
    let dedupeExpiresAt: Date?
    let attachmentRecoveryDeadline: Date?

    private enum CodingKeys: String, CodingKey {
        case promptRequestID, text, attachments, sessionID, uploadedAttachments, dedupeExpiresAt,
             attachmentRecoveryDeadline
    }

    init(promptRequestID: String, text: String, attachments: [DSHStoredAttachment],
         sessionID: String?, uploadedAttachments: [String: DSHMessageAttachment],
         dedupeExpiresAt: Date?, attachmentRecoveryDeadline: Date?) {
        self.promptRequestID = promptRequestID
        self.text = text
        self.attachments = attachments
        self.sessionID = sessionID
        self.uploadedAttachments = uploadedAttachments
        self.dedupeExpiresAt = dedupeExpiresAt
        self.attachmentRecoveryDeadline = attachmentRecoveryDeadline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptRequestID = try container.decode(String.self, forKey: .promptRequestID)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([DSHStoredAttachment].self, forKey: .attachments)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        uploadedAttachments = try container.decodeIfPresent(
            [String: DSHMessageAttachment].self, forKey: .uploadedAttachments) ?? [:]
        // A legacy initial-message record can represent a prompt that already
        // crossed the socket.  Missing deadline metadata therefore migrates to
        // an expired window; an explicit null remains the safe, not-yet-sent
        // representation used by current session-create records.
        dedupeExpiresAt = container.contains(.dedupeExpiresAt)
            ? try container.decodeIfPresent(Date.self, forKey: .dedupeExpiresAt)
            : .now
        attachmentRecoveryDeadline = container.contains(.attachmentRecoveryDeadline)
            ? try container.decodeIfPresent(Date.self, forKey: .attachmentRecoveryDeadline)
            : (attachments.isEmpty ? nil : .now)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptRequestID, forKey: .promptRequestID)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encode(uploadedAttachments, forKey: .uploadedAttachments)
        try container.encode(dedupeExpiresAt, forKey: .dedupeExpiresAt)
        try container.encode(attachmentRecoveryDeadline, forKey: .attachmentRecoveryDeadline)
    }
}

private struct DSHStoredSessionCreationTransaction: Codable, Sendable {
    let command: DSHCommand
    let initialMessage: DSHStoredInitialMessage?
    let failure: DSHSessionCreationFailure?
    let detached: Bool
    let retryDeadline: Date
}

private struct DSHStoredInitialMessageTransaction: Codable, Sendable {
    let pending: DSHStoredInitialMessage
    let failure: DSHInitialMessageFailure?
}

private enum DSHStoredSendFailure: Codable, Equatable, Sendable {
    case local(String)
    case server(String)
}

/// Durable prompt sends have an explicit phase so a restart can distinguish
/// an upload that has not produced a prompt yet from a prompt that was
/// actually sent and is waiting for its targeted acknowledgement.
enum DSHPromptTransactionPhase: String, Codable, Equatable, Sendable {
    case preparing
    case readyToSend
    case awaitingAck
}

private struct DSHStoredPendingSend: Codable, Sendable {
    let id: String
    let text: String
    let receipts: [String]
    let sessionID: String
    let mode: String
    let sentAt: Date
    /// The fixed server-side request-id retention deadline. This is separate
    /// from sentAt because a queued draft may wait locally before dispatch.
    let dedupeExpiresAt: Date?
    let attempt: Int
    let messageAttachments: [DSHMessageAttachment]
    let phase: DSHPromptTransactionPhase?
    /// Present only while a normal prompt is uploading its staged files.
    /// The bytes live in the same immutable blob store as initial messages;
    /// old journals omit these optional fields.
    let stagedAttachments: [DSHStoredAttachment]?
    let uploadedAttachments: [String: DSHMessageAttachment]?
    let attachmentRecoveryDeadline: Date?

    init(id: String, text: String, receipts: [String], sessionID: String,
         mode: String, sentAt: Date, dedupeExpiresAt: Date? = nil, attempt: Int,
         messageAttachments: [DSHMessageAttachment],
         stagedAttachments: [DSHStoredAttachment]? = nil,
         uploadedAttachments: [String: DSHMessageAttachment]? = nil,
         phase: DSHPromptTransactionPhase? = nil,
         attachmentRecoveryDeadline: Date? = nil) {
        self.id = id
        self.text = text
        self.receipts = receipts
        self.sessionID = sessionID
        self.mode = mode
        self.sentAt = sentAt
        self.dedupeExpiresAt = dedupeExpiresAt
        self.attempt = attempt
        self.messageAttachments = messageAttachments
        self.stagedAttachments = stagedAttachments
        self.uploadedAttachments = uploadedAttachments
        self.phase = phase
        self.attachmentRecoveryDeadline = attachmentRecoveryDeadline
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, receipts, sessionID, mode, sentAt, attempt,
             messageAttachments, stagedAttachments, uploadedAttachments, phase,
             dedupeExpiresAt, attachmentRecoveryDeadline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        receipts = try container.decode([String].self, forKey: .receipts)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        mode = try container.decode(String.self, forKey: .mode)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        dedupeExpiresAt = try container.decodeIfPresent(Date.self, forKey: .dedupeExpiresAt)
        attempt = try container.decode(Int.self, forKey: .attempt)
        messageAttachments = try container.decode([DSHMessageAttachment].self, forKey: .messageAttachments)
        stagedAttachments = try container.decodeIfPresent([DSHStoredAttachment].self, forKey: .stagedAttachments)
        uploadedAttachments = try container.decodeIfPresent([String: DSHMessageAttachment].self, forKey: .uploadedAttachments)
        attachmentRecoveryDeadline = container.contains(.attachmentRecoveryDeadline)
            ? try container.decodeIfPresent(Date.self, forKey: .attachmentRecoveryDeadline)
            : (stagedAttachments?.isEmpty == false
                ? sentAt.addingTimeInterval(dshAttachmentRecoveryWindow) : nil)
        phase = try container.decodeIfPresent(DSHPromptTransactionPhase.self, forKey: .phase)
    }
}

private struct DSHStoredFailedSend: Codable, Sendable {
    let id: String
    let text: String
    let receipts: [String]
    let sessionID: String
    let mode: String
    let messageAttachments: [DSHMessageAttachment]
    let failure: DSHStoredSendFailure
    /// A timeout means the prompt may already have reached the Mac.  Keep the
    /// retry window in the journal so a later launch cannot outlive the
    /// Connector/Bridge request-id tombstone and execute it again.
    let retryUntil: Date?

    private enum CodingKeys: String, CodingKey {
        case id, text, receipts, sessionID, mode, messageAttachments, failure, retryUntil
    }

    init(id: String, text: String, receipts: [String], sessionID: String,
         mode: String, messageAttachments: [DSHMessageAttachment],
         failure: DSHStoredSendFailure, retryUntil: Date?) {
        self.id = id
        self.text = text
        self.receipts = receipts
        self.sessionID = sessionID
        self.mode = mode
        self.messageAttachments = messageAttachments
        self.failure = failure
        self.retryUntil = retryUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        receipts = try container.decode([String].self, forKey: .receipts)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        mode = try container.decode(String.self, forKey: .mode)
        messageAttachments = try container.decode([DSHMessageAttachment].self, forKey: .messageAttachments)
        failure = try container.decode(DSHStoredSendFailure.self, forKey: .failure)
        // Builds before the finite prompt-idempotency window was introduced
        // omitted this key.  Such a request may already have reached Relay,
        // so migration must fail closed instead of interpreting the missing
        // value as an indefinitely safe local retry.  An explicit JSON null
        // remains the intentional "proven local failure" representation.
        retryUntil = container.contains(.retryUntil)
            ? try container.decodeIfPresent(Date.self, forKey: .retryUntil)
            : .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(receipts, forKey: .receipts)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(mode, forKey: .mode)
        try container.encode(messageAttachments, forKey: .messageAttachments)
        try container.encode(failure, forKey: .failure)
        // Encode nil explicitly.  Omitting it would make a future launch
        // mistake a deliberately local failure for an unsafe legacy record.
        try container.encode(retryUntil, forKey: .retryUntil)
    }
}

private struct DSHPendingTransactionSnapshot: Sendable {
    let metadata: Data
    let blobs: [String: Data]
    let referencedBlobNames: Set<String>
    let generation: Int
}

private struct DSHLoadedPendingTransactionStore: Sendable {
    let store: DSHPendingTransactionStore
    let blobs: [String: Data]
}

/// Loading the large transaction journal can fail independently of the small
/// removed-machine sidecar. Keep the sidecar fence attached to the failure so
/// startup can still fail closed and reconcile a removed profile instead of
/// silently reconnecting it.
private struct DSHPendingTransactionStoreLoadError: Error, Sendable {
    let fencedMachineIDs: Set<String>
    /// A sidecar that exists but cannot be read is not equivalent to an empty
    /// fence.  Keep this bit separate so startup can fail closed instead of
    /// reconnecting an old profile with unknown removal state.
    let fenceUnavailable: Bool
}

/// Serializes transaction files away from the `@MainActor`.  The model still
/// builds a small metadata snapshot on the main actor, but blob writes,
/// directory scans, and atomic replacement all run on this independent
/// executor.  Generations prevent an older fire-and-forget save from
/// overwriting a newer snapshot when machine switching and event handling race.
private actor DSHPendingTransactionFileStore {
    private let metadataURL: URL
    private let attachmentDirectoryURL: URL
    private let removedMachineIDsURL: URL
    private var latestGeneration = 0

    init(metadataURL: URL, attachmentDirectoryURL: URL, removedMachineIDsURL: URL) {
        self.metadataURL = metadataURL
        self.attachmentDirectoryURL = attachmentDirectoryURL
        self.removedMachineIDsURL = removedMachineIDsURL
    }

    func writeRemovedMachineIDs(_ machineIDs: Set<String>) throws {
        let directory = removedMachineIDsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent("removed-machines-\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(machineIDs)
        try data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
        if FileManager.default.fileExists(atPath: removedMachineIDsURL.path) {
            _ = try FileManager.default.replaceItemAt(removedMachineIDsURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: removedMachineIDsURL)
        }
    }

    func write(_ snapshot: DSHPendingTransactionSnapshot) throws {
        guard snapshot.generation >= latestGeneration else { return }
        latestGeneration = snapshot.generation
        try FileManager.default.createDirectory(at: attachmentDirectoryURL,
                                                 withIntermediateDirectories: true)
        for (fileName, data) in snapshot.blobs {
            let blobURL = attachmentDirectoryURL.appendingPathComponent(fileName)
            // Attachment ids are UUID-backed immutable object names.  Once a
            // blob has been atomically installed, receipt progress only
            // changes the small manifest; rewriting the same 10 MiB object on
            // every upload acknowledgement causes multi-GB write
            // amplification for a legal 16-attachment request.
            if !FileManager.default.fileExists(atPath: blobURL.path) {
                try data.write(to: blobURL, options: [.atomic, .completeFileProtection])
            }
        }
        let directory = metadataURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent("pending-transactions-\(UUID().uuidString).tmp")
        try snapshot.metadata.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            _ = try FileManager.default.replaceItemAt(metadataURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: metadataURL)
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: attachmentDirectoryURL,
                                                                       includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "blob" &&
                !snapshot.referencedBlobNames.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func load() throws -> DSHLoadedPendingTransactionStore {
        // Read the fence first and keep it independent from the large journal.
        // An existing (even empty) sidecar is authoritative: an empty sidecar
        // is the durable completion marker for a re-pair and must not be merged
        // with a stale removedMachineIDs value left in the old journal.
        let sidecarMachineIDs: Set<String>?
        do {
            if FileManager.default.fileExists(atPath: removedMachineIDsURL.path) {
                let data = try Data(contentsOf: removedMachineIDsURL)
                sidecarMachineIDs = try JSONDecoder().decode(Set<String>.self, from: data)
            } else {
                sidecarMachineIDs = nil
            }
        } catch {
            throw DSHPendingTransactionStoreLoadError(fencedMachineIDs: [], fenceUnavailable: true)
        }
        // A first launch has no journal yet.  Treat that absence as an empty
        // store instead of converting the normal ENOENT variant returned by
        // a simulator/device into a fail-closed persistence error.
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return DSHLoadedPendingTransactionStore(
                store: DSHPendingTransactionStore(
                    sessionCreationTransactionsByMachine: [:],
                    lastSessionCreationRequestIDsByMachine: [:],
                    initialMessageTransactionsByMachine: [:],
                    removedMachineIDs: sidecarMachineIDs ?? []),
                blobs: [:])
        }
        var fallbackFence = sidecarMachineIDs ?? []
        do {
            let metadata = try Data(contentsOf: metadataURL)
            var store = try JSONDecoder().decode(DSHPendingTransactionStore.self, from: metadata)
            let fencedMachineIDs = sidecarMachineIDs ?? store.removedMachineIDs
            fallbackFence = fencedMachineIDs
            // The sidecar is authoritative when present; the journal field is
            // retained only as a legacy migration path for installations that
            // predate the sidecar. Drop fenced machine maps before collecting
            // blob names so a corrupt attachment on a removed machine cannot
            // block recovery of every healthy machine.
            store.removedMachineIDs = fencedMachineIDs
            for machineID in fencedMachineIDs {
                store.sessionCreationTransactionsByMachine.removeValue(forKey: machineID)
                store.remoteMutationTransactionsByMachine.removeValue(forKey: machineID)
                store.lastSessionCreationRequestIDsByMachine.removeValue(forKey: machineID)
                store.initialMessageTransactionsByMachine.removeValue(forKey: machineID)
                store.pendingPromptTransactionsByMachine.removeValue(forKey: machineID)
                store.failedPromptTransactionsByMachine.removeValue(forKey: machineID)
            }
            var names = Set<String>()
            func collect(_ attachments: [DSHStoredAttachment]) throws {
                for attachment in attachments {
                    if let fileName = attachment.fileName,
                       fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                       fileName.hasSuffix(".blob") {
                        names.insert(fileName)
                    } else if attachment.legacyData == nil {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            }
            func collect(_ value: DSHStoredInitialMessage) throws {
                try collect(value.attachments)
            }
            for transactions in store.sessionCreationTransactionsByMachine.values {
                for transaction in transactions.values {
                    if let initialMessage = transaction.initialMessage { try collect(initialMessage) }
                }
            }
            for transactions in store.initialMessageTransactionsByMachine.values {
                for transaction in transactions.values { try collect(transaction.pending) }
            }
            // A normal composer prompt can be killed while its attachments are
            // still uploading.  Its staged blobs live under the pending-prompt
            // records too, so include those references in the load set or the
            // recovery pass would report a corrupt journal and lose the draft.
            for transactions in store.pendingPromptTransactionsByMachine.values {
                for transaction in transactions.values {
                    try collect(transaction.stagedAttachments ?? [])
                }
            }
            var blobs: [String: Data] = [:]
            blobs.reserveCapacity(names.count)
            for fileName in names {
                blobs[fileName] = try Data(contentsOf: attachmentDirectoryURL.appendingPathComponent(fileName))
            }
            return DSHLoadedPendingTransactionStore(store: store, blobs: blobs)
        } catch {
            // Preserve a valid sidecar fence even when the journal or one of
            // its blobs is corrupt. The caller marks persistence unavailable,
            // but still deletes/reconciles fenced profiles on this launch.
            throw DSHPendingTransactionStoreLoadError(fencedMachineIDs: fallbackFence,
                                                       fenceUnavailable: false)
        }
    }
}

private struct DSHPendingTransactionStore: Codable, Sendable {
    var sessionCreationTransactionsByMachine: [String: [String: DSHStoredSessionCreationTransaction]]
    var remoteMutationTransactionsByMachine: [String: [String: DSHRemoteMutationTransaction]]
    var lastSessionCreationRequestIDsByMachine: [String: String]
    var initialMessageTransactionsByMachine: [String: [String: DSHStoredInitialMessageTransaction]]
    var pendingPromptTransactionsByMachine: [String: [String: DSHStoredPendingSend]]
    var failedPromptTransactionsByMachine: [String: [String: DSHStoredFailedSend]]
    /// A durable fence for an explicitly removed/forgotten Mac. If cleanup
    /// cannot replace the old journal immediately, a later relaunch or
    /// re-pair must not resurrect that machine's queued side effects.
    var removedMachineIDs: Set<String>

    private enum CodingKeys: String, CodingKey {
        case sessionCreationTransactionsByMachine, remoteMutationTransactionsByMachine,
             lastSessionCreationRequestIDsByMachine,
             initialMessageTransactionsByMachine, pendingPromptTransactionsByMachine,
             failedPromptTransactionsByMachine, removedMachineIDs
    }

    init(sessionCreationTransactionsByMachine: [String: [String: DSHStoredSessionCreationTransaction]],
         remoteMutationTransactionsByMachine: [String: [String: DSHRemoteMutationTransaction]] = [:],
         lastSessionCreationRequestIDsByMachine: [String: String],
         initialMessageTransactionsByMachine: [String: [String: DSHStoredInitialMessageTransaction]],
         pendingPromptTransactionsByMachine: [String: [String: DSHStoredPendingSend]] = [:],
         failedPromptTransactionsByMachine: [String: [String: DSHStoredFailedSend]] = [:],
         removedMachineIDs: Set<String> = []) {
        self.sessionCreationTransactionsByMachine = sessionCreationTransactionsByMachine
        self.remoteMutationTransactionsByMachine = remoteMutationTransactionsByMachine
        self.lastSessionCreationRequestIDsByMachine = lastSessionCreationRequestIDsByMachine
        self.initialMessageTransactionsByMachine = initialMessageTransactionsByMachine
        self.pendingPromptTransactionsByMachine = pendingPromptTransactionsByMachine
        self.failedPromptTransactionsByMachine = failedPromptTransactionsByMachine
        self.removedMachineIDs = removedMachineIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionCreationTransactionsByMachine = try container.decode(
            [String: [String: DSHStoredSessionCreationTransaction]].self,
            forKey: .sessionCreationTransactionsByMachine)
        remoteMutationTransactionsByMachine = try container.decodeIfPresent(
            [String: [String: DSHRemoteMutationTransaction]].self,
            forKey: .remoteMutationTransactionsByMachine) ?? [:]
        lastSessionCreationRequestIDsByMachine = try container.decode(
            [String: String].self, forKey: .lastSessionCreationRequestIDsByMachine)
        initialMessageTransactionsByMachine = try container.decode(
            [String: [String: DSHStoredInitialMessageTransaction]].self,
            forKey: .initialMessageTransactionsByMachine)
        pendingPromptTransactionsByMachine = try container.decodeIfPresent(
            [String: [String: DSHStoredPendingSend]].self,
            forKey: .pendingPromptTransactionsByMachine) ?? [:]
        failedPromptTransactionsByMachine = try container.decodeIfPresent(
            [String: [String: DSHStoredFailedSend]].self,
            forKey: .failedPromptTransactionsByMachine) ?? [:]
        removedMachineIDs = try container.decodeIfPresent(Set<String>.self,
                                                         forKey: .removedMachineIDs) ?? []
    }
}

/// The reasoning choices exposed by the currently selected Harness model.
/// This is derived from the live model catalog rather than a hard-coded list,
/// so the phone follows additions/removals made by the desktop Harness.
struct DSHReasoningConfiguration: Equatable {
    let provider: String
    let model: String
    let efforts: [DSHModelReasoningEffort]
    let selectedEffortID: String

    var selectedEffort: DSHModelReasoningEffort? {
        efforts.first { $0.id == selectedEffortID }
    }
}

/// One shared interpretation of device reachability for every screen.
/// Relay health and Mac presence are intentionally not conflated.
enum DSHDeviceStatus: Equatable {
    case offline
    case error
    case online
    case approvalRequired
}

/// Per-session traffic light shown as the row dot.
enum DSHSessionDot: Sendable, Equatable {
    case none
    case green
    case yellow
    case red
}

@MainActor
final class DSHAppModel: ObservableObject {
    @Published private(set) var state: DSHStoreState
    @Published private(set) var isPaired: Bool
    @Published private(set) var isPairing = false
    /// Monotonic success marker used by the optional Add Mac sheet. A failed
    /// attempt must not dismiss a sheet merely because another Mac is already
    /// paired.
    @Published private(set) var pairingSuccessRevision = 0
    @Published var machineID = ""
    @Published var pairingSecret = ""
    @Published var serverAddress = UserDefaults.standard.string(forKey: "dsh-anywhere.server-address") ?? ""
    @Published var machineName = "My Mac"
    @Published var selectedSessionID: String?
    @Published var draft = ""
    @Published var showArchivedSessions = false
    /// Conversation presentation choices. These are local UI preferences and
    /// deliberately do not alter the Harness session itself.
    @Published var showUsageFooter: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.usageFooterKey) as? Bool ?? true
    /// Assistant copy/branch controls are visible by default, matching Remote.
    /// The setting remains available for a quieter transcript; user messages
    /// always use the native long-press copy menu instead of inline controls.
    @Published var showMessageActionsByDefault: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.messageActionsKey) as? Bool ?? true
    @Published var collapseComposerControls: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.composerCollapsedKey) as? Bool ?? true
    /// List arrangement and per-section collapse survive relaunch: they are
    /// browsing preferences, not session state.
    /// ChatGPT Remote's task home is organised by project. Keep the preference
    /// under the existing key so an upgrade preserves a deliberate user choice,
    /// while fresh installs open in the project-card layout by default.
    @Published var groupsSessionsByWorkspace: Bool =
        UserDefaults.standard.object(forKey: DSHAppModel.groupingKey) as? Bool ?? true
    @Published var collapsedSessionGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.collapsedGroupsKey) ?? [])
    /// The Harness bridge has no command for deleting one historical message.
    /// Keep a persistent, device-local suppression list so a confirmed delete
    /// does not reappear on refresh while the authoritative Mac transcript is
    /// left untouched.
    @Published private(set) var hiddenMessageKeys: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: DSHAppModel.hiddenMessagesKey) ?? [])
    /// Read markers are local to this phone. The Harness does not currently
    /// expose cross-device read receipts, but persisting the session timestamp
    /// is enough to highlight activity that arrived after the user last opened
    /// that conversation.
    @Published private(set) var lastReadSessionTimestamps: [String: Int64] =
        DSHAppModel.loadLastReadSessionTimestamps()
    /// Interface language. "Follow the device" is the default, and the choice
    /// survives relaunch like the other browsing preferences.
    @Published var language: DSHLanguage =
        DSHLanguage(rawValue: UserDefaults.standard.string(forKey: DSHAppModel.languageKey) ?? "") ?? .system
    @Published var errorMessage: String?
    /// A new-session attachment can fail before a normal prompt request is
    /// created. Keep its staged bytes in the pending map and expose a retry
    /// action for the matching conversation. The map is request-scoped so a
    /// successful first message in one session cannot clear another session's
    /// retry entry.
    @Published private(set) var failedInitialMessages: [String: DSHInitialMessageFailure] = [:]
    /// A create request remains recoverable after a local or remote rejection.
    /// NewSessionSheet keeps its draft visible until the user retries or
    /// explicitly returns to editing.
    @Published private(set) var failedSessionCreations: [String: DSHSessionCreationFailure] = [:]
    @Published private(set) var lastSessionCreationRequestID: String?
    @Published private(set) var completedSessionCreationRequestID: String?
    /// Completion is request-scoped.  The legacy single id remains a useful
    /// last-completed hint, but a dictionary prevents two acknowledgements in
    /// one event batch from overwriting the id a sheet is waiting for.
    @Published private(set) var sessionCreationResults: [String: String] = [:]
    /// Every Mac this iPhone is paired with, and which one is active.
    @Published private(set) var machines: [DSHRemoteProfile]
    /// Devices paired to the active machine, as the Relay reports them.
    @Published private(set) var pairedDevices: [DSHRelayDevice] = []
    /// Kept apart from `errorMessage` so a device-list failure does not pop an
    /// alert over whatever the user is doing in Settings.
    @Published var devicesError: String?
    /// The folder picker dismisses only after this request receives the Mac's
    /// `workspace.created` acknowledgement. `nil` means no confirmed result.
    @Published private(set) var createdWorkspace: DSHWorkspaceOption?
    @Published private(set) var isCreatingWorkspace = false
    @Published private(set) var isLoadingDirectory = false

    private let transport: any DSHAppTransport
    private let reducer = DSHEventReducer()
    /// Building transcript sections sorts and folds the entire local history.
    /// Live deltas change only one session, but SwiftUI asks several derived
    /// transcript properties during every body pass.  Keep one snapshot per
    /// session until an event for that session arrives, so a 20 Hz stream does
    /// not repeatedly rebuild the same history in a single frame.
    private var transcriptEntriesCache: [String: [DSHTranscriptEntry]] = [:]
    private var transcriptSectionsCache: [String: [DSHTranscriptSection]] = [:]
    private var eventTask: Task<Void, Never>?
    /// WebSocket deltas can arrive much faster than a phone needs to redraw.
    /// Keep the reducer authoritative, but publish one state snapshot per
    /// frame-sized window instead of invalidating every SwiftUI view for every
    /// token. This is what keeps live output responsive without a hot CPU.
    private var pendingEvents: [DSHEvent] = []
    private var eventFlushTask: Task<Void, Never>?
    /// Invalidates delayed callbacks when the active machine/socket changes.
    private var machineStateGeneration = 0
    /// Only the most recent machine-picker action may commit after awaiting
    /// Transport cleanup. This is separate from the connection generation:
    /// two valid choices can race even when both sockets are already gone.
    private var machineSelectionGeneration = 0
    /// The target of the currently suspended machine-picker action. Removing
    /// an unrelated profile must not cancel that action, while removing its
    /// target must invalidate it just like removing the active machine.
    private var pendingMachineSelectionID: String?
    /// A send or upload task captures this token before its first suspension.
    /// Views use it to discard stale attachment callbacks without changing
    /// machine state themselves.
    var currentMachineGeneration: Int { machineStateGeneration }

    func isCurrentMachineGeneration(_ generation: Int) -> Bool {
        machineStateGeneration == generation
    }
    /// The shared protocol measures prompt strings in UTF-16 code units (the
    /// JavaScript `String.length` semantics). Validate before clearing the
    /// editor so a rejected request leaves the user's complete draft intact.
    static let maxPromptUTF16Length = 100_000

    @discardableResult
    func validatePromptText(_ text: String) -> Bool {
        guard text.utf16.count <= Self.maxPromptUTF16Length else {
            errorMessage = "消息内容不能超过 100,000 个字符。"
            return false
        }
        return true
    }
    private static let eventBatchNanoseconds: UInt64 = 50_000_000
    /// A prompt upload completes before the Harness emits its accepted user
    /// message. Keep the local thumbnails under the prompt request id so a
    /// concurrent prompt or a historical row cannot consume the wrong set.
    private var pendingMessageAttachmentsByRequestID: [String: [DSHMessageAttachment]] = [:]
    private var pendingMessageAttachmentCleanupTasks: [String: Task<Void, Never>] = [:]
    /// Thumbnail bytes by receipt. NSCache, not a dict: image bytes are the
    /// largest thing the app holds, a dict would grow without bound, and
    /// cache reads happen off the main actor where a dict would race.
    private let attachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()
    /// Disk ceiling for the same thumbnails; enforced oldest-first on write.
    /// Nonisolated: the eviction sweep runs on a detached background task.
    nonisolated static let attachmentDiskBudgetBytes = 200 * 1024 * 1024
    private let deviceID = "ios-device"
    /// Creation acknowledgements are correlated by the Connector request id;
    /// never infer the created session from a later list snapshot.
    private var pendingSessionCreationRequestIDs: Set<String> = []
    private var pendingSessionCreationCommandsByRequestID: [String: DSHCommand] = [:]
    /// A create acknowledgement has a bounded waiting window.  Attempt
    /// generations ensure a timer from an older retry cannot fail the newer
    /// attempt after the same request id has been reused.
    private var sessionCreationAttemptGenerations: [String: Int] = [:]
    private var sessionCreationTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// Internal for deterministic tests; a real create gets fifteen seconds
    /// before the UI changes from an indeterminate spinner to recoverable
    /// "result unknown" state.
    var sessionCreationAckTimeout: TimeInterval = 15
    /// Historical HTTP cache window retained for UI copy and journal metadata.
    /// It is not a safety cutoff: the Bridge's durable create record remains
    /// the authority for resuming a committed-but-partially-configured task.
    static let sessionCreationIdempotencyWindow: TimeInterval = 10 * 60
    /// Matches the Connector/Bridge prompt request-id tombstone window.  A
    /// queue mirror may be resumed after a crash only while this identity is
    /// still guaranteed to coalesce at the remote side.
    static let promptIdempotencyWindow: TimeInterval = 10 * 60
    /// A second explicit tap is required before replacing an unknown mutation
    /// whose remote dedupe window has expired. This keeps the at-most-once
    /// default while still giving the user a durable escape hatch.
    private static let expiredRemoteMutationConfirmation = "结果未知的操作已过期；再次执行将创建新的请求。"
    /// The Bridge retains completed attachment identities for this period.
    /// Staged uploads use the same deadline so a long-offline phone never
    /// reuses an operation id after the Bridge has safely compacted it.
    static let attachmentRecoveryWindow: TimeInterval = dshAttachmentRecoveryWindow
    var sessionCreationRetryWindow: TimeInterval = 10 * 60
    private var sessionCreationRetryDeadlines: [String: Date] = [:]
    private var sessionCreationResultOrder: [String] = []
    /// Unknown creates are business transactions, not socket scratch state.
    /// Keep one snapshot per paired Mac so switching A -> B cannot delete an
    /// A request that may still complete on the original machine.
    private var sessionCreationTransactionsByMachine: [String: [String: DSHSessionCreationTransaction]] = [:]
    /// Durable request identities for native mutations other than prompt and
    /// session.create. A transport error is not proof that the Connector did
    /// not execute the command, so retries must find the original command.
    private var remoteMutationTransactionsByMachine: [String: [String: DSHRemoteMutationTransaction]] = [:]
    private var lastSessionCreationRequestIDsByMachine: [String: String] = [:]
    /// A session may already exist while its first prompt is still uploading
    /// or awaiting acceptance. Keep that second phase by machine as well, so
    /// a normal disconnect/switch cannot strand the user's original text or
    /// attachments in the cleared socket state.
    private var initialMessageTransactionsByMachine: [String: [String: DSHInitialMessageTransaction]] = [:]
    /// Requests explicitly kept while the user edits a new draft.  They stay
    /// correlated so a late `session.created` can still be settled instead of
    /// silently becoming an unrelated duplicate.
    private var detachedSessionCreationRequestIDs: Set<String> = []
    private var pendingWorkspaceCreationRequestID: String?
    /// The picker issues one navigation request at a time. Keeping its latest
    /// id prevents a slower parent-folder response from replacing a newer
    /// child-folder listing.
    private var pendingDirectoryRequestID: String?
    private var requestedCatalogsForConnection = false
    /// Attachments selected in the shared new-session composer stay local until
    /// the session exists. They are uploaded and sent as one initial prompt
    /// immediately after the matching `session.created` event arrives.
    private var pendingInitialMessagesByRequestID: [String: DSHPendingInitialMessage] = [:]
    private var pendingInitialMessageUploads: Set<String> = []
    /// Request ids currently awaited by `uploadAttachmentAndWait`. Their
    /// `protocolError`s are consumed by that waiter (see `surfaceProtocolError`)
    /// and must not also pop the global alert.
    private var uploadWaitRequestIDs: Set<String> = []
    /// Last `openSession` per session, to collapse duplicate replays.
    private var lastOpenSessionAt: [String: Date] = [:]
    /// The visible screen, unlike `lastOpenSessionAt`, is cleared when the
    /// user returns home. Replay recovery must not reopen a stale transcript
    /// behind the session list.
    private var visibleConversationSessionID: String?
    /// A Connector can explicitly say that its replay window no longer covers
    /// this phone's cursor. That is a recoverable cache miss, rather than a
    /// failed user command: once the current socket and Mac are ready again,
    /// request fresh authoritative projections. Keep this state per active
    /// machine generation so a delayed recovery can never read from a newly
    /// selected Mac.
    private var pendingReplayResynchronizationGeneration: Int?
    private var pendingReplayResynchronizationSessionIDs: Set<String> = []
    private var replayResynchronizationTask: Task<Void, Never>?
    /// Read-only requests can race construction of the initial socket. Store
    /// only the latest desired projections and replay them after readiness;
    /// no task mutation ever enters this queue.
    private var pendingReadOnlyRecoveryGeneration: Int?
    /// A local `.notConnected` can race a stale `.connected` UI state while
    /// URLSession is replacing its task. Do not retry until a *new* handshake
    /// readiness event has been observed, or the queue would spin on that
    /// stale state.
    private var readOnlyRecoveryReadinessRevision = 0
    private var requiredReadOnlyRecoveryReadinessRevision: Int?
    private var pendingSessionListRecovery = false
    private var pendingWorkspaceCatalogRecovery = false
    private var pendingModeCatalogRecovery = false
    private var pendingModelCatalogRecovery = false
    private var pendingSessionOpenRecoveryIDs: Set<String> = []
    private var readOnlyRecoveryTask: Task<Void, Never>?
    /// Force-merge tasks for history batches whose closing bracket never
    /// arrives (bridge died mid-stream). Keyed by the session and batch so a
    /// late callback from an older overlapping replay cannot cancel or clear
    /// the newer batch's timer.
    private var historyTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// History replay includes the stored terminal turn state. It must rebuild
    /// the transcript only; treating that state as a live completion would
    /// release a locally queued prompt while the user is merely opening an
    /// old session.
    private var replayingHistoryBatches: [String: Set<String>] = [:]
    /// Already-notified request ids and failed sessions (see notifyForEvent).
    private var notifiedApprovalIDs: Set<String> = []
    private var notifiedQuestionIDs: Set<String> = []
    private var notifiedFailedSessions: Set<String> = []

    private var pendingTransactionStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH Anywhere/pending-transactions.json")
    }

    private var pendingAttachmentDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH Anywhere/pending-attachments", isDirectory: true)
    }

    private var removedMachineIDsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH Anywhere/removed-machines.json")
    }

    private lazy var pendingTransactionFileStore = DSHPendingTransactionFileStore(
        metadataURL: pendingTransactionStoreURL,
        attachmentDirectoryURL: pendingAttachmentDirectoryURL,
        removedMachineIDsURL: removedMachineIDsURL)
    private var pendingPersistenceGeneration = 0

    private static let maxPendingAttachmentCount = 16
    private static let maxPendingAttachmentBytes = 192 * 1024 * 1024
    private static let maxAttachmentBytes = 10 * 1024 * 1024

    private var pendingPromptTransactionsByMachine: [String: [String: DSHPendingSend]] = [:]
    private var failedPromptTransactionsByMachine: [String: [String: DSHStoredFailedSend]] = [:]
    /// Explicitly removed machines remain fenced until a deliberate new pair
    /// clears the tombstone. This prevents old queue/journal data from
    /// resurfacing if local cleanup was interrupted.
    private var removedMachineIDs: Set<String> = []
    /// A present-but-unreadable fence must never be treated as an empty set.
    /// Keep every profile offline until the sidecar can be read again.
    private var removedMachineFenceUnavailable = false

    /// A transaction that cannot be written must never be sent again: after
    /// an app kill there would be no request identity left to coalesce the
    /// side effect. Keep recovery fail-closed until the next launch can read
    /// or recreate the store.
    private var pendingTransactionPersistenceUnavailable = false
    private enum PendingPersistenceResult: Equatable {
        case persisted
        case quotaExceeded
        case unavailable
    }
    private var pendingTransactionStoreLoaded = false
    /// Every mutation waits for the first journal load to merge disk state.
    /// Without this task, a user who switches/removes a Mac immediately after
    /// launch could write an empty in-memory snapshot over the old journal
    /// while the actor was still reading it.
    private var pendingTransactionStoreLoadTask: Task<Void, Never>?
    /// A disconnect suspends durable state asynchronously so file I/O never
    /// runs on the main actor.  Keep the UI transition observable immediately
    /// and let a connect request wait for the snapshot to finish.
    private var suspendingTransactions = false
    private var reconnectAfterSuspension = false

    private func materializeInitialMessage(_ stored: DSHStoredInitialMessage,
                                           blobs: [String: Data]) throws -> DSHPendingInitialMessage {
        guard stored.attachments.count <= Self.maxPendingAttachmentCount else {
            throw DSHAttachmentUploadError.tooLarge
        }
        var attachments: [DSHStagedAttachment] = []
        attachments.reserveCapacity(stored.attachments.count)
        for attachment in stored.attachments {
            let data: Data
            if let legacyData = attachment.legacyData {
                data = legacyData
            } else if let fileName = attachment.fileName,
                      fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                      fileName.hasSuffix(".blob") {
                guard let storedData = blobs[fileName] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data = storedData
            } else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard data.count <= Self.maxAttachmentBytes else { throw DSHAttachmentUploadError.tooLarge }
            attachments.append(DSHStagedAttachment(id: attachment.id, name: attachment.name,
                                                    data: data, isImage: attachment.isImage))
        }
        return DSHPendingInitialMessage(
            promptRequestID: stored.promptRequestID,
            text: stored.text,
            attachments: attachments,
            sessionID: stored.sessionID,
            dedupeExpiresAt: stored.dedupeExpiresAt,
            uploadedAttachments: stored.uploadedAttachments,
            attachmentRecoveryDeadline: stored.attachmentRecoveryDeadline)
    }

    private func loadPendingTransactionStore() async {
        do {
            let loaded = try await pendingTransactionFileStore.load()
            let store = loaded.store
            removedMachineIDs = store.removedMachineIDs
            var creations: [String: [String: DSHSessionCreationTransaction]] = [:]
            for (machineID, transactions) in store.sessionCreationTransactionsByMachine {
                var next: [String: DSHSessionCreationTransaction] = [:]
                for (requestID, transaction) in transactions {
                    next[requestID] = DSHSessionCreationTransaction(
                        command: transaction.command,
                        initialMessage: try transaction.initialMessage.map {
                            try materializeInitialMessage($0, blobs: loaded.blobs)
                        },
                        failure: transaction.failure,
                        detached: transaction.detached,
                        retryDeadline: transaction.retryDeadline)
                }
                creations[machineID] = next
            }
            // A user can submit or retry a request while this first-launch
            // load is still reading the journal.  Merge the freshly loaded
            // disk view instead of replacing those live maps and losing the
            // request before its first send.  Live entries win on collision;
            // their request identity is the newest authority in this process.
            for (activeMachineID, current) in sessionCreationTransactionsByMachine {
                var merged = creations[activeMachineID] ?? [:]
                merged.merge(current) { _, current in current }
                creations[activeMachineID] = merged
            }
            if !pendingSessionCreationRequestIDs.isEmpty {
                var current = creations[machineID] ?? [:]
                for requestID in pendingSessionCreationRequestIDs {
                    guard let command = pendingSessionCreationCommandsByRequestID[requestID] else { continue }
                    current[requestID] = DSHSessionCreationTransaction(
                        command: command,
                        initialMessage: pendingInitialMessagesByRequestID[requestID],
                        failure: failedSessionCreations[requestID],
                        detached: detachedSessionCreationRequestIDs.contains(requestID),
                        retryDeadline: sessionCreationRetryDeadlines[requestID]
                            ?? Date().addingTimeInterval(sessionCreationRetryWindow))
                }
                creations[machineID] = current
            }
            for removedMachineID in removedMachineIDs {
                creations.removeValue(forKey: removedMachineID)
            }
            sessionCreationTransactionsByMachine = creations
            var remoteMutations = store.remoteMutationTransactionsByMachine
            // Once the app has restarted, an entry without a terminal
            // acknowledgement is an unknown result even if the process died
            // between journaling and the first send. Reusing its exact
            // request id is safe in both cases and prevents an accidental
            // second native mutation.
            for (activeMachineID, current) in remoteMutationTransactionsByMachine {
                var merged = remoteMutations[activeMachineID] ?? [:]
                merged.merge(current) { _, current in current }
                remoteMutations[activeMachineID] = merged
            }
            var restoredRemoteMutations: [String: [String: DSHRemoteMutationTransaction]] = [:]
            for (activeMachineID, transactions) in remoteMutations {
                restoredRemoteMutations[activeMachineID] = transactions.mapValues { transaction in
                    var restored = transaction
                    if restored.failure == nil {
                        restored.failure = "连接已断开，操作结果待确认。"
                    }
                    return restored
                }
            }
            remoteMutations = restoredRemoteMutations
            for removedMachineID in removedMachineIDs {
                remoteMutations.removeValue(forKey: removedMachineID)
            }
            remoteMutationTransactionsByMachine = remoteMutations
            var lastIDs = store.lastSessionCreationRequestIDsByMachine
            for removedMachineID in removedMachineIDs {
                lastIDs.removeValue(forKey: removedMachineID)
            }
            for (activeMachineID, requestID) in lastSessionCreationRequestIDsByMachine {
                if !removedMachineIDs.contains(activeMachineID) {
                    lastIDs[activeMachineID] = requestID
                }
            }
            if let lastSessionCreationRequestID,
               !machineID.isEmpty, !removedMachineIDs.contains(machineID) {
                lastIDs[machineID] = lastSessionCreationRequestID
            }
            lastSessionCreationRequestIDsByMachine = lastIDs
            var initialMessages: [String: [String: DSHInitialMessageTransaction]] = [:]
            for (machineID, transactions) in store.initialMessageTransactionsByMachine {
                var next: [String: DSHInitialMessageTransaction] = [:]
                for (requestID, transaction) in transactions {
                    next[requestID] = DSHInitialMessageTransaction(
                        pending: try materializeInitialMessage(transaction.pending, blobs: loaded.blobs),
                        failure: transaction.failure)
                }
                initialMessages[machineID] = next
            }
            for (activeMachineID, current) in initialMessageTransactionsByMachine {
                var merged = initialMessages[activeMachineID] ?? [:]
                merged.merge(current) { _, current in current }
                initialMessages[activeMachineID] = merged
            }
            if !pendingInitialMessagesByRequestID.isEmpty {
                var current = initialMessages[machineID] ?? [:]
                for (requestID, pending) in pendingInitialMessagesByRequestID {
                    guard let sessionID = pending.sessionID else { continue }
                    current[requestID] = DSHInitialMessageTransaction(
                        pending: pending,
                        failure: failedInitialMessages[requestID]
                            ?? DSHInitialMessageFailure(
                                id: requestID, sessionID: sessionID, text: pending.text,
                                detail: "连接已断开，首条消息待重试。"))
                }
                initialMessages[machineID] = current
            }
            for removedMachineID in removedMachineIDs {
                initialMessages.removeValue(forKey: removedMachineID)
            }
            initialMessageTransactionsByMachine = initialMessages
            var pendingPrompts: [String: [String: DSHPendingSend]] = [:]
            for (storedMachineID, transactions) in store.pendingPromptTransactionsByMachine {
                var restored: [String: DSHPendingSend] = [:]
                for (requestID, stored) in transactions {
                    restored[requestID] = try pendingSend(stored, blobs: loaded.blobs)
                }
                pendingPrompts[storedMachineID] = restored
            }
            for (activeMachineID, current) in pendingPromptTransactionsByMachine {
                var merged = pendingPrompts[activeMachineID] ?? [:]
                merged.merge(current) { _, current in current }
                pendingPrompts[activeMachineID] = merged
            }
            if !pendingSendsByRequestID.isEmpty {
                var current = pendingPrompts[machineID] ?? [:]
                current.merge(pendingSendsByRequestID) { _, current in current }
                pendingPrompts[machineID] = current
            }
            for removedMachineID in removedMachineIDs {
                pendingPrompts.removeValue(forKey: removedMachineID)
            }
            pendingPromptTransactionsByMachine = pendingPrompts
            var failedPrompts = store.failedPromptTransactionsByMachine
            for (activeMachineID, current) in failedPromptTransactionsByMachine {
                var merged = failedPrompts[activeMachineID] ?? [:]
                merged.merge(current) { _, current in current }
                failedPrompts[activeMachineID] = merged
            }
            if !failedSendsByRequestID.isEmpty {
                var current = failedPrompts[machineID] ?? [:]
                current.merge(failedSendsByRequestID.mapValues(storedFailedSend)) { _, current in current }
                failedPrompts[machineID] = current
            }
            for removedMachineID in removedMachineIDs {
                failedPrompts.removeValue(forKey: removedMachineID)
            }
            failedPromptTransactionsByMachine = failedPrompts
        } catch {
            if let loadError = error as? DSHPendingTransactionStoreLoadError {
                removedMachineIDs = loadError.fencedMachineIDs
                removedMachineFenceUnavailable = loadError.fenceUnavailable
            }
            let nsError = error as NSError
            if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError) {
                pendingTransactionPersistenceUnavailable = true
                errorMessage = removedMachineFenceUnavailable
                    ? "未能读取本机删除记录，已停止连接以保护待处理请求。"
                    : "未能读取待处理请求，已停止自动重试。"
            }
        }
        pendingTransactionStoreLoaded = true
        let loadedMachineID = machineID
        restoreSessionCreationTransactions(for: loadedMachineID)
        // A fence is durable lifecycle intent.  If the process died after a
        // remove/forget (or a failed pair rollback) wrote that fence but before
        // the profile/token deletion finished, do the local deletion on the
        // next launch.  Otherwise the fenced profile remains selectable and
        // can block the healthy profiles that should have become active.
        await reconcileFencedProfiles()
        if let active = activeMachine, !removedMachineIDs.contains(active.machineId) {
            if active.machineId != loadedMachineID {
                machineName = active.machineName
                machineID = active.machineId
                resetTransientRequestState()
                state = DSHStoreState()
                restoreSessionCreationTransactions(for: active.machineId)
            } else {
                machineName = active.machineName
            }
            isPaired = true
            connect()
        } else {
            machineName = ""
            machineID = ""
            isPaired = false
            state.connectionState = .disconnected
            state.transportState = .disconnected
        }
    }

    /// A removal/forget operation fences before deleting local credentials so
    /// a crash cannot resurrect queued side effects.  Reconcile that intent on
    /// startup by deleting every still-present fenced profile and letting the
    /// profile store choose the next active machine.
    private func reconcileFencedProfiles() async {
        guard !removedMachineFenceUnavailable else {
            // A corrupt sidecar cannot be safely interpreted. Do not delete
            // or reconnect any profile until the authoritative fence is
            // readable again.
            return
        }
        let fencedProfiles = profiles.profiles.filter { removedMachineIDs.contains($0.machineId) }
        guard !fencedProfiles.isEmpty else {
            refreshMachines()
            return
        }
        for profile in fencedProfiles {
            await transport.rollbackPairing(machineId: profile.machineId)
        }
        refreshMachines()
    }

    private func makePendingTransactionSnapshot() throws -> DSHPendingTransactionSnapshot {
        var referencedBlobNames = Set<String>()
        var blobs: [String: Data] = [:]
        var attachmentBytes = 0
        func storeAttachments(_ values: [DSHStagedAttachment]) throws -> [DSHStoredAttachment] {
            guard values.count <= Self.maxPendingAttachmentCount else {
                throw DSHAttachmentUploadError.tooLarge
            }
            var attachments: [DSHStoredAttachment] = []
            attachments.reserveCapacity(values.count)
            for attachment in values {
                guard attachment.data.count <= Self.maxAttachmentBytes else {
                    throw DSHAttachmentUploadError.tooLarge
                }
                attachmentBytes += attachment.data.count
                guard attachmentBytes <= Self.maxPendingAttachmentBytes else {
                    throw DSHAttachmentUploadError.quotaExceeded
                }
                let fileName = "\(attachment.id.uuidString).blob"
                referencedBlobNames.insert(fileName)
                blobs[fileName] = attachment.data
                attachments.append(DSHStoredAttachment(id: attachment.id, name: attachment.name,
                                                        isImage: attachment.isImage, fileName: fileName))
            }
            return attachments
        }
        func storedInitialMessage(_ pending: DSHPendingInitialMessage) throws -> DSHStoredInitialMessage {
            let attachments = try storeAttachments(pending.attachments)
            return DSHStoredInitialMessage(
                promptRequestID: pending.promptRequestID,
                text: pending.text,
                attachments: attachments,
                sessionID: pending.sessionID,
                uploadedAttachments: pending.uploadedAttachments,
                dedupeExpiresAt: pending.dedupeExpiresAt,
                attachmentRecoveryDeadline: pending.attachmentRecoveryDeadline)
        }
        func storedPendingSend(_ pending: DSHPendingSend) throws -> DSHStoredPendingSend {
            let attachments = try storeAttachments(pending.stagedAttachments)
            return DSHStoredPendingSend(
                id: pending.id, text: pending.text, receipts: pending.receipts,
                sessionID: pending.sessionID, mode: pending.mode, sentAt: pending.sentAt,
                dedupeExpiresAt: pending.dedupeExpiresAt,
                attempt: pending.attempt, messageAttachments: pending.messageAttachments,
                stagedAttachments: attachments.isEmpty ? nil : attachments,
                uploadedAttachments: pending.uploadedAttachments.isEmpty ? nil : pending.uploadedAttachments,
                phase: pending.phase,
                attachmentRecoveryDeadline: pending.attachmentRecoveryDeadline)
        }
        var storedCreations: [String: [String: DSHStoredSessionCreationTransaction]] = [:]
        for (machineID, transactions) in sessionCreationTransactionsByMachine {
            var next: [String: DSHStoredSessionCreationTransaction] = [:]
            for (requestID, transaction) in transactions {
                next[requestID] = DSHStoredSessionCreationTransaction(
                    command: transaction.command,
                    initialMessage: try transaction.initialMessage.map(storedInitialMessage),
                    failure: transaction.failure,
                    detached: transaction.detached,
                    retryDeadline: transaction.retryDeadline)
            }
            storedCreations[machineID] = next
        }
        var storedInitialMessages: [String: [String: DSHStoredInitialMessageTransaction]] = [:]
        for (machineID, transactions) in initialMessageTransactionsByMachine {
            var next: [String: DSHStoredInitialMessageTransaction] = [:]
            for (requestID, transaction) in transactions {
                next[requestID] = DSHStoredInitialMessageTransaction(
                    pending: try storedInitialMessage(transaction.pending),
                    failure: transaction.failure)
            }
            storedInitialMessages[machineID] = next
        }
        var storedPendingPrompts: [String: [String: DSHStoredPendingSend]] = [:]
        for (storedMachineID, transactions) in pendingPromptTransactionsByMachine {
            var stored: [String: DSHStoredPendingSend] = [:]
            for (requestID, pending) in transactions {
                stored[requestID] = try storedPendingSend(pending)
            }
            storedPendingPrompts[storedMachineID] = stored
        }
        if !machineID.isEmpty {
            if pendingSendsByRequestID.isEmpty {
                storedPendingPrompts.removeValue(forKey: machineID)
            } else {
                var current: [String: DSHStoredPendingSend] = [:]
                for (requestID, pending) in pendingSendsByRequestID {
                    current[requestID] = try storedPendingSend(pending)
                }
                storedPendingPrompts[machineID] = current
            }
        }
        let store = DSHPendingTransactionStore(
            sessionCreationTransactionsByMachine: storedCreations,
            remoteMutationTransactionsByMachine: remoteMutationTransactionsByMachine,
            lastSessionCreationRequestIDsByMachine: lastSessionCreationRequestIDsByMachine,
            initialMessageTransactionsByMachine: storedInitialMessages,
            pendingPromptTransactionsByMachine: storedPendingPrompts,
            failedPromptTransactionsByMachine: failedPromptTransactionsByMachine,
            removedMachineIDs: removedMachineIDs)
        pendingPersistenceGeneration += 1
        return DSHPendingTransactionSnapshot(metadata: try JSONEncoder().encode(store),
                                              blobs: blobs,
                                              referencedBlobNames: referencedBlobNames,
                                              generation: pendingPersistenceGeneration)
    }

    @discardableResult
    private func persistPendingTransactionStoreResult() async -> PendingPersistenceResult {
        await awaitPendingTransactionStoreLoaded()
        guard pendingTransactionStoreLoaded else {
            return .unavailable
        }
        guard !pendingTransactionPersistenceUnavailable else {
            return .unavailable
        }
        do {
            let snapshot = try makePendingTransactionSnapshot()
            try await pendingTransactionFileStore.write(snapshot)
            return .persisted
        } catch DSHAttachmentUploadError.quotaExceeded {
            // A valid batch can exceed the aggregate attachment budget while
            // the journal itself is perfectly healthy. Do not poison the
            // process-wide persistence gate: deleting/cancelling an older
            // transaction must be able to free space and persist again.
            errorMessage = "待处理附件总量已达到上限，请先取消旧请求后重试。"
            return .quotaExceeded
        } catch {
            // Keep the in-memory transaction and surface the loss of durable
            // recovery explicitly. The app refuses further side effects until
            // the next launch can recreate or repair the store; silently
            // dropping the record would turn a process kill into a duplicate.
            pendingTransactionPersistenceUnavailable = true
            errorMessage = "无法保存待处理请求，暂不安全重试。"
            return .unavailable
        }
    }

    @discardableResult
    private func persistPendingTransactionStore() async -> Bool {
        if case .persisted = await persistPendingTransactionStoreResult() { return true }
        return false
    }

    private func persistPendingTransactionStoreLater() {
        Task { @MainActor [weak self] in
            _ = await self?.persistPendingTransactionStore()
        }
    }

    /// Removed-machine fences live in a tiny sidecar so a large attachment
    /// journal failure cannot erase the lifecycle boundary that prevents old
    /// requests from returning after re-pairing.
    @discardableResult
    private func persistRemovedMachineFence() async -> Bool {
        do {
            try await pendingTransactionFileStore.writeRemovedMachineIDs(removedMachineIDs)
            return true
        } catch {
            errorMessage = "无法安全保存本机删除记录，已停止继续配对或删除。"
            return false
        }
    }

    private func persistCurrentTransactionsLater(for machineID: String) {
        Task { @MainActor [weak self] in
            _ = await self?.persistCurrentTransactions(for: machineID)
        }
    }

    private func storedPendingSend(_ value: DSHPendingSend) -> DSHStoredPendingSend {
        DSHStoredPendingSend(id: value.id, text: value.text, receipts: value.receipts,
                             sessionID: value.sessionID, mode: value.mode, sentAt: value.sentAt,
                             dedupeExpiresAt: value.dedupeExpiresAt,
                             attempt: value.attempt, messageAttachments: value.messageAttachments,
                             phase: value.phase,
                             attachmentRecoveryDeadline: value.attachmentRecoveryDeadline)
    }

    private func pendingSend(_ value: DSHStoredPendingSend,
                             blobs: [String: Data] = [:]) throws -> DSHPendingSend {
        var staged: [DSHStagedAttachment] = []
        let storedAttachments = value.stagedAttachments ?? []
        guard storedAttachments.count <= Self.maxPendingAttachmentCount else {
            throw DSHAttachmentUploadError.tooLarge
        }
        for attachment in storedAttachments {
            let data: Data
            if let legacyData = attachment.legacyData {
                data = legacyData
            } else if let fileName = attachment.fileName,
                      let storedData = blobs[fileName] {
                data = storedData
            } else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard data.count <= Self.maxAttachmentBytes else {
                throw DSHAttachmentUploadError.tooLarge
            }
            staged.append(DSHStagedAttachment(id: attachment.id, name: attachment.name,
                                               data: data, isImage: attachment.isImage))
        }
        return DSHPendingSend(id: value.id, text: value.text, receipts: value.receipts,
                       sessionID: value.sessionID, mode: value.mode, sentAt: value.sentAt,
                       dedupeExpiresAt: value.dedupeExpiresAt,
                       attempt: value.attempt, messageAttachments: value.messageAttachments,
                       phase: value.phase ?? (staged.isEmpty
                           ? (value.uploadedAttachments?.isEmpty == false ? .readyToSend : .awaitingAck)
                           : .preparing),
                       stagedAttachments: staged,
                       uploadedAttachments: value.uploadedAttachments ?? [:])
    }

    private func storedFailure(_ value: DSHSendFailure) -> DSHStoredSendFailure {
        switch value {
        case .local(let detail): return .local(detail)
        case .server(let detail): return .server(detail)
        }
    }

    private func failure(_ value: DSHStoredSendFailure) -> DSHSendFailure {
        switch value {
        case .local(let detail): return .local(detail)
        case .server(let detail): return .server(detail)
        }
    }

    private func storedFailedSend(_ value: DSHFailedSend) -> DSHStoredFailedSend {
        DSHStoredFailedSend(id: value.id, text: value.text, receipts: value.receipts,
                            sessionID: value.sessionID, mode: value.mode,
                            messageAttachments: value.messageAttachments,
                            failure: storedFailure(value.failure), retryUntil: value.retryUntil)
    }

    private func failedSend(_ value: DSHStoredFailedSend) -> DSHFailedSend {
        DSHFailedSend(id: value.id, text: value.text, receipts: value.receipts,
                      sessionID: value.sessionID, mode: value.mode,
                      messageAttachments: value.messageAttachments,
                      failure: failure(value.failure), retryUntil: value.retryUntil)
    }

    /// Rebuilds the per-machine durable view from the live request maps. This
    /// is called after every mutation that could otherwise be lost if iOS is
    /// killed without giving the socket a disconnect callback.
    @discardableResult
    private func persistCurrentTransactions(for machineID: String) async -> Bool {
        await awaitPendingTransactionStoreLoaded()
        guard pendingTransactionStoreLoaded else { return false }
        guard !pendingTransactionPersistenceUnavailable else { return false }
        let previousCreationSnapshot = sessionCreationTransactionsByMachine[machineID]
        let previousRemoteMutationSnapshot = remoteMutationTransactionsByMachine[machineID]
        let previousLastCreationRequestID = lastSessionCreationRequestIDsByMachine[machineID]
        let previousInitialSnapshot = initialMessageTransactionsByMachine[machineID]
        let previousPendingSnapshot = pendingPromptTransactionsByMachine[machineID]
        let previousFailedSnapshot = failedPromptTransactionsByMachine[machineID]
        var creationSnapshot: [String: DSHSessionCreationTransaction] = [:]
        for requestID in pendingSessionCreationRequestIDs {
            guard let command = pendingSessionCreationCommandsByRequestID[requestID] else { continue }
            creationSnapshot[requestID] = DSHSessionCreationTransaction(
                command: command,
                initialMessage: pendingInitialMessagesByRequestID[requestID],
                failure: failedSessionCreations[requestID],
                detached: detachedSessionCreationRequestIDs.contains(requestID),
                retryDeadline: sessionCreationRetryDeadlines[requestID]
                    ?? Date().addingTimeInterval(sessionCreationRetryWindow))
        }
        if creationSnapshot.isEmpty {
            sessionCreationTransactionsByMachine.removeValue(forKey: machineID)
            lastSessionCreationRequestIDsByMachine.removeValue(forKey: machineID)
        } else {
            sessionCreationTransactionsByMachine[machineID] = creationSnapshot
            if let lastSessionCreationRequestID,
               creationSnapshot[lastSessionCreationRequestID] != nil {
                lastSessionCreationRequestIDsByMachine[machineID] = lastSessionCreationRequestID
            }
        }

        var initialSnapshot: [String: DSHInitialMessageTransaction] = [:]
        for (requestID, pending) in pendingInitialMessagesByRequestID {
            guard let sessionID = pending.sessionID else { continue }
            let failure = failedInitialMessages[requestID]
                ?? DSHInitialMessageFailure(
                    id: requestID,
                    sessionID: sessionID,
                    text: pending.text,
                    detail: "连接已断开，首条消息待重试。")
            initialSnapshot[requestID] = DSHInitialMessageTransaction(
                pending: pending, failure: failure)
        }
        if initialSnapshot.isEmpty {
            initialMessageTransactionsByMachine.removeValue(forKey: machineID)
        } else {
            initialMessageTransactionsByMachine[machineID] = initialSnapshot
        }
        if pendingSendsByRequestID.isEmpty {
            pendingPromptTransactionsByMachine.removeValue(forKey: machineID)
        } else {
            pendingPromptTransactionsByMachine[machineID] = pendingSendsByRequestID
        }
        if failedSendsByRequestID.isEmpty {
            failedPromptTransactionsByMachine.removeValue(forKey: machineID)
        } else {
            failedPromptTransactionsByMachine[machineID] = failedSendsByRequestID.mapValues(storedFailedSend)
        }
        // Preview/test transports can be marked paired before a profile has a
        // machine id.  Keep their in-memory per-machine snapshot so a
        // disconnect/reconnect still restores an in-flight request, while
        // avoiding a shared on-disk journal entry that could leak between
        // unrelated preview models.
        guard !machineID.isEmpty else { return true }
        let persistenceResult = await persistPendingTransactionStoreResult()
        guard persistenceResult != .quotaExceeded else {
            if let previousCreationSnapshot {
                sessionCreationTransactionsByMachine[machineID] = previousCreationSnapshot
            } else {
                sessionCreationTransactionsByMachine.removeValue(forKey: machineID)
            }
            if let previousRemoteMutationSnapshot {
                remoteMutationTransactionsByMachine[machineID] = previousRemoteMutationSnapshot
            } else {
                remoteMutationTransactionsByMachine.removeValue(forKey: machineID)
            }
            if let previousLastCreationRequestID {
                lastSessionCreationRequestIDsByMachine[machineID] = previousLastCreationRequestID
            } else {
                lastSessionCreationRequestIDsByMachine.removeValue(forKey: machineID)
            }
            if let previousInitialSnapshot {
                initialMessageTransactionsByMachine[machineID] = previousInitialSnapshot
            } else {
                initialMessageTransactionsByMachine.removeValue(forKey: machineID)
            }
            if let previousPendingSnapshot {
                pendingPromptTransactionsByMachine[machineID] = previousPendingSnapshot
            } else {
                pendingPromptTransactionsByMachine.removeValue(forKey: machineID)
            }
            if let previousFailedSnapshot {
                failedPromptTransactionsByMachine[machineID] = previousFailedSnapshot
            } else {
                failedPromptTransactionsByMachine.removeValue(forKey: machineID)
            }
            return false
        }
        return persistenceResult == .persisted
    }

    /// Every transaction-store mutation must wait for the startup merge.  A
    /// caller that only wants to remove a non-active machine can otherwise
    /// mutate the empty in-memory maps while the loader is still reading the
    /// old journal, allowing the loader's merge to resurrect that machine.
    private func awaitPendingTransactionStoreLoaded() async {
        if !pendingTransactionStoreLoaded {
            await pendingTransactionStoreLoadTask?.value
        }
    }

    @discardableResult
    private func suspendSessionCreationTransactions(for machineID: String) async -> Bool {
        return await persistCurrentTransactions(for: machineID)
    }

    private func restoreSessionCreationTransactions(for machineID: String) {
        guard !removedMachineIDs.contains(machineID) else { return }
        if let snapshot = sessionCreationTransactionsByMachine[machineID] {
            for (requestID, transaction) in snapshot {
                pendingSessionCreationRequestIDs.insert(requestID)
                pendingSessionCreationCommandsByRequestID[requestID] = transaction.command
                if let initialMessage = transaction.initialMessage {
                    pendingInitialMessagesByRequestID[requestID] = initialMessage
                }
                if let failure = transaction.failure {
                    failedSessionCreations[requestID] = failure
                }
                sessionCreationRetryDeadlines[requestID] = transaction.retryDeadline
                if transaction.detached { detachedSessionCreationRequestIDs.insert(requestID) }
            }
            lastSessionCreationRequestID = lastSessionCreationRequestIDsByMachine[machineID]
                ?? snapshot.keys.sorted().last
            for requestID in pendingSessionCreationRequestIDs where failedSessionCreations[requestID] == nil {
                armSessionCreationTimeout(requestID: requestID)
            }
        }
        if let initialSnapshot = initialMessageTransactionsByMachine[machineID] {
            for (requestID, transaction) in initialSnapshot {
                pendingInitialMessagesByRequestID[requestID] = transaction.pending
                if let failure = transaction.failure {
                    failedInitialMessages[requestID] = failure
                }
            }
        }
        // Restore existing failures before expiring stale awaitingAck
        // transactions. timeoutPendingSend() creates new entries in this map;
        // assigning the disk snapshot afterwards would erase those freshly
        // recovered retry records.
        if let failedSnapshot = failedPromptTransactionsByMachine[machineID] {
            let restored = failedSnapshot.mapValues(failedSend)
            failedSendsByRequestID.merge(restored) { current, _ in current }
        }
        if let pendingSnapshot = pendingPromptTransactionsByMachine[machineID] {
            pendingSendsByRequestID = pendingSnapshot
            for pending in pendingSendsByRequestID.values {
                guard pending.phase == .awaitingAck else { continue }
                let elapsed = Date().timeIntervalSince(pending.sentAt)
                if elapsed >= sendAckTimeout {
                    timeoutPendingSend(requestId: pending.id, attempt: pending.attempt)
                } else {
                    armSendAckTimeout(requestId: pending.id, attempt: pending.attempt,
                                      delay: sendAckTimeout - elapsed)
                }
            }
        }
    }

    private func removeStoredSessionCreationTransaction(_ requestID: String, for machineID: String) {
        guard var snapshot = sessionCreationTransactionsByMachine[machineID] else {
            persistPendingTransactionStoreLater()
            return
        }
        snapshot.removeValue(forKey: requestID)
        if snapshot.isEmpty {
            sessionCreationTransactionsByMachine.removeValue(forKey: machineID)
            lastSessionCreationRequestIDsByMachine.removeValue(forKey: machineID)
        } else {
            sessionCreationTransactionsByMachine[machineID] = snapshot
            if lastSessionCreationRequestIDsByMachine[machineID] == requestID {
                lastSessionCreationRequestIDsByMachine[machineID] = snapshot.keys.sorted().last
            }
        }
        persistPendingTransactionStoreLater()
    }

    private func removeStoredInitialMessageTransaction(_ requestID: String, for machineID: String) {
        guard var snapshot = initialMessageTransactionsByMachine[machineID] else {
            persistPendingTransactionStoreLater()
            return
        }
        snapshot.removeValue(forKey: requestID)
        if snapshot.isEmpty {
            initialMessageTransactionsByMachine.removeValue(forKey: machineID)
        } else {
            initialMessageTransactionsByMachine[machineID] = snapshot
        }
        persistPendingTransactionStoreLater()
    }

    /// Drops all in-flight per-machine bookkeeping. History batches belong to
    /// the previous machine's socket, so their timeouts die here too (the
    /// state reset already drops any carried-over rows).
    private func resetTransientRequestState() {
        machineStateGeneration += 1
        replayResynchronizationTask?.cancel()
        replayResynchronizationTask = nil
        pendingReplayResynchronizationGeneration = nil
        pendingReplayResynchronizationSessionIDs.removeAll(keepingCapacity: false)
        visibleConversationSessionID = nil
        readOnlyRecoveryTask?.cancel()
        readOnlyRecoveryTask = nil
        pendingReadOnlyRecoveryGeneration = nil
        readOnlyRecoveryReadinessRevision = 0
        requiredReadOnlyRecoveryReadinessRevision = nil
        pendingSessionListRecovery = false
        pendingWorkspaceCatalogRecovery = false
        pendingModeCatalogRecovery = false
        pendingModelCatalogRecovery = false
        pendingSessionOpenRecoveryIDs.removeAll(keepingCapacity: false)
        pendingEvents.removeAll(keepingCapacity: false)
        transcriptEntriesCache.removeAll(keepingCapacity: false)
        transcriptSectionsCache.removeAll(keepingCapacity: false)
        pendingInitialMessagesByRequestID.removeAll(keepingCapacity: false)
        pendingInitialMessageUploads.removeAll(keepingCapacity: false)
        for task in pendingMessageAttachmentCleanupTasks.values { task.cancel() }
        pendingMessageAttachmentCleanupTasks.removeAll(keepingCapacity: false)
        pendingMessageAttachmentsByRequestID.removeAll(keepingCapacity: false)
        pendingSendsByRequestID.removeAll(keepingCapacity: false)
        stagedPromptResumeIDs.removeAll(keepingCapacity: false)
        stagedPromptUploadIDs.removeAll(keepingCapacity: false)
        cancelledStagedPromptIDs.removeAll(keepingCapacity: false)
        sendAttemptGenerations.removeAll(keepingCapacity: false)
        uploadWaitRequestIDs.removeAll(keepingCapacity: false)
        failedSendsByRequestID.removeAll(keepingCapacity: false)
        failedInitialMessages.removeAll(keepingCapacity: false)
        failedSessionCreations.removeAll(keepingCapacity: false)
        lastSessionCreationRequestID = nil
        completedSessionCreationRequestID = nil
        sessionCreationResults.removeAll(keepingCapacity: false)
        sessionCreationResultOrder.removeAll(keepingCapacity: false)
        sessionCreationRetryDeadlines.removeAll(keepingCapacity: false)
        for task in historyTimeoutTasks.values { task.cancel() }
        historyTimeoutTasks.removeAll(keepingCapacity: false)
        replayingHistoryBatches.removeAll(keepingCapacity: false)
        lastOpenSessionAt.removeAll(keepingCapacity: false)
        pendingSessionCreationRequestIDs.removeAll(keepingCapacity: false)
        pendingSessionCreationCommandsByRequestID.removeAll(keepingCapacity: false)
        for task in sessionCreationTimeoutTasks.values { task.cancel() }
        sessionCreationTimeoutTasks.removeAll(keepingCapacity: false)
        sessionCreationAttemptGenerations.removeAll(keepingCapacity: false)
        detachedSessionCreationRequestIDs.removeAll(keepingCapacity: false)
        pendingWorkspaceCreationRequestID = nil
        pendingDirectoryRequestID = nil
        isCreatingWorkspace = false
        isLoadingDirectory = false
        requestedCatalogsForConnection = false
        // Queued prompts belong to one machine: swap the in-memory set for
        // the newly active machine's persisted one (disk already holds both).
        queuedPromptSendIDs.removeAll(keepingCapacity: false)
        queuedPromptsBySession.removeAll(keepingCapacity: false)
        restoreQueuedPrompts()
    }
    private let profiles = DSHProfileStore()
    private let unreadBaseline = DSHAppModel.loadOrCreateUnreadBaseline()
    static let groupingKey = "dsh-anywhere.session-list-grouping"
    static let languageKey = "dsh-anywhere.language"
    static let collapsedGroupsKey = "dsh-anywhere.collapsed-groups"
    static let usageFooterKey = "dsh-anywhere.show-session-usage"
    static let messageActionsKey = "dsh-anywhere.show-message-actions-by-default"
    static let composerCollapsedKey = "dsh-anywhere.collapse-composer-controls"
    static let hiddenMessagesKey = "dsh-anywhere.hidden-messages"
    static let lastReadSessionsKey = "dsh-anywhere.last-read-session-timestamps"
    static let unreadBaselineKey = "dsh-anywhere.unread-baseline"

    init(transport: any DSHAppTransport = DSHRemoteTransport(),
         initialState: DSHStoreState = .init(), isPaired: Bool? = nil) {
        self.transport = transport
        self.state = initialState
        let stored = DSHProfileStore()
        self.machines = stored.profiles
        self.isPaired = isPaired ?? DSHRemoteTransport.isConfigured
        if let active = stored.activeProfile {
            self.machineName = active.machineName
            self.machineID = active.machineId
        }
        let loadTask: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPendingTransactionStore()
        }
        self.pendingTransactionStoreLoadTask = loadTask
        restoreQueuedPrompts()
    }

    /// The Mac the app is currently talking to.
    var activeMachine: DSHRemoteProfile? { profiles.activeProfile }

    var sessions: [DSHSessionSummary] { state.sessions }
    var hasLoadedSessions: Bool { state.hasLoadedSessions }
    var modelCatalog: DSHModelCatalog? { state.modelCatalog }
    var pendingApprovals: [DSHApprovalRequest] { state.pendingApprovals }
    var pendingQuestions: [DSHQuestionRequest] { state.pendingQuestions }
    var connectionState: DSHConnectionState { state.connectionState }

    /// A paired launch first restores the local transaction journal, then
    /// starts Relay. During that short handoff the transport still reports
    /// `disconnected`, but no connection attempt has failed and the Mac has
    /// not been confirmed offline. Keep Home in its connecting presentation
    /// instead of flashing the actionable "unreachable" state.
    var isPreparingInitialConnection: Bool {
        isPaired && !state.hasLoadedSessions && !pendingTransactionStoreLoaded
    }

    /// Per-session traffic light, same hues as the header status dot:
    /// red = turn died on an error, yellow = the Mac is waiting on the
    /// user (approval or questions), green = unread or running activity.
    func sessionDot(for session: DSHSessionSummary) -> DSHSessionDot {
        let turn = turnState(for: session.id).lowercased()
        if turn == "failed" || turn == "error" { return .red }
        if pendingApprovals.contains(where: { $0.sessionId == session.id })
            || pendingQuestions.contains(where: { $0.sessionId == session.id }) {
            return .yellow
        }
        if session.running == true || isSessionUnread(session) { return .green }
        return .none
    }

    var deviceStatus: DSHDeviceStatus {
        switch state.transportState {
        case .failed:
            return .error
        case .reconnecting(let attempt) where attempt >= 3:
            return .error
        default:
            break
        }
        guard state.transportState == .connected, state.machineOnline else { return .offline }
        if state.bridgeReachable == false { return .error }
        if state.bridgeReachable == nil { return .offline }
        return pendingApprovals.isEmpty ? .online : .approvalRequired
    }

    func isSessionUnread(_ session: DSHSessionSummary) -> Bool {
        guard session.archived != true, session.updatedAt > 0 else { return false }
        let lastRead = lastReadSessionTimestamps[sessionReadKey(session.id)] ?? unreadBaseline
        return session.updatedAt > lastRead
    }

    func markSessionRead(_ sessionID: String) {
        let sessionTimestamp = sessions.first(where: { $0.id == sessionID })?.updatedAt ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let value = max(sessionTimestamp, now)
        let key = sessionReadKey(sessionID)
        guard lastReadSessionTimestamps[key] != value else { return }
        lastReadSessionTimestamps[key] = value
        UserDefaults.standard.set(lastReadSessionTimestamps, forKey: Self.lastReadSessionsKey)
    }

    func messages(for sessionID: String) -> [DSHChatMessage] {
        state.messagesBySession[sessionID, default: []]
    }

    func tools(for sessionID: String) -> [DSHToolActivity] {
        state.toolsBySession[sessionID, default: []]
    }

    /// The transcript in the order things actually happened: messages and tool
    /// calls interleaved by arrival sequence.
    func transcriptEntries(for sessionID: String) -> [DSHTranscriptEntry] {
        if let cached = transcriptEntriesCache[sessionID] { return cached }
        let entries = messages(for: sessionID)
            .filter { !hiddenMessageKeys.contains(messageKey(sessionID: sessionID, messageID: $0.id)) }
            .transcriptEntries(
            with: tools(for: sessionID),
            commandResults: commandResults(for: sessionID),
            modelChanges: modelChanges(for: sessionID)
        )
        transcriptEntriesCache[sessionID] = entries
        return entries
    }

    /// Render units: assistant turns with their tool calls folded in.
    func transcriptSections(for sessionID: String) -> [DSHTranscriptSection] {
        if let cached = transcriptSectionsCache[sessionID] { return cached }
        let sections = transcriptEntries(for: sessionID).groupedTurns()
        transcriptSectionsCache[sessionID] = sections
        return sections
    }

    /// Hides one message on this device. Per-message deletion is not currently
    /// exposed by the Connector/Harness protocol, so this intentionally does
    /// not pretend to mutate the Mac's source history.
    func hideMessage(_ messageID: String, in sessionID: String) {
        hiddenMessageKeys.insert(messageKey(sessionID: sessionID, messageID: messageID))
        invalidateTranscriptCaches(for: [sessionID])
        UserDefaults.standard.set(Array(hiddenMessageKeys), forKey: Self.hiddenMessagesKey)
    }

    private func invalidateTranscriptCaches(for sessionIDs: Set<String>) {
        for sessionID in sessionIDs {
            transcriptEntriesCache.removeValue(forKey: sessionID)
            transcriptSectionsCache.removeValue(forKey: sessionID)
        }
    }

    /// Transcript events normally carry their session in the envelope.  The
    /// history brackets also contain it in their payload because they can be
    /// delivered as control messages.  Keep that fallback so completing a
    /// replay can never leave a cached pre-replay transcript on screen.
    private func transcriptSessionIDs(affectedBy events: [DSHEvent]) -> Set<String> {
        var sessionIDs = Set(events.compactMap(\.envelope.sessionId))
        for event in events {
            switch event.kind {
            case .historyStarted(let batch), .historyCompleted(let batch):
                sessionIDs.insert(batch.sessionId)
            default:
                break
            }
        }
        return sessionIDs
    }

    private func messageKey(sessionID: String, messageID: String) -> String {
        "\(machineID)\u{001F}\(sessionID)\u{001F}\(messageID)"
    }

    func modelChanges(for sessionID: String) -> [DSHModelChangeNotice] {
        state.modelChangesBySession[sessionID, default: []]
    }


    func turnState(for sessionID: String) -> String {
        state.turnStateBySession[sessionID, default: "idle"]
    }

    func usage(for sessionID: String) -> DSHSessionUsage? {
        state.usageBySession[sessionID] ?? sessions.first(where: { $0.id == sessionID })?.usage
    }

    func permissionMode(for sessionID: String) -> String {
        state.permissionBySession[sessionID]?.mode
            ?? sessions.first(where: { $0.id == sessionID })?.permissionMode
            ?? "workspace-write"
    }

    func commandResults(for sessionID: String) -> [DSHCommandResult] {
        state.commandResultsBySession[sessionID, default: []]
    }

    func attachments(for sessionID: String) -> [DSHUploadedAttachment] {
        state.attachmentsBySession[sessionID, default: []]
    }

    /// Keeps the already-downsampled image available for the current run and
    /// on disk for a later session-history reload. Only the thumbnail bytes are
    /// cached; the original camera-library asset never leaves Photos.
    func cacheAttachmentData(_ data: Data, for receiptId: String) {
        attachmentDataCache.setObject(data as NSData, forKey: receiptId as NSString, cost: data.count)
        let url = attachmentCacheURL.appendingPathComponent(receiptId.dshAttachmentCacheFileName)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                          withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                Self.evictAttachmentCache(
                    directory: url.deletingLastPathComponent(),
                    keepingBytesUnder: Self.attachmentDiskBudgetBytes)
            } catch {
                // A cache miss only removes the thumbnail; the Harness file and
                // the message itself remain intact.
            }
        }
    }

    /// Deletes oldest-first until the thumbnail directory fits the budget.
    /// Internal (not private) so the eviction order is unit-tested.
    /// Nonisolated: it runs on a detached background task and only touches
    /// its parameters plus FileManager.
    nonisolated static func evictAttachmentCache(directory: URL, keepingBytesUnder budget: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = values.fileSize else { continue }
            total += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > budget else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= budget { break }
        }
    }

    func attachmentData(for attachment: DSHMessageAttachment) -> Data? {
        let key = attachment.receiptId ?? attachment.id
        if let cached = attachmentDataCache.object(forKey: key as NSString) { return cached as Data }
        let url = attachmentCacheURL.appendingPathComponent(key.dshAttachmentCacheFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        attachmentDataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    /// Drops a staged upload before the message goes out. The bytes are already
    /// on the Mac, but nothing was sent with them yet, so this only discards the
    /// reference — which is exactly what makes the chip safe to remove.
    func discardAttachment(_ id: String, for sessionID: String) {
        state.attachmentsBySession[sessionID]?.removeAll { $0.id == id }
    }

    func pair() {
        pair(serverAddress: serverAddress, machineID: machineID, pairingSecret: pairingSecret)
    }

    /// Pairs a profile from an isolated form draft.  The active machine id is
    /// deliberately not used as the form's storage, so cancelling an Add Mac
    /// sheet cannot desynchronise the live socket from the selected profile.
    func pair(serverAddress inputServerAddress: String,
              machineID inputMachineID: String,
              pairingSecret inputPairingSecret: String) {
        let trimmedMachineID = inputMachineID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = inputPairingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = inputServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !removedMachineFenceUnavailable else {
            errorMessage = "本机删除记录不可读，暂不能修改配对。"
            return
        }
        guard !trimmedMachineID.isEmpty else {
            errorMessage = DSHLocalization.string("Enter the machine ID shown by DSH Anywhere Connector.")
            return
        }
        // One field accepts either shape: an 8-character one-time code or the
        // longer pairing secret, distinguished by length.
        guard let credential = DSHPairingCredential.detect(trimmedSecret) else {
            errorMessage = DSHLocalization.string("Enter the pairing code or secret shown by DSH Anywhere Connector.")
            return
        }
        guard !address.isEmpty else {
            errorMessage = "Enter the HTTPS address for your DSH Anywhere gateway."
            return
        }
        guard !profiles.profiles.contains(where: { $0.machineId == trimmedMachineID }) else {
            errorMessage = "这台 Mac 已经配对，请在设置中切换或先移除旧配对。"
            return
        }
        isPairing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPairing = false }
            let previousProfile = self.activeMachine
            let previousMachineID = previousProfile?.machineId ?? ""
            let previousServerAddress = self.serverAddress
            let previousPairingSecret = self.pairingSecret
            let hadActivePair = self.isPaired && !previousMachineID.isEmpty
            if hadActivePair {
                await self.awaitPendingTransactionStoreLoaded()
                guard await self.persistCurrentTransactions(for: previousMachineID) else {
                    self.errorMessage = "无法安全保存当前 Mac 的待处理请求，暂不切换配对。"
                    return
                }
                self.eventTask?.cancel()
                self.eventTask = nil
                self.state.connectionState = .disconnected
                self.state.transportState = .disconnected
                await self.transport.disconnect()
            }
            do {
                let profile = try await self.transport.pair(
                    serverAddress: address, machineId: trimmedMachineID,
                    credential: credential, deviceName: "iPhone"
                )
                UserDefaults.standard.set(address, forKey: "dsh-anywhere.server-address")
                self.serverAddress = address
                self.pairingSecret = trimmedSecret
                self.machineName = profile.machineName
                self.machineID = profile.machineId
                // Pairing is an explicit new lifecycle. Clear only this
                // machine's removal fence; its old queue key was deleted at
                // removal and must not be resurrected by a re-pair.
                self.lastSessionCreationRequestIDsByMachine.removeValue(forKey: profile.machineId)
                self.sessionCreationTransactionsByMachine.removeValue(forKey: profile.machineId)
                self.remoteMutationTransactionsByMachine.removeValue(forKey: profile.machineId)
                self.initialMessageTransactionsByMachine.removeValue(forKey: profile.machineId)
                self.pendingPromptTransactionsByMachine.removeValue(forKey: profile.machineId)
                self.failedPromptTransactionsByMachine.removeValue(forKey: profile.machineId)
                UserDefaults.standard.removeObject(
                    forKey: self.queuedPromptsDefaultsKey(for: profile.machineId))
                self.resetTransientRequestState()
                // Keep the old fence while the large journal is rewritten;
                // this first write removes any stale per-machine records. A
                // later sidecar clear and final journal write complete the new
                // pairing lifecycle without exposing a crash window.
                guard await self.persistPendingTransactionStore() else {
                    await self.rollbackFailedPairing(
                        profile.machineId, restoring: previousProfile,
                        serverAddress: previousServerAddress, pairingSecret: previousPairingSecret)
                    return
                }
                self.removedMachineIDs.remove(profile.machineId)
                guard await self.persistRemovedMachineFence() else {
                    await self.rollbackFailedPairing(
                        profile.machineId, restoring: previousProfile,
                        serverAddress: previousServerAddress, pairingSecret: previousPairingSecret)
                    return
                }
                // Fence the Relay credential before the final journal write.
                // If the app is killed in the remaining crash window, the
                // transport can activate this locally committed marker on the
                // next launch instead of mistaking it for an abandoned pair.
                guard await self.transport.markPairingLocallyCommitted(machineId: profile.machineId) else {
                    await self.rollbackFailedPairing(
                        profile.machineId, restoring: previousProfile,
                        serverAddress: previousServerAddress, pairingSecret: previousPairingSecret)
                    return
                }
                guard await self.persistPendingTransactionStore() else {
                    await self.rollbackFailedPairing(
                        profile.machineId, restoring: previousProfile,
                        serverAddress: previousServerAddress, pairingSecret: previousPairingSecret)
                    return
                }
                await self.transport.commitPairing(machineId: profile.machineId)
                self.refreshMachines()
                self.isPaired = true
                self.pairingSuccessRevision &+= 1
                self.connect()
            } catch {
                // DSHRemoteTransport may have obtained a Relay credential
                // before a local token/journal write failed. Give it one more
                // chance to issue the compensating self-revoke even though no
                // profile was returned to this transaction.
                await self.transport.rollbackPairing(machineId: trimmedMachineID)
                // Pairing is additive. If the new Mac fails, restore the
                // previous active profile and reconnect it rather than leaving
                // the home screen detached from a healthy machine.
                if hadActivePair, let previousProfile {
                    self.machineID = previousProfile.machineId
                    self.machineName = previousProfile.machineName
                    self.isPaired = true
                    self.connect()
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshMachines() {
        machines = profiles.profiles
    }

    /// Transport recovery can revoke a provisional profile or promote the
    /// next stored Mac before returning its event stream. Keep the published
    /// AppModel identity in lockstep with that actor-owned profile store so a
    /// stream for machine B is never rendered or sent as machine A.
    @discardableResult
    private func synchronizeTransportProfiles(_ snapshot: DSHTransportProfileSnapshot) -> Bool {
        let previousMachineID = machineID
        machines = snapshot.profiles
        guard let active = snapshot.activeProfile,
              !removedMachineIDs.contains(active.machineId) else {
            if !previousMachineID.isEmpty {
                machineID = ""
                resetTransientRequestState()
            }
            machineName = ""
            isPaired = false
            state.connectionState = .disconnected
            state.transportState = .disconnected
            state.machineOnline = false
            state.bridgeReachable = nil
            return false
        }
        if previousMachineID != active.machineId {
            machineID = active.machineId
            machineName = active.machineName
            resetTransientRequestState()
            state = DSHStoreState()
            restoreSessionCreationTransactions(for: active.machineId)
        }
        machineID = active.machineId
        machineName = active.machineName
        isPaired = true
        return true
    }

    /// A transport persists credentials before returning from pair(). If the
    /// subsequent journal/fence commit fails, remove that provisional profile
    /// instead of leaving an active-but-fenced identity that would reconnect
    /// after relaunch with no durable recovery path.
    private func rollbackFailedPairing(_ machineID: String,
                                       restoring previousProfile: DSHRemoteProfile? = nil,
                                       serverAddress previousServerAddress: String? = nil,
                                       pairingSecret previousPairingSecret: String? = nil) async {
        await transport.rollbackPairing(machineId: machineID)
        removedMachineIDs.insert(machineID)
        _ = await persistRemovedMachineFence()
        refreshMachines()
        if let previousServerAddress {
            serverAddress = previousServerAddress
            UserDefaults.standard.set(previousServerAddress, forKey: "dsh-anywhere.server-address")
        }
        if let previousPairingSecret {
            pairingSecret = previousPairingSecret
        }
        if let previousProfile,
           profiles.profiles.contains(where: { $0.machineId == previousProfile.machineId }) {
            await transport.setActiveMachine(previousProfile.machineId)
            machineName = previousProfile.machineName
            self.machineID = previousProfile.machineId
            resetTransientRequestState()
            state = DSHStoreState()
            restoreSessionCreationTransactions(for: previousProfile.machineId)
            isPaired = true
            connect()
        } else if let active = profiles.activeProfile,
           !removedMachineIDs.contains(active.machineId) {
            machineName = active.machineName
            self.machineID = active.machineId
            resetTransientRequestState()
            state = DSHStoreState()
            restoreSessionCreationTransactions(for: active.machineId)
            isPaired = true
            connect()
        } else {
            machineName = ""
            self.machineID = ""
            isPaired = false
        }
    }

    /// Points the app at another paired Mac. The socket is torn down first
    /// because it carries the previous machine's identity.
    func switchMachine(_ machine: DSHRemoteProfile) {
        let isCurrentMachine = machine.machineId == activeMachine?.machineId
        // A second tap on the original machine is a cancellation when a
        // previous A -> B switch is still waiting for its socket teardown.
        // The old guard treated it as a no-op, leaving the UI detached from A
        // until the stale B task eventually committed.
        guard !isCurrentMachine || pendingMachineSelectionID != nil else { return }
        let previousMachineID = machineID
        machineSelectionGeneration &+= 1
        let selection = machineSelectionGeneration
        pendingMachineSelectionID = machine.machineId
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.suspendSessionCreationTransactions(for: previousMachineID) else {
                self.pendingMachineSelectionID = nil
                self.connect()
                return
            }
            await self.transport.setActiveMachine(machine.machineId)
            guard self.machineSelectionGeneration == selection else { return }
            self.pendingMachineSelectionID = nil
            self.machineName = machine.machineName
            self.machineID = machine.machineId
            // Restore only after the active identity changes. Restoring before
            // this point reads A's key and can later overwrite B's queue.
            self.resetTransientRequestState()
            self.state = DSHStoreState()
            self.restoreSessionCreationTransactions(for: machine.machineId)
            self.refreshMachines()
            self.connect()
        }
    }

    func removeMachine(_ machine: DSHRemoteProfile) {
        guard !removedMachineFenceUnavailable else {
            errorMessage = "本机删除记录不可读，暂不能移除配对。"
            return
        }
        let wasActive = machine.machineId == activeMachine?.machineId
        let isPendingSelection = machine.machineId == pendingMachineSelectionID
        let needsRecovery = wasActive || isPendingSelection
        if needsRecovery { machineSelectionGeneration &+= 1 }
        let recoveryGeneration = machineSelectionGeneration
        if isPendingSelection { pendingMachineSelectionID = nil }
        if wasActive {
            eventTask?.cancel()
            eventTask = nil
            eventFlushTask?.cancel()
            eventFlushTask = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Removal mutates the shared transaction journal even when the
            // target is not active.  Wait for startup loading before deleting
            // the in-memory entry, otherwise the loader can merge the old
            // target back and the following save resurrects its requests.
            await self.awaitPendingTransactionStoreLoaded()
            // A pending target is not the machine represented by the live
            // maps; snapshot only the active machine before deletion. The
            // target's already-durable records remain untouched until removal
            // succeeds.
            if wasActive, !(await self.persistCurrentTransactions(for: machine.machineId)) {
                self.connect()
                return
            }
            // Fence the lifecycle before deleting the remote profile. If the
            // app is killed after the remote deletion, the sidecar still
            // prevents the old journal/queue from being restored on relaunch.
            self.removedMachineIDs.insert(machine.machineId)
            guard await self.persistRemovedMachineFence() else {
                if needsRecovery, self.machineSelectionGeneration == recoveryGeneration {
                    self.restoreActiveMachineAfterRemoval()
                }
                return
            }
            do {
                try await self.transport.removeMachine(machine.machineId)
            } catch {
                self.removedMachineIDs.remove(machine.machineId)
                guard await self.persistRemovedMachineFence() else { return }
                self.errorMessage = error.localizedDescription
                self.refreshMachines()
                if needsRecovery, self.machineSelectionGeneration == recoveryGeneration {
                    self.restoreActiveMachineAfterRemoval()
                }
                self.isPaired = !self.machines.isEmpty
                return
            }
            self.sessionCreationTransactionsByMachine.removeValue(forKey: machine.machineId)
            self.remoteMutationTransactionsByMachine.removeValue(forKey: machine.machineId)
            self.lastSessionCreationRequestIDsByMachine.removeValue(forKey: machine.machineId)
            self.initialMessageTransactionsByMachine.removeValue(forKey: machine.machineId)
            self.pendingPromptTransactionsByMachine.removeValue(forKey: machine.machineId)
            self.failedPromptTransactionsByMachine.removeValue(forKey: machine.machineId)
            self.removedMachineIDs.insert(machine.machineId)
            UserDefaults.standard.removeObject(
                forKey: self.queuedPromptsDefaultsKey(for: machine.machineId))
            let cleanupResult = await self.persistPendingTransactionStoreResult()
            guard cleanupResult == .persisted else {
                if cleanupResult == .quotaExceeded {
                    self.errorMessage = "本机已从 Relay 删除，但本地待处理附件占用过多，清理尚未安全落盘。"
                } else {
                    self.errorMessage = "本机已从 Relay 删除，但本地清理尚未安全落盘；旧请求已被隔离。"
                }
                return
            }
            self.refreshMachines()
            guard needsRecovery else {
                self.isPaired = !self.machines.isEmpty
                return
            }
            // If the user made another selection while deletion was in flight,
            // its task owns recovery. Do not reconnect the old machine over it.
            guard self.machineSelectionGeneration == recoveryGeneration else {
                self.isPaired = !self.machines.isEmpty
                return
            }
            self.pendingMachineSelectionID = nil
            self.restoreActiveMachineAfterRemoval()
        }
    }

    /// Re-establishes the remaining active profile after an active machine or
    /// a just-selected target is removed. Both cases may already have detached
    /// the old socket, so merely refreshing the profile list is not enough.
    private func restoreActiveMachineAfterRemoval() {
        selectedSessionID = nil
        if let active = profiles.activeProfile {
            // ProfileStore selects the remaining profile while removing the
            // active one. Change identity before restoring the per-machine
            // queue so the old machine's state cannot be loaded into it.
            machineName = active.machineName
            machineID = active.machineId
            resetTransientRequestState()
            state = DSHStoreState()
            restoreSessionCreationTransactions(for: active.machineId)
            connect()
        } else {
            machineName = ""
            machineID = ""
            resetTransientRequestState()
            state = DSHStoreState()
        }
        isPaired = !machines.isEmpty
    }

    /// Loads the device list for the active machine from the Relay. The Relay
    /// refuses this on older builds, so a failure is reported in Settings rather
    /// than treated as a broken app.
    func refreshPairedDevices() {
        guard isPaired else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.pairedDevices = try await self.transport.pairedDevices()
                self.devicesError = nil
            } catch {
                self.pairedDevices = []
                self.devicesError = error.localizedDescription
            }
        }
    }

    func revokeDevice(_ device: DSHRelayDevice) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.transport.revokeDevice(device.deviceId)
                self.refreshPairedDevices()
            } catch {
                self.devicesError = error.localizedDescription
            }
        }
    }

    /// The device id of the phone holding this app, so Settings can label it and
    /// avoid offering a self-revoke the Relay would refuse anyway.
    var currentDeviceId: String? { profiles.activeProfile?.deviceId }

    func connect() {
        guard pendingTransactionStoreLoaded, isPaired, eventTask == nil,
              !removedMachineFenceUnavailable,
              !pendingTransactionPersistenceUnavailable,
              !machineID.isEmpty, !removedMachineIDs.contains(machineID) else { return }
        if suspendingTransactions {
            reconnectAfterSuspension = true
            return
        }
        if pendingSessionCreationRequestIDs.isEmpty {
            restoreSessionCreationTransactions(for: machineID)
        }
        let connectionGeneration = machineStateGeneration
        state.connectionState = .connecting
        state.transportState = .connecting
        state.machineOnline = false
        state.bridgeReachable = nil
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transport.setIncludeArchived(self.showArchivedSessions)
            let stream = await transport.connect()
            guard self.machineStateGeneration == connectionGeneration else { return }
            if let snapshot = await self.transport.profileSnapshot(),
               !self.synchronizeTransportProfiles(snapshot) {
                self.eventTask = nil
                return
            }
            let streamGeneration = self.machineStateGeneration
            do {
                for try await event in stream {
                    guard self.machineStateGeneration == streamGeneration else { return }
                    self.enqueue(event)
                }
            } catch {
                guard self.machineStateGeneration == streamGeneration else { return }
                self.flushPendingEvents()
                self.markPendingSessionCreationsUnknown(
                    detail: "连接已断开，创建结果待确认。")
                self.errorMessage = error.localizedDescription
                self.state.transportState = .failed(error.localizedDescription)
                self.state.machineOnline = false
                self.state.bridgeReachable = nil
                self.state.connectionState = .failed(error.localizedDescription)
            }
            guard self.machineStateGeneration == streamGeneration else { return }
            self.flushPendingEvents()
            if !Task.isCancelled {
                self.markPendingSessionCreationsUnknown(
                    detail: "连接已结束，创建结果待确认。")
            }
            self.eventTask = nil
        }
    }

    func disconnect() {
        guard !suspendingTransactions else { return }
        machineSelectionGeneration &+= 1
        pendingMachineSelectionID = nil
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        suspendingTransactions = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.suspendSessionCreationTransactions(for: self.machineID) else {
                self.suspendingTransactions = false
                self.connect()
                return
            }
            self.resetTransientRequestState()
            await self.transport.disconnect()
            self.state.transportState = .disconnected
            self.state.machineOnline = false
            self.state.bridgeReachable = nil
            self.state.connectionState = .disconnected
            let shouldReconnect = self.reconnectAfterSuspension
            self.reconnectAfterSuspension = false
            self.suspendingTransactions = false
            if shouldReconnect { self.connect() }
        }
    }

    func forgetPairing() {
        guard !removedMachineFenceUnavailable else {
            errorMessage = "本机删除记录不可读，暂不能解除配对。"
            return
        }
        machineSelectionGeneration &+= 1
        pendingMachineSelectionID = nil
        eventTask?.cancel()
        eventTask = nil
        eventFlushTask?.cancel()
        eventFlushTask = nil
        let forgottenMachineID = activeMachine?.machineId ?? machineID
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.suspendSessionCreationTransactions(for: forgottenMachineID) else {
                self.connect()
                return
            }
            self.removedMachineIDs.insert(forgottenMachineID)
            guard await self.persistRemovedMachineFence() else {
                self.removedMachineIDs.remove(forgottenMachineID)
                self.connect()
                return
            }
            self.resetTransientRequestState()
            do { try await self.transport.forgetPairing() }
            catch {
                self.removedMachineIDs.remove(forgottenMachineID)
                guard await self.persistRemovedMachineFence() else { return }
                self.errorMessage = error.localizedDescription
                self.refreshMachines()
                self.machineID = self.activeMachine?.machineId ?? forgottenMachineID
                self.machineName = self.activeMachine?.machineName ?? "My Mac"
                self.restoreSessionCreationTransactions(for: self.machineID)
                self.isPaired = !self.machines.isEmpty
                self.connect()
                return
            }
            self.sessionCreationTransactionsByMachine.removeValue(forKey: forgottenMachineID)
            self.remoteMutationTransactionsByMachine.removeValue(forKey: forgottenMachineID)
            self.lastSessionCreationRequestIDsByMachine.removeValue(forKey: forgottenMachineID)
            self.initialMessageTransactionsByMachine.removeValue(forKey: forgottenMachineID)
            self.pendingPromptTransactionsByMachine.removeValue(forKey: forgottenMachineID)
            self.failedPromptTransactionsByMachine.removeValue(forKey: forgottenMachineID)
            self.removedMachineIDs.insert(forgottenMachineID)
            UserDefaults.standard.removeObject(
                forKey: self.queuedPromptsDefaultsKey(for: forgottenMachineID))
            let cleanupResult = await self.persistPendingTransactionStoreResult()
            guard cleanupResult == .persisted else {
                if cleanupResult == .quotaExceeded {
                    self.errorMessage = "本机已解除配对，但本地待处理附件占用过多，清理尚未安全落盘。"
                } else {
                    self.errorMessage = "本机已解除配对，但本地清理尚未安全落盘；旧请求已被隔离。"
                }
                return
            }
            self.refreshMachines()
            self.state = .init()
            if let active = self.activeMachine {
                self.machineName = active.machineName
                self.machineID = active.machineId
                self.resetTransientRequestState()
                self.restoreSessionCreationTransactions(for: active.machineId)
                self.isPaired = true
                self.connect()
            } else {
                self.machineName = ""
                self.machineID = ""
                self.resetTransientRequestState()
                self.isPaired = false
            }
        }
    }

    /// The paired Mac owns the workspace registry. It includes empty projects,
    /// so deriving this from sessions would make a newly-created project vanish
    /// until its first task exists.
    var workspaces: [DSHWorkspaceOption] { state.workspaceCatalog }
    var modes: [DSHModeOption] { state.modeCatalog?.modes ?? [] }
    var defaultModeID: String? { state.modeCatalog?.defaultMode }
    var directoryListing: DSHDirectoryListing? { state.directoryListing }

    /// Starts a session, optionally inside a workspace.
    ///
    @discardableResult
    func createSession(in workspace: DSHWorkspaceOption? = nil,
                       title: String? = nil,
                       workingDirectory: String? = nil,
                       branch: String? = nil,
                       mode: String = "standard",
                       model: DSHModelSelection? = nil,
                       permissionMode: String = "workspace-write",
                       initialPrompt: String? = nil,
                       initialAttachments: [DSHStagedAttachment] = []) -> Bool {
        guard !removedMachineFenceUnavailable,
              !pendingTransactionPersistenceUnavailable,
              !removedMachineIDs.contains(machineID), !machineID.isEmpty else {
            errorMessage = "当前 Mac 配对事务尚未完成，请重新配对后再试。"
            return false
        }
        if let initialPrompt, !validatePromptText(initialPrompt) { return false }
        guard initialAttachments.count <= Self.maxPendingAttachmentCount else {
            errorMessage = "首条消息最多包含 16 个附件。"
            return false
        }
        guard initialAttachments.allSatisfy({ $0.data.count <= Self.maxAttachmentBytes }) else {
            errorMessage = "附件必须不超过 10 MiB，请移除过大的文件后重试。"
            return false
        }
        // A mode id is owned by the active Mac.  When its catalog is present,
        // reject stale values before they can cross the machine boundary.  A
        // nil catalog is kept compatible with older Connectors and previews;
        // the new-session UI still waits for a non-empty catalog before it
        // enables Create.
        if let modeCatalog = state.modeCatalog,
           !modeCatalog.modes.contains(where: { $0.id == mode }) {
            errorMessage = "所选模式不属于当前 Mac，请重新选择。"
            return false
        }
        let requestId = UUID().uuidString
        pendingSessionCreationRequestIDs.insert(requestId)
        var payload: [String: DSHJSONValue] = [:]
        if let title {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty { payload["title"] = .string(cleanTitle) }
        }
        // The bridge accepts workspaceId OR cwd, never both: the workspace
        // registry already resolves the directory, so sending both is a 400.
        if workspace == nil, let workingDirectory {
            let cleanPath = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPath.isEmpty { payload["workingDirectory"] = .string(cleanPath) }
        }
        if let workspace { payload["workspaceId"] = .string(workspace.id) }
        if !mode.isEmpty { payload["agentPreset"] = .string(mode) }
        if let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["branch"] = .string(branch.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let model {
            var modelValue: [String: DSHJSONValue] = [
                "provider": .string(model.provider),
                "model": .string(model.model)
            ]
            if let effort = model.reasoningEffort { modelValue["reasoningEffort"] = .string(effort) }
            payload["model"] = .object(modelValue)
        }
        payload["permissionMode"] = .string(permissionMode)
        // Keep every initial message out of `session.create`, including
        // text-only prompts.  The Connector used to send the creation
        // acknowledgement first and then submit this prompt with the same
        // request id; a prompt failure consequently discarded the only copy
        // of the user's text.  Sending it after `session.created` gives it a
        // normal, independently retryable prompt request id.
        let trimmedInitialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInitialPrompt.isEmpty || !initialAttachments.isEmpty {
            pendingInitialMessagesByRequestID[requestId] = DSHPendingInitialMessage(
                promptRequestID: UUID().uuidString,
                text: trimmedInitialPrompt,
                attachments: initialAttachments,
                sessionID: nil,
                dedupeExpiresAt: nil,
                attachmentRecoveryDeadline: initialAttachments.isEmpty
                    ? nil : Date().addingTimeInterval(Self.attachmentRecoveryWindow))
        }
        let command = DSHCommand(requestId: requestId, deviceId: deviceID, machineId: machineID,
                                  type: "session.create",
                                  payload: .object(payload))
        pendingSessionCreationCommandsByRequestID[requestId] = command
        lastSessionCreationRequestID = requestId
        sessionCreationRetryDeadlines[requestId] =
            Date().addingTimeInterval(sessionCreationRetryWindow)
        failedSessionCreations.removeValue(forKey: requestId)
        detachedSessionCreationRequestIDs.remove(requestId)
        let expectedMachineGeneration = machineStateGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.machineStateGeneration == expectedMachineGeneration,
                  self.machineID == machineID else {
                self.cancelSessionCreationTimeout(requestID: requestId)
                return
            }
            guard await self.persistCurrentTransactions(for: machineID) else {
                // Keep the request and staged draft addressable, but convert
                // the spinner into an explicit local failure.  The sheet can
                // now return the draft to editing instead of remaining
                // permanently non-dismissible after a journal error.
                self.cancelSessionCreationTimeout(requestID: requestId)
                self.failedSessionCreations[requestId] = DSHSessionCreationFailure(
                    id: requestId,
                    detail: "无法保存待处理请求，消息尚未发送。",
                    resultUnknown: false,
                    retryUntil: .now)
                self.errorMessage = "无法保存待处理请求，消息尚未发送。"
                return
            }
            guard self.machineStateGeneration == expectedMachineGeneration,
                  self.machineID == machineID else { return }
            // The remote acknowledgement clock starts only after the complete
            // create transaction (including any staged first-message blobs)
            // has been durably committed.  Slow local I/O must not turn a
            // request that has not left the phone into an "unknown" result.
            self.armSessionCreationTimeout(requestID: requestId)
            self.send(command)
        }
        return true
    }

    private func armSessionCreationTimeout(requestID: String) {
        let attempt = (sessionCreationAttemptGenerations[requestID] ?? 0) + 1
        sessionCreationAttemptGenerations[requestID] = attempt
        sessionCreationTimeoutTasks[requestID]?.cancel()
        sessionCreationTimeoutTasks[requestID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, self.sessionCreationAckTimeout)))
            } catch {
                return
            }
            guard self.sessionCreationAttemptGenerations[requestID] == attempt,
                  self.pendingSessionCreationRequestIDs.contains(requestID) else { return }
            self.markSessionCreationFailed(
                requestID,
                detail: "创建请求未收到 Mac 确认，结果待确认。",
                resultUnknown: true)
        }
    }

    private func cancelSessionCreationTimeout(requestID: String) {
        sessionCreationTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        sessionCreationAttemptGenerations[requestID, default: 0] &+= 1
    }

    private func markPendingSessionCreationsUnknown(detail: String) {
        for requestID in pendingSessionCreationRequestIDs {
            guard failedSessionCreations[requestID] == nil else { continue }
            markSessionCreationFailed(requestID, detail: detail, resultUnknown: true)
        }
    }

    func refreshSessions(includeArchived: Bool? = nil) {
        let include = includeArchived ?? showArchivedSessions
        send(DSHCommand.listSessions(deviceId: deviceID, machineId: machineID, includeArchived: include))
    }

    func requestWorkspaces() {
        send(DSHCommand.workspaceCatalog(deviceId: deviceID, machineId: machineID))
    }

    func requestModes() {
        send(DSHCommand.modeCatalog(deviceId: deviceID, machineId: machineID))
    }

    func listDirectory(at path: String? = nil) {
        let requestId = UUID().uuidString
        pendingDirectoryRequestID = requestId
        isLoadingDirectory = true
        send(DSHCommand.directoryList(deviceId: deviceID, machineId: machineID,
                                      path: path, requestId: requestId))
    }

    func createWorkspace(at path: String, title: String? = nil) {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty, !isCreatingWorkspace else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The protocol and Harness registry count JavaScript UTF-16 code
        // units. Reject an overlong title locally so the command spinner can
        // settle immediately instead of relying on a malformed relay error
        // after the request has already left the phone.
        if let cleanTitle, cleanTitle.utf16.count > 512 {
            errorMessage = "工作区名称不能超过 512 个字符。"
            return
        }
        let requestId = UUID().uuidString
        createdWorkspace = nil
        isCreatingWorkspace = true
        let proposed = DSHCommand.createWorkspace(deviceId: deviceID, machineId: machineID,
                                                   path: cleanPath,
                                                   title: cleanTitle?.isEmpty == false ? cleanTitle : nil,
                                                   requestId: requestId)
        guard let command = durableRemoteMutationCommand(proposed) else {
            isCreatingWorkspace = false
            return
        }
        pendingWorkspaceCreationRequestID = command.requestId
        send(command)
    }

    /// Loads the durable transcript for an existing session. Session snapshots
    /// intentionally contain metadata only; opening a conversation asks the
    /// Mac bridge to inspect that session and stream its normalized history.
    /// Replays less than two seconds apart are the same user gesture (appear
    /// plus pull-to-refresh): the second stream would only interleave a
    /// duplicate of the first, so it is skipped.
    func openSession(_ sessionID: String) {
        let now = Date()
        if let last = lastOpenSessionAt[sessionID], now.timeIntervalSince(last) < 2 { return }
        lastOpenSessionAt[sessionID] = now
        send(DSHCommand.openSession(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID, streaming: true))
    }

    func setConversationVisible(_ sessionID: String, visible: Bool) {
        if visible {
            visibleConversationSessionID = sessionID
        } else if visibleConversationSessionID == sessionID {
            visibleConversationSessionID = nil
            pendingReplayResynchronizationSessionIDs.remove(sessionID)
            pendingSessionOpenRecoveryIDs.remove(sessionID)
        }
    }

    func sendModelCatalog() {
        send(DSHCommand.modelCatalog(deviceId: deviceID, machineId: machineID))
    }

    func setShowArchived(_ value: Bool) {
        showArchivedSessions = value
        Task { await transport.setIncludeArchived(value) }
        refreshSessions(includeArchived: value)
    }

    var sessionGrouping: DSHSessionGrouping {
        groupsSessionsByWorkspace ? .byWorkspace : .flat
    }

    func setLanguage(_ value: DSHLanguage) {
        language = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.languageKey)
        // Plain strings built in helpers resolve immediately; SwiftUI text
        // follows the environment locale the root view sets from `language`.
        DSHLocalization.language = value
    }

    func setGroupsSessionsByWorkspace(_ value: Bool) {
        groupsSessionsByWorkspace = value
        UserDefaults.standard.set(value, forKey: Self.groupingKey)
    }

    func setShowUsageFooter(_ value: Bool) {
        showUsageFooter = value
        UserDefaults.standard.set(value, forKey: Self.usageFooterKey)
    }

    func setShowMessageActionsByDefault(_ value: Bool) {
        showMessageActionsByDefault = value
        UserDefaults.standard.set(value, forKey: Self.messageActionsKey)
    }

    func setCollapseComposerControls(_ value: Bool) {
        collapseComposerControls = value
        UserDefaults.standard.set(value, forKey: Self.composerCollapsedKey)
    }

    func isGroupCollapsed(_ id: String) -> Bool { collapsedSessionGroups.contains(id) }

    func setGroup(_ id: String, collapsed: Bool) {
        if collapsed { collapsedSessionGroups.insert(id) } else { collapsedSessionGroups.remove(id) }
        UserDefaults.standard.set(Array(collapsedSessionGroups), forKey: Self.collapsedGroupsKey)
    }

    func workspaceDisplayName(for id: String, fallback: String) -> String {
        workspaces.first(where: { $0.id == id })?.name ?? fallback
    }

    /// Mutations intentionally wait for the Connector's following catalog or
    /// snapshot. Local aliases and hidden-project sets used to make failed
    /// mutations look successful and could outlive the remote truth.
    func renameWorkspace(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(DSHCommand.renameWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: id, title: trimmed))
    }

    func deleteWorkspace(_ group: DSHSessionGroup) {
        guard !group.isUnfiled, group.id != DSHSessionGroup.flatGroupID else { return }
        send(DSHCommand.deleteWorkspace(deviceId: deviceID, machineId: machineID,
                                        workspaceId: group.id))
    }

    func renameSession(_ session: DSHSessionSummary, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(DSHCommand.renameSession(deviceId: deviceID, machineId: machineID,
                                      sessionId: session.id, title: trimmed))
    }

    func archive(_ session: DSHSessionSummary, archived: Bool = true) {
        send(DSHCommand.archiveSession(deviceId: deviceID, machineId: machineID,
                                       sessionId: session.id, archived: archived))
    }

    func sendPrompt(_ text: String, to sessionID: String) {
        sendPrompt(text, attachments: [], to: sessionID)
    }

    private struct DSHPreparedPrompt: Sendable {
        let requestID: String
        let attempt: Int
        let text: String
        var receipts: [String]
        let messageAttachments: [DSHMessageAttachment]
        let sessionID: String
        let mode: String
        let machineID: String
        let machineGeneration: Int
    }

    @discardableResult
    func sendPrompt(_ text: String, attachments: [String],
                    messageAttachments: [DSHMessageAttachment] = [], to sessionID: String,
                    mode: String = "queue", requestId requestedRequestID: String? = nil,
                    expectedMachineGeneration: Int? = nil,
                    expectedMachineID: String? = nil,
                    dedupeExpiresAt: Date? = nil) -> Bool {
        guard let prepared = preparePrompt(text, attachments: attachments,
                                           messageAttachments: messageAttachments, to: sessionID,
                                           mode: mode, requestId: requestedRequestID,
                                           expectedMachineGeneration: expectedMachineGeneration,
                                           expectedMachineID: expectedMachineID,
                                           dedupeExpiresAt: dedupeExpiresAt) else { return false }
        Task { @MainActor [weak self] in
            _ = await self?.persistAndSend(prepared)
        }
        return true
    }

    /// Persists a prompt transaction before the caller clears its editor. The
    /// normal fire-and-forget API above remains for existing event handlers and
    /// tests; UI paths that own the draft use this result-bearing variant so a
    /// storage failure leaves the text and attachment chips intact.
    @discardableResult
    func sendPromptPersisted(_ text: String, attachments: [String],
                             messageAttachments: [DSHMessageAttachment] = [], to sessionID: String,
                             mode: String = "queue", requestId requestedRequestID: String? = nil,
                             expectedMachineGeneration: Int? = nil,
                             expectedMachineID: String? = nil,
                             dedupeExpiresAt: Date? = nil) async -> Bool {
        guard let prepared = preparePrompt(text, attachments: attachments,
                                           messageAttachments: messageAttachments, to: sessionID,
                                           mode: mode, requestId: requestedRequestID,
                                           expectedMachineGeneration: expectedMachineGeneration,
                                           expectedMachineID: expectedMachineID,
                                           dedupeExpiresAt: dedupeExpiresAt) else { return false }
        return await persistAndSend(prepared)
    }

    /// Uploads a composer draft through a durable preparing transaction.  The
    /// staged bytes and every uploaded receipt are journaled before the first
    /// upload and after each subsequent upload, so a process kill cannot lose
    /// the only copy of the text while orphaning already-uploaded files.
    /// A retry with the same request id resumes the receipt map instead of
    /// uploading completed attachments again.
    @discardableResult
    func sendStagedPromptPersisted(_ text: String,
                                   attachments staged: [DSHStagedAttachment],
                                   to sessionID: String,
                                   mode: String = "queue",
                                   requestId requestedRequestID: String,
                                   expectedMachineGeneration: Int? = nil,
                                   expectedMachineID: String? = nil) async throws -> Bool {
        let generation = expectedMachineGeneration ?? machineStateGeneration
        guard generation == machineStateGeneration,
              expectedMachineID == nil || expectedMachineID == machineID else { return false }
        let expectedID = machineID
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !staged.isEmpty || pendingSendsByRequestID[requestedRequestID] != nil else {
            return false
        }
        guard staged.count <= Self.maxPendingAttachmentCount,
              staged.allSatisfy({ $0.data.count <= Self.maxAttachmentBytes }) else {
            errorMessage = "附件数量或大小超过限制。"
            return false
        }
        let requestID = requestedRequestID
        guard !cancelledStagedPromptIDs.contains(requestID) else { return false }
        guard stagedPromptUploadIDs.insert(requestID).inserted else {
            // A reconnect resume and a user retry can race for the same
            // durable transaction.  Let the first owner finish; a second
            // uploader must not create duplicate remote files.
            return false
        }
        defer { stagedPromptUploadIDs.remove(requestID) }
        var pending = pendingSendsByRequestID[requestID]
        if pending == nil {
            let attempt = (sendAttemptGenerations[requestID] ?? 0) + 1
            sendAttemptGenerations[requestID] = attempt
            pending = DSHPendingSend(
                id: requestID, text: trimmed, receipts: [], sessionID: sessionID,
                mode: mode, sentAt: .now, attempt: attempt,
                messageAttachments: [], phase: .preparing, stagedAttachments: staged,
                uploadedAttachments: [:],
                attachmentRecoveryDeadline: staged.isEmpty
                    ? nil : Date().addingTimeInterval(Self.attachmentRecoveryWindow))
            pendingSendsByRequestID[requestID] = pending
            guard await persistCurrentTransactions(for: machineID) else {
                pendingSendsByRequestID.removeValue(forKey: requestID)
                return false
            }
        } else if pending!.phase == .awaitingAck {
            // The prompt was already sent.  A reconnect must wait for its
            // targeted acknowledgement instead of issuing another send.
            return false
        } else if pending!.stagedAttachments.isEmpty && pending!.receipts.isEmpty {
            // A stale in-memory entry from an older retry may not contain the
            // staged payload.  Replace only before any side effect is known.
            pending!.stagedAttachments = staged
            pending!.sentAt = .now
            pending!.phase = .preparing
            if pending!.attachmentRecoveryDeadline == nil, !staged.isEmpty {
                pending!.attachmentRecoveryDeadline = Date().addingTimeInterval(Self.attachmentRecoveryWindow)
            }
            pendingSendsByRequestID[requestID] = pending
            guard await persistCurrentTransactions(for: machineID) else { return false }
        }

        guard var current = pendingSendsByRequestID[requestID] else { return false }
        guard current.sessionID == sessionID,
              current.phase == .preparing || current.phase == .readyToSend else { return false }
        let hasUnuploadedAttachment = current.stagedAttachments.contains {
            current.uploadedAttachments[$0.id.uuidString] == nil
        }
        if let deadline = current.attachmentRecoveryDeadline,
           Date() >= deadline,
           hasUnuploadedAttachment {
            pendingSendsByRequestID.removeValue(forKey: requestID)
            failedSendsByRequestID[requestID] = DSHFailedSend(
                id: requestID, text: current.text, receipts: current.receipts,
                sessionID: current.sessionID, mode: current.mode,
                messageAttachments: current.messageAttachments,
                failure: .local("附件恢复期限已过，请重新选择附件后发送。"),
                retryUntil: .now)
            _ = await persistCurrentTransactions(for: machineID)
            throw DSHAttachmentUploadError.recoveryExpired
        }
        if current.phase == .preparing && current.stagedAttachments.isEmpty && !staged.isEmpty && current.receipts.isEmpty {
            current.stagedAttachments = staged
            if current.attachmentRecoveryDeadline == nil {
                current.attachmentRecoveryDeadline = Date().addingTimeInterval(Self.attachmentRecoveryWindow)
            }
        }
        // A reconnect can invoke this method to resume an already-preparing
        // request; the stored staged array is authoritative in that case.
        for attachment in current.stagedAttachments {
            guard generation == machineStateGeneration, machineID == expectedID,
                  !cancelledStagedPromptIDs.contains(requestID),
                  pendingSendsByRequestID[requestID]?.phase == .preparing else {
                return false
            }
            let key = attachment.id.uuidString
            if current.uploadedAttachments[key] == nil {
                let uploadRequestID = "\(requestID)/attachment/\(key)"
                let receipt = try await uploadAttachmentAndWait(
                    name: attachment.name, data: attachment.data, for: sessionID,
                    machineGeneration: generation, requestID: uploadRequestID,
                    attachmentRecoveryDeadline: current.attachmentRecoveryDeadline)
                guard !cancelledStagedPromptIDs.contains(requestID),
                      pendingSendsByRequestID[requestID]?.phase == .preparing else {
                    return false
                }
                let mediaType = attachment.isImage ? "image/jpeg" : nil
                cacheAttachmentData(attachment.data, for: receipt)
                current.uploadedAttachments[key] = DSHMessageAttachment(
                    id: receipt, name: attachment.name, mediaType: mediaType, receiptId: receipt)
                current.receipts = current.stagedAttachments.compactMap {
                    current.uploadedAttachments[$0.id.uuidString]?.receiptId
                        ?? current.uploadedAttachments[$0.id.uuidString]?.id
                }
                current.messageAttachments = current.stagedAttachments.compactMap {
                    current.uploadedAttachments[$0.id.uuidString]
                }
                pendingSendsByRequestID[requestID] = current
                guard await persistCurrentTransactions(for: machineID) else { return false }
            }
        }
        guard !cancelledStagedPromptIDs.contains(requestID),
              pendingSendsByRequestID[requestID] != nil else { return false }
        current.stagedAttachments = []
        current.phase = .readyToSend
        current.sentAt = .now
        pendingSendsByRequestID[requestID] = current
        guard await persistCurrentTransactions(for: machineID) else { return false }
        guard !cancelledStagedPromptIDs.contains(requestID),
              pendingSendsByRequestID[requestID] != nil else { return false }
        current.phase = .awaitingAck
        current.sentAt = .now
        if current.dedupeExpiresAt == nil {
            current.dedupeExpiresAt = Date().addingTimeInterval(Self.promptIdempotencyWindow)
        }
        pendingSendsByRequestID[requestID] = current
        guard await persistCurrentTransactions(for: machineID) else { return false }
        armSendAckTimeout(requestId: requestID, attempt: current.attempt)
        let parts = current.receipts.map {
            DSHJSONValue.object(["type": .string("file"), "receiptId": .string($0)])
        }
        send(DSHCommand.sendPrompt(deviceId: deviceID, machineId: expectedID,
                                   sessionId: sessionID, text: current.text,
                                   attachments: parts, mode: current.mode, requestId: requestID))
        return true
    }

    /// Gives attachment-producing UI a durable preflight before it uploads
    /// bytes to the Mac. This does not create a prompt; it only verifies that
    /// the transaction journal is writable while the original draft remains
    /// in the editor.
    func preparePromptPersistence(expectedMachineGeneration: Int? = nil,
                                  expectedMachineID: String? = nil) async -> Bool {
        let generation = expectedMachineGeneration ?? machineStateGeneration
        guard !pendingTransactionPersistenceUnavailable,
              generation == machineStateGeneration,
              expectedMachineID == nil || expectedMachineID == machineID else { return false }
        return await persistCurrentTransactions(for: machineID)
    }

    private func preparePrompt(_ text: String, attachments: [String],
                               messageAttachments: [DSHMessageAttachment], to sessionID: String,
                               mode: String, requestId requestedRequestID: String?,
                               expectedMachineGeneration: Int?,
                               expectedMachineID: String?,
                               dedupeExpiresAt: Date? = nil) -> DSHPreparedPrompt? {
        if let expectedMachineGeneration,
           expectedMachineGeneration != machineStateGeneration { return nil }
        if let expectedMachineID, expectedMachineID != machineID { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
        if let dedupeExpiresAt, Date() >= dedupeExpiresAt {
            errorMessage = "原消息已超过安全重试窗口，请重新发送以避免重复执行。"
            return nil
        }
        guard attachments.count <= Self.maxPendingAttachmentCount else {
            errorMessage = "一条消息最多包含 16 个附件。"
            return nil
        }
        guard validatePromptText(trimmed) else { return nil }
        let requestId = requestedRequestID ?? UUID().uuidString
        if !messageAttachments.isEmpty {
            pendingMessageAttachmentsByRequestID[requestId] = messageAttachments
            pendingMessageAttachmentCleanupTasks[requestId]?.cancel()
            pendingMessageAttachmentCleanupTasks[requestId] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.clearPendingMessageAttachments(for: requestId)
            }
        }
        let attempt = (sendAttemptGenerations[requestId] ?? 0) + 1
        sendAttemptGenerations[requestId] = attempt
        pendingSendsByRequestID[requestId] = DSHPendingSend(
            id: requestId, text: trimmed, receipts: attachments,
            sessionID: sessionID, mode: mode, sentAt: .now,
            dedupeExpiresAt: dedupeExpiresAt, attempt: attempt,
            messageAttachments: messageAttachments)
        return DSHPreparedPrompt(requestID: requestId, attempt: attempt, text: trimmed,
                                 receipts: attachments, messageAttachments: messageAttachments,
                                 sessionID: sessionID, mode: mode, machineID: machineID,
                                 machineGeneration: machineStateGeneration)
    }

    private func persistAndSend(_ prepared: DSHPreparedPrompt) async -> Bool {
        guard machineStateGeneration == prepared.machineGeneration,
              machineID == prepared.machineID else { return false }
        guard var pending = pendingSendsByRequestID[prepared.requestID],
              pending.attempt == prepared.attempt else { return false }
        // The idempotency deadline starts at the first wire-facing attempt,
        // not when a local queue item was created. A retry carrying an
        // existing deadline must never extend the server tombstone.
        pending.phase = .awaitingAck
        pending.sentAt = .now
        if pending.dedupeExpiresAt == nil {
            pending.dedupeExpiresAt = Date().addingTimeInterval(Self.promptIdempotencyWindow)
        }
        pendingSendsByRequestID[prepared.requestID] = pending
        guard await persistCurrentTransactions(for: prepared.machineID) else {
            if pendingSendsByRequestID[prepared.requestID]?.attempt == prepared.attempt {
                pendingSendsByRequestID.removeValue(forKey: prepared.requestID)
                clearPendingMessageAttachments(for: prepared.requestID)
                failedSendsByRequestID[prepared.requestID] = DSHFailedSend(
                    id: prepared.requestID, text: prepared.text, receipts: prepared.receipts,
                    sessionID: prepared.sessionID, mode: prepared.mode,
                    messageAttachments: prepared.messageAttachments,
                    failure: .local("无法保存待处理请求，消息尚未发送。"),
                    // A retry may be failing locally, but its request id can
                    // have been accepted by an earlier attempt. Preserve the
                    // existing finite deadline instead of turning it into an
                    // indefinitely reusable local failure.
                    retryUntil: pending.dedupeExpiresAt)
            }
            errorMessage = "无法保存待处理请求，消息尚未发送。"
            return false
        }
        guard machineStateGeneration == prepared.machineGeneration,
              machineID == prepared.machineID else { return false }
        armSendAckTimeout(requestId: prepared.requestID, attempt: prepared.attempt)
        let parts = prepared.receipts.map {
            DSHJSONValue.object(["type": .string("file"), "receiptId": .string($0)])
        }
        send(DSHCommand.sendPrompt(deviceId: deviceID, machineId: prepared.machineID,
                                   sessionId: prepared.sessionID, text: prepared.text,
                                   attachments: parts, mode: prepared.mode,
                                   requestId: prepared.requestID))
        return true
    }

    /// An outbound prompt awaiting its accepted user message. If nothing
    /// comes back, the send failed somewhere between this phone and the Mac.
    struct DSHPendingSend: Sendable, Equatable, Identifiable, Codable {
        let id: String
        let text: String
        var receipts: [String]
        let sessionID: String
        let mode: String
        var sentAt: Date
        /// Fixed when this request first enters awaitingAck. Retries reuse
        /// the same deadline instead of extending remote idempotency.
        var dedupeExpiresAt: Date?
        let attempt: Int
        var messageAttachments: [DSHMessageAttachment]
        var phase: DSHPromptTransactionPhase
        /// Non-empty only while the composer is uploading attachments.  It is
        /// persisted so a process kill can resume from the uploaded receipt
        /// map instead of losing the draft after partial remote uploads.
        var stagedAttachments: [DSHStagedAttachment] = []
        var uploadedAttachments: [String: DSHMessageAttachment] = [:]
        /// Matches the Bridge's completed attachment retention window.
        var attachmentRecoveryDeadline: Date?

        private enum CodingKeys: String, CodingKey {
            case id, text, receipts, sessionID, mode, sentAt, attempt,
                 messageAttachments, phase, stagedAttachments, uploadedAttachments,
                 dedupeExpiresAt, attachmentRecoveryDeadline
        }

        init(id: String, text: String, receipts: [String], sessionID: String,
             mode: String, sentAt: Date, dedupeExpiresAt: Date? = nil, attempt: Int,
             messageAttachments: [DSHMessageAttachment],
             phase: DSHPromptTransactionPhase = .awaitingAck,
             stagedAttachments: [DSHStagedAttachment] = [],
             uploadedAttachments: [String: DSHMessageAttachment] = [:],
             attachmentRecoveryDeadline: Date? = nil) {
            self.id = id
            self.text = text
            self.receipts = receipts
            self.sessionID = sessionID
            self.mode = mode
            self.sentAt = sentAt
            self.dedupeExpiresAt = dedupeExpiresAt
            self.attempt = attempt
            self.messageAttachments = messageAttachments
            self.phase = phase
            self.stagedAttachments = stagedAttachments
            self.uploadedAttachments = uploadedAttachments
            self.attachmentRecoveryDeadline = attachmentRecoveryDeadline
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            text = try container.decode(String.self, forKey: .text)
            receipts = try container.decode([String].self, forKey: .receipts)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            mode = try container.decode(String.self, forKey: .mode)
            sentAt = try container.decode(Date.self, forKey: .sentAt)
            dedupeExpiresAt = try container.decodeIfPresent(Date.self, forKey: .dedupeExpiresAt)
            attempt = try container.decode(Int.self, forKey: .attempt)
            messageAttachments = try container.decode([DSHMessageAttachment].self, forKey: .messageAttachments)
            stagedAttachments = try container.decodeIfPresent([DSHStagedAttachment].self, forKey: .stagedAttachments) ?? []
            uploadedAttachments = try container.decodeIfPresent(
                [String: DSHMessageAttachment].self, forKey: .uploadedAttachments) ?? [:]
            attachmentRecoveryDeadline = container.contains(.attachmentRecoveryDeadline)
                ? try container.decodeIfPresent(Date.self, forKey: .attachmentRecoveryDeadline)
                : (stagedAttachments.isEmpty ? nil : sentAt.addingTimeInterval(dshAttachmentRecoveryWindow))
            if let storedPhase = try container.decodeIfPresent(DSHPromptTransactionPhase.self, forKey: .phase) {
                phase = storedPhase
            } else if !stagedAttachments.isEmpty {
                phase = .preparing
            } else if !uploadedAttachments.isEmpty {
                // Older builds persisted the ready-to-send window without a
                // phase marker.  Receipts prove uploads completed, but do not
                // prove that prompt.send reached the Connector.
                phase = .readyToSend
            } else {
                phase = .awaitingAck
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(receipts, forKey: .receipts)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(mode, forKey: .mode)
            try container.encode(sentAt, forKey: .sentAt)
            try container.encodeIfPresent(dedupeExpiresAt, forKey: .dedupeExpiresAt)
            try container.encode(attempt, forKey: .attempt)
            try container.encode(messageAttachments, forKey: .messageAttachments)
            try container.encode(phase, forKey: .phase)
            try container.encode(stagedAttachments, forKey: .stagedAttachments)
            try container.encode(uploadedAttachments, forKey: .uploadedAttachments)
            try container.encodeIfPresent(attachmentRecoveryDeadline, forKey: .attachmentRecoveryDeadline)
        }
    }

    enum DSHSendFailure: Sendable, Equatable, Codable {
        /// The transport rejected the send before this app attempted to put a
        /// frame on the wire; this path has no remote side effect to dedupe.
        case local(String)
        /// The frame may have left the phone but the Mac never acknowledged
        /// (or rejected it). Timeouts are intentionally classified here.
        case server(String)
    }

    struct DSHFailedSend: Sendable, Equatable, Identifiable, Codable {
        let id: String
        let text: String
        let receipts: [String]
        let sessionID: String
        let mode: String
        let messageAttachments: [DSHMessageAttachment]
        let failure: DSHSendFailure
        /// `nil` means the transport proved that the frame never left the
        /// phone.  Timeouts use the server's request-id retention window;
        /// after it expires the original request must not be re-executed.
        let retryUntil: Date?
    }

    private var pendingSendsByRequestID: [String: DSHPendingSend] = [:]
    private var stagedPromptResumeIDs: Set<String> = []
    private var stagedPromptUploadIDs: Set<String> = []
    /// Preparing uploads can be superseded while a reconnect task is still
    /// unwinding.  Keep a cancellation tombstone so that late upload results
    /// cannot resurrect a draft the user already edited or discarded.
    private var cancelledStagedPromptIDs: Set<String> = []
    /// Monotonic per-request attempt generations keep an old timeout task from
    /// settling a retried send that reuses the same idempotency key.
    private var sendAttemptGenerations: [String: Int] = [:]
    @Published private(set) var failedSendsByRequestID: [String: DSHFailedSend] = [:]
    /// Compatibility accessor for callers that only need one failure. Views
    /// showing a specific conversation must use `failedSend(for:)` so one
    /// failed request cannot hide another session's retry action.
    var failedSend: DSHFailedSend? { failedSendsByRequestID.values.first }
    /// Acceptance window before a send is declared lost. Internal for tests.
    var sendAckTimeout: TimeInterval = 15

    func pendingSendCount(for sessionID: String) -> Int {
        pendingSendsByRequestID.values.filter { $0.sessionID == sessionID }.count
    }

    /// Reuse a preparing transaction when the user retries the same composer
    /// draft after an attachment upload failed.  This keeps one request id for
    /// the draft, so a reconnect resume cannot later send a duplicate prompt.
    func stagedPromptRequestID(text: String, attachments: [DSHStagedAttachment],
                               sessionID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return pendingSendsByRequestID.values
            .filter { $0.sessionID == sessionID && $0.text == trimmed &&
                ($0.phase == .preparing || $0.phase == .readyToSend) &&
                (!$0.stagedAttachments.isEmpty || !$0.uploadedAttachments.isEmpty) &&
                $0.stagedAttachments == attachments }
            .max(by: { $0.sentAt < $1.sentAt })?.id
    }

    /// Removes only prompt transactions that have not reached `prompt.send`.
    /// A request already waiting for an acknowledgement may have reached the
    /// Mac and therefore remains protected by its original request id.
    @discardableResult
    func supersedePreparingPromptTransactions(for sessionID: String,
                                              keeping requestID: String? = nil) async -> Bool {
        let superseded = pendingSendsByRequestID.values.filter {
            $0.sessionID == sessionID &&
            ($0.phase == .preparing || $0.phase == .readyToSend) &&
            $0.id != requestID
        }
        guard !superseded.isEmpty else { return true }
        let removed = Dictionary(uniqueKeysWithValues: superseded.map { ($0.id, $0) })
        let supersededIDs = superseded.map(\.id)
        for id in supersededIDs {
            cancelledStagedPromptIDs.insert(id)
            pendingSendsByRequestID.removeValue(forKey: id)
        }
        // The replacement queue item must not be accepted until the old
        // preparing records are durably gone.  Otherwise a crash between the
        // asynchronous journal write and UserDefaults can resurrect the old
        // draft and send it alongside the replacement.
        guard await persistCurrentTransactions(for: machineID) else {
            pendingSendsByRequestID.merge(removed) { _, current in current }
            for id in supersededIDs { cancelledStagedPromptIDs.remove(id) }
            return false
        }
        return true
    }

    private func armSendAckTimeout(requestId: String, attempt: Int, delay: TimeInterval? = nil) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay ?? self?.sendAckTimeout ?? 15))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.timeoutPendingSend(requestId: requestId, attempt: attempt)
        }
    }

    func timeoutPendingSend(requestId: String) {
        timeoutPendingSend(requestId: requestId, attempt: nil)
    }

    private func timeoutPendingSend(requestId: String, attempt: Int?) {
        guard let pending = pendingSendsByRequestID[requestId] else { return }
        guard pending.phase == .awaitingAck else { return }
        if let attempt, pending.attempt != attempt { return }
        pendingSendsByRequestID.removeValue(forKey: requestId)
        let failure: DSHSendFailure
        if let detail = state.protocolErrorsByRequestID[requestId], !detail.isEmpty {
            failure = .server(detail)
        } else if connectionState != .connected {
            failure = .local("连接已断开")
        } else {
            failure = .server("Mac 未响应")
        }
        let retryUntil = pending.dedupeExpiresAt
            ?? pending.sentAt.addingTimeInterval(Self.promptIdempotencyWindow)
        failedSendsByRequestID[requestId] = DSHFailedSend(id: requestId, text: pending.text,
                                                          receipts: pending.receipts,
                                                          sessionID: pending.sessionID, mode: pending.mode,
                                                          messageAttachments: pending.messageAttachments,
                                                          failure: failure,
                                                          retryUntil: retryUntil)
        persistCurrentTransactionsLater(for: machineID)
    }

    /// A request id is authoritative.  A message with an id that does not match
    /// this phone's pending operation must not fall back to text matching: it
    /// may be a broadcast or historical message from another operation.
    func confirmPendingSend(text: String, sessionID: String, requestID: String? = nil) {
        if let requestID {
            pendingSendsByRequestID.removeValue(forKey: requestID)
            failedSendsByRequestID.removeValue(forKey: requestID)
            persistCurrentTransactionsLater(for: machineID)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let key = pendingSendsByRequestID.values.first(
            where: { $0.sessionID == sessionID && $0.text == trimmed })?.id {
            pendingSendsByRequestID.removeValue(forKey: key)
        }
        if let failure = failedSendsByRequestID.values.first(where: {
            $0.sessionID == sessionID && $0.text == trimmed
        }) { failedSendsByRequestID.removeValue(forKey: failure.id) }
        persistCurrentTransactionsLater(for: machineID)
    }

    private func clearPendingMessageAttachments(for requestID: String) {
        pendingMessageAttachmentsByRequestID.removeValue(forKey: requestID)
        pendingMessageAttachmentCleanupTasks.removeValue(forKey: requestID)?.cancel()
    }

    /// Park a transport failure instead of only flashing an alert. Errors from
    /// the WebSocket task itself are result-unknown: URLSession may report a
    /// failed completion after the frame already reached Relay, so they must
    /// retain the original request-id deadline just like an ACK timeout.
    /// Internal for tests.
    func parkFailedPromptSend(_ command: DSHCommand, error: Error,
                              attempt: Int? = nil, machineGeneration: Int? = nil) {
        if let machineGeneration, machineGeneration != self.machineStateGeneration { return }
        if let attempt, pendingSendsByRequestID[command.requestId]?.attempt != attempt { return }
        if attempt != nil && pendingSendsByRequestID[command.requestId] == nil { return }
        let inheritedFailed = failedSendsByRequestID[command.requestId]
        let pending = pendingSendsByRequestID.removeValue(forKey: command.requestId)
        var receipts: [String] = []
        var text = ""
        var sessionID = ""
        var mode = "queue"
        if case .object(let payload) = command.payload {
            if case .string(let value) = payload["text"] { text = value }
            if let sid = command.sessionId { sessionID = sid }
            if case .string(let value) = payload["mode"], !value.isEmpty { mode = value }
            for key in ["attachments", "content"] {
                if let value = payload[key] { receipts += receiptIds(in: value) }
            }
        }
        let messageAttachments = pending?.messageAttachments
            ?? pendingMessageAttachmentsByRequestID[command.requestId]
            ?? []
        clearPendingMessageAttachments(for: command.requestId)
        let resultUnknown = promptTransportResultUnknown(error)
        let deadlineExpired = (error as? DSHWebSocketError) == .dedupeWindowExpired
        let retryUntil = resultUnknown
            ? (pending?.dedupeExpiresAt
                ?? inheritedFailed?.retryUntil
                ?? pending?.sentAt.addingTimeInterval(Self.promptIdempotencyWindow)
                ?? Date().addingTimeInterval(Self.promptIdempotencyWindow))
            : (deadlineExpired
                ? pending?.dedupeExpiresAt ?? inheritedFailed?.retryUntil ?? .now
                : pending?.dedupeExpiresAt ?? inheritedFailed?.retryUntil)
        failedSendsByRequestID[command.requestId] = DSHFailedSend(
            id: command.requestId, text: text, receipts: receipts,
            sessionID: sessionID, mode: mode,
            messageAttachments: messageAttachments,
            failure: resultUnknown ? .server(error.localizedDescription) : .local(error.localizedDescription),
            retryUntil: retryUntil)
        persistCurrentTransactionsLater(for: machineID)
    }

    private func promptTransportResultUnknown(_ error: Error) -> Bool {
        guard let transportError = error as? DSHWebSocketError else { return true }
        switch transportError {
        case .dedupeWindowExpired, .notConnected, .machineMismatch, .messageTooLarge,
             .invalidMessage, .unsupportedProtocolVersion,
             .unauthorizedRelayRole, .authenticationRequired:
            return false
        case .closed, .eventBufferOverflow, .relay:
            return true
        }
    }

    private func receiptIds(in value: DSHJSONValue) -> [String] {
        switch value {
        case .object(let object):
            if case .string(let receipt) = object["receiptId"] { return [receipt] }
            return []
        case .array(let items):
            return items.flatMap { receiptIds(in: $0) }
        default:
            return []
        }
    }

    func failedSend(for sessionID: String) -> DSHFailedSend? {
        failedSendsByRequestID.values.first { $0.sessionID == sessionID }
    }

    func retryFailedSend(requestID: String) {
        guard let failed = failedSendsByRequestID[requestID] else { return }
        guard validatePromptText(failed.text) else { return }
        if let retryUntil = failed.retryUntil, Date() >= retryUntil {
            errorMessage = "原消息已超过安全重试窗口，请重新发送以避免重复执行。"
            return
        }
        // A timeout means the Mac may already have accepted the side effect.
        // Reuse the complete original command identity and mode so Connector
        // and Bridge idempotency coalesce the retry instead of executing it
        // a second time (a genuinely new submission still gets a new UUID).
        let accepted = sendPrompt(failed.text, attachments: failed.receipts,
                                  messageAttachments: failed.messageAttachments, to: failed.sessionID,
                                  mode: failed.mode, requestId: failed.id,
                                  dedupeExpiresAt: failed.retryUntil)
        if accepted {
            failedSendsByRequestID.removeValue(forKey: requestID)
            persistCurrentTransactionsLater(for: machineID)
        }
    }

    func retryFailedSend() {
        guard let failed = failedSend else { return }
        retryFailedSend(requestID: failed.id)
    }

    func dismissFailedSend(requestID: String) {
        failedSendsByRequestID.removeValue(forKey: requestID)
        // A dismissed failure is an explicit terminal user decision, not a
        // crash gap. Remove its queue mirror so reconnect recovery cannot
        // infer "pending and failed maps are empty" and submit the request
        // without another tap.
        for sessionID in Array(queuedPromptsBySession.keys) {
            guard var queue = queuedPromptsBySession[sessionID] else { continue }
            let filtered = queue.filter { $0.requestId != requestID }
            if filtered.count == queue.count { continue }
            queue = filtered
            queuedPromptsBySession[sessionID] = queue
        }
        persistQueuedPrompts()
        persistCurrentTransactionsLater(for: machineID)
    }

    func dismissFailedSend() {
        guard let failed = failedSend else { return }
        dismissFailedSend(requestID: failed.id)
    }

    /// A prompt this device queued while its session was busy. Text-only
    /// holds stay on the device (editable/cancellable, auto-sent when the
    /// turn settles); attachment sends go to the server queue immediately and
    /// are only mirrored here for the bubble. Entries retire when accepted.
    struct DSHQueuedPrompt: Sendable, Equatable, Identifiable, Codable {
        let id: String
        var text: String
        let mode: String
        let sentAt: Date
        /// Set when a stable request id is assigned for actual dispatch. It
        /// is separate from sentAt, which is the original local queue time.
        let dispatchAt: Date?
        /// Request identity for entries sent directly to the server queue.
        /// Older persisted entries have no identity and are never retired by
        /// an unrelated history event.
        let requestId: String?
        /// False = held locally (editable, cancellable, sendable). True =
        /// already sent to the server queue (bubble mirror only).
        let sent: Bool
        /// A stable request id has been reserved and mirrored locally, but the
        /// normal durable prompt transaction has not yet been committed. This
        /// state is known not to have reached Relay and can be recovered even
        /// after the ten-minute remote dedupe window.
        let dispatchPrepared: Bool

        private enum CodingKeys: String, CodingKey {
            case id, text, mode, sentAt, dispatchAt, requestId, sent, dispatchPrepared
        }

        init(id: String = UUID().uuidString, text: String, mode: String,
             sentAt: Date = .now, dispatchAt: Date? = nil,
             sent: Bool = false, requestId: String? = nil,
             dispatchPrepared: Bool = false) {
            self.id = id; self.text = text; self.mode = mode
            self.sentAt = sentAt; self.dispatchAt = dispatchAt
            self.sent = sent; self.requestId = requestId
            self.dispatchPrepared = dispatchPrepared
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            text = try container.decode(String.self, forKey: .text)
            mode = try container.decode(String.self, forKey: .mode)
            sentAt = try container.decode(Date.self, forKey: .sentAt)
            dispatchAt = try container.decodeIfPresent(Date.self, forKey: .dispatchAt)
            requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
            sent = try container.decode(Bool.self, forKey: .sent)
            // Older queue mirrors had only held/sent. Treat them as may-have-
            // sent records, never as known-unsent dispatch preparations.
            dispatchPrepared = try container.decodeIfPresent(Bool.self, forKey: .dispatchPrepared) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(mode, forKey: .mode)
            try container.encode(sentAt, forKey: .sentAt)
            try container.encodeIfPresent(dispatchAt, forKey: .dispatchAt)
            try container.encodeIfPresent(requestId, forKey: .requestId)
            try container.encode(sent, forKey: .sent)
            try container.encode(dispatchPrepared, forKey: .dispatchPrepared)
        }
    }

    private var queuedPromptsBySession: [String: [DSHQueuedPrompt]] = [:]
    private var queuedPromptSendIDs: Set<String> = []
    private static let queuedPromptTTL: TimeInterval = 24 * 60 * 60
    private static let queuedPromptsDefaultsKey = "dsh-anywhere.queued-prompts"

    private func queuedPromptsDefaultsKey(for machineID: String) -> String {
        "\(Self.queuedPromptsDefaultsKey).\(machineID)"
    }

    private var queuedPromptsDefaultsKey: String {
        queuedPromptsDefaultsKey(for: machineID)
    }

    /// Holds a text prompt locally until the turn settles (cancellable).
    func holdQueuedPrompt(text: String, for sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard validatePromptText(trimmed) else { return }
        queuedPromptsBySession[sessionID, default: []].append(
            DSHQueuedPrompt(text: trimmed, mode: "queue"))
        persistQueuedPrompts()
    }

    /// Mirrors an attachment send that went straight to the server queue.
    func noteQueuedPrompt(text: String, mode: String, requestId: String, for sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard validatePromptText(trimmed) else { return }
        queuedPromptsBySession[sessionID, default: []].append(
            DSHQueuedPrompt(text: trimmed, mode: mode, dispatchAt: .now,
                            sent: true, requestId: requestId))
        persistQueuedPrompts()
    }

    func queuedPrompts(for sessionID: String) -> [DSHQueuedPrompt] {
        let cutoff = Date.now.addingTimeInterval(-Self.queuedPromptTTL)
        let fresh = queuedPromptsBySession[sessionID, default: []].filter {
            ($0.sent || $0.dispatchPrepared ? ($0.dispatchAt ?? $0.sentAt) : $0.sentAt) > cutoff
        }
        if fresh.count != queuedPromptsBySession[sessionID]?.count {
            queuedPromptsBySession[sessionID] = fresh
            persistQueuedPrompts()
        }
        return fresh
    }

    func updateQueuedPrompt(id: String, text: String, sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent && !$0.dispatchPrepared }) else { return }
        guard validatePromptText(trimmed) else { return }
        queue[index].text = trimmed
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
    }

    /// Drops a locally held prompt before it ever fires. Server-sent entries
    /// cannot be retracted (no queue API) and are refused here.
    @discardableResult
    func cancelQueuedPrompt(id: String, sessionID: String) -> Bool {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent && !$0.dispatchPrepared }) else { return false }
        queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        return true
    }

    /// Pops the oldest locally held prompt for immediate sending.
    func takeQueuedPrompt(id: String, sessionID: String) -> DSHQueuedPrompt? {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent && !$0.dispatchPrepared }) else { return nil }
        let item = queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        return item
    }

    /// Sends a locally held queue item only after its normal prompt
    /// transaction is durable. A failed journal write leaves the item in the
    /// local queue instead of making the editor and queue both lose it.
    func sendQueuedPrompt(id: String, sessionID: String) {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.id == id && !$0.sent }),
              queuedPromptSendIDs.insert(id).inserted else { return }
        let item = queue[index]
        // Assign the request identity before creating the durable prompt
        // transaction.  The queue mirror and pending-transactions journal can
        // then be reconciled by the same id after a process kill; leaving Q as
        // an anonymous `sent=false` item allowed a second request id later.
        let requestID = item.requestId ?? UUID().uuidString
        let dispatchAt = item.dispatchAt ?? .now
        // A dispatch preparation is known not to have reached Relay. If its
        // task is killed before the durable prompt journal is committed, it
        // may safely start a fresh ten-minute window on recovery. Once the
        // queue mirror is already marked sent, retain the original deadline.
        let dedupeDeadline = item.dispatchPrepared
            ? nil : dispatchAt.addingTimeInterval(Self.promptIdempotencyWindow)
        queue[index] = DSHQueuedPrompt(id: item.id, text: item.text, mode: item.mode,
                                       sentAt: item.sentAt, dispatchAt: dispatchAt,
                                       sent: false, requestId: requestID,
                                       dispatchPrepared: true)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
        let generation = machineStateGeneration
        let activeMachineID = machineID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.queuedPromptSendIDs.remove(id) }
            let sent = await self.sendPromptPersisted(
                item.text, attachments: [], to: sessionID, mode: item.mode,
                requestId: requestID, expectedMachineGeneration: generation,
                expectedMachineID: activeMachineID,
                dedupeExpiresAt: dedupeDeadline)
            if sent,
               var currentQueue = self.queuedPromptsBySession[sessionID],
               let currentIndex = currentQueue.firstIndex(where: {
                   $0.id == id && $0.requestId == requestID
               }) {
                currentQueue[currentIndex] = DSHQueuedPrompt(
                    id: id, text: currentQueue[currentIndex].text,
                    mode: currentQueue[currentIndex].mode,
                    sentAt: currentQueue[currentIndex].sentAt,
                    dispatchAt: currentQueue[currentIndex].dispatchAt,
                    sent: true, requestId: requestID)
                self.queuedPromptsBySession[sessionID] = currentQueue
                self.persistQueuedPrompts()
            }
            // Keep the sent queue mirror until prompt.accepted retires it.  A
            // failed/unknown send can therefore be retried with this same id
            // instead of generating a second side effect.
        }
    }

    /// Fires the oldest held prompt when a turn settles. Returns false when
    /// there is nothing to fire (or the session is gone).
    @discardableResult
    private func flushQueuedPrompt(for sessionID: String) -> Bool {
        guard let queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { !$0.sent && !$0.dispatchPrepared }) else { return false }
        guard validatePromptText(queue[index].text) else { return false }
        let item = queue[index]
        sendQueuedPrompt(id: item.id, sessionID: sessionID)
        return true
    }

    private func persistQueuedPrompts() {
        guard let data = try? JSONEncoder().encode(queuedPromptsBySession) else { return }
        UserDefaults.standard.set(data, forKey: queuedPromptsDefaultsKey)
    }

    func restoreQueuedPrompts() {
        guard !removedMachineIDs.contains(machineID) else {
            queuedPromptsBySession.removeAll(keepingCapacity: false)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: queuedPromptsDefaultsKey),
              let restored = try? JSONDecoder().decode([String: [DSHQueuedPrompt]].self, from: data)
        else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.queuedPromptTTL)
        queuedPromptsBySession = restored.mapValues { items in
            items.filter { ($0.sent || $0.dispatchPrepared ? ($0.dispatchAt ?? $0.sentAt) : $0.sentAt) > cutoff }
        }
    }

    /// Retires the oldest queued entry whose text matches an accepted user
    /// message (the queued prompt surfacing for its turn).
    func matchQueuedPrompt(text: String, sessionID: String, requestID: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var queue = queuedPromptsBySession[sessionID],
              // Only entries that were already submitted to the server can be
              // retired, and a modern entry must match its request identity.
              // Legacy entries without an identity are intentionally retained
              // rather than guessed away by a history or other-device event.
              let index = queue.firstIndex(where: {
                  $0.sent && $0.requestId != nil && $0.requestId == requestID && $0.text == trimmed
              }) else { return }
        queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
    }

    /// A queued prompt surfacing for its turn arrives as an accepted user
    /// message: retire the matching bubble entry.
    private func retireQueuedPrompt(_ event: DSHEvent) {
        guard case .userMessageAccepted(let message) = event.kind,
              let sessionId = event.envelope.sessionId else { return }
        matchQueuedPrompt(text: message.markdown, sessionID: sessionId,
                          requestID: event.envelope.messageId)
    }

    private func retireQueuedPrompt(requestID: String, sessionID: String) {
        guard var queue = queuedPromptsBySession[sessionID],
              let index = queue.firstIndex(where: { $0.sent && $0.requestId == requestID }) else { return }
        queue.remove(at: index)
        queuedPromptsBySession[sessionID] = queue
        persistQueuedPrompts()
    }

    /// A prompt acceptance is a request-scoped receipt, not a transcript row.
    /// Durable user messages are broadcast/history data and intentionally do
    /// not settle pending sends by matching their text.
    private func confirmPromptAccepted(_ event: DSHEvent) {
        guard case .promptAccepted(let receipt) = event.kind else { return }
        confirmPendingSend(text: "", sessionID: receipt.sessionId, requestID: receipt.requestId)
        if let key = pendingInitialMessagesByRequestID.first(where: {
            $0.value.promptRequestID == receipt.requestId && $0.value.sessionID == receipt.sessionId
        })?.key {
            pendingInitialMessagesByRequestID.removeValue(forKey: key)
            failedInitialMessages.removeValue(forKey: key)
            removeStoredInitialMessageTransaction(key, for: machineID)
        }
        retireQueuedPrompt(requestID: receipt.requestId, sessionID: receipt.sessionId)
    }

    /// When a turn settles, fire the oldest locally held prompt (FIFO — the
    /// rest follow as their turns end). Only locally held prompts; the turn
    /// that just ended already consumed the wire.
    private func flushQueueOnSettle(_ event: DSHEvent) {
        guard case .turnStateChanged(let turn) = event.kind else { return }
        switch turn.state.lowercased() {
        case "completed", "failed", "cancelled":
            flushQueuedPrompt(for: turn.sessionId)
        default:
            break
        }
    }

    func selectModel(_ selection: DSHModelSelection, for sessionID: String) {
        send(DSHCommand.selectModel(deviceId: deviceID, machineId: machineID,
                                    sessionId: sessionID, provider: selection.provider,
                                    model: selection.model, reasoningEffort: selection.reasoningEffort))
    }

    /// Resolves the session's model against the server-provided catalog. If a
    /// model has no reasoning choices, nil keeps the control out of the UI.
    func reasoningConfiguration(for sessionID: String) -> DSHReasoningConfiguration? {
        guard let catalog = modelCatalog else { return nil }
        let session = sessions.first { $0.id == sessionID }
        let rawModel = session?.model ?? catalog.default.model
        let preferredProvider = session?.provider ?? catalog.default.provider

        let preferredGroup = catalog.groups.first { $0.id == preferredProvider }
        let preferredMatch = preferredGroup.flatMap { group in
            group.models.first(where: { modelMatches($0, rawValue: rawModel) }).map { (group, $0) }
        }
        let match = preferredMatch ?? catalog.groups.lazy.compactMap { group in
            group.models.first(where: { self.modelMatches($0, rawValue: rawModel) }).map { (group, $0) }
        }.first

        guard let (group, item) = match,
              let reasoning = item.reasoning,
              !reasoning.efforts.isEmpty else { return nil }

        let selected = session?.reasoningEffort
            ?? reasoning.defaultEffort
            ?? (rawModel == catalog.default.model ? catalog.default.reasoningEffort : nil)
            ?? reasoning.efforts[0].id
        return DSHReasoningConfiguration(provider: group.id, model: item.id,
                                         efforts: reasoning.efforts,
                                         selectedEffortID: selected)
    }

    private func modelMatches(_ item: DSHModelCatalogModel, rawValue: String) -> Bool {
        rawValue == item.id || rawValue == item.name || rawValue.hasSuffix("/\(item.id)")
    }

    func setPermission(_ mode: String, for sessionID: String) {
        send(DSHCommand.setPermission(deviceId: deviceID, machineId: machineID,
                                      sessionId: sessionID, mode: mode))
    }

    func executeCommand(_ line: String, for sessionID: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let proposed = DSHCommand.executeCommand(deviceId: deviceID, machineId: machineID,
                                                  sessionId: sessionID, line: trimmed)
        guard let command = durableRemoteMutationCommand(proposed) else { return }
        send(command)
    }

    func uploadAttachment(name: String, data: Data, for sessionID: String) {
        send(DSHCommand.uploadAttachment(deviceId: deviceID, machineId: machineID,
                                         sessionId: sessionID, name: name, data: data))
    }

    /// Uploads one staged attachment and waits until the Connector has
    /// returned its receipt. The receipt is the only safe value to put into a
    /// subsequent prompt, so the composer can now defer all network work until
    /// the user taps Send.
    func uploadAttachmentAndWait(name: String, data: Data, for sessionID: String,
                                 machineGeneration: Int? = nil,
                                 requestID requestedRequestID: String? = nil,
                                 attachmentRecoveryDeadline: Date? = nil) async throws -> String {
        guard !removedMachineFenceUnavailable,
              !pendingTransactionPersistenceUnavailable,
              !machineID.isEmpty, !removedMachineIDs.contains(machineID) else {
            throw DSHWebSocketError.machineMismatch
        }
        guard data.count <= Self.maxAttachmentBytes else { throw DSHAttachmentUploadError.tooLarge }
        if let machineGeneration, machineGeneration != self.machineStateGeneration {
            throw CancellationError()
        }
        let requestId = requestedRequestID ?? UUID().uuidString
        // A retry reuses the idempotency key. Discard the previous terminal
        // error before waiting for the new response; otherwise the old
        // protocol error would make a legitimate retry fail immediately.
        state.protocolErrorsByRequestID.removeValue(forKey: requestId)
        uploadWaitRequestIDs.insert(requestId)
        defer { uploadWaitRequestIDs.remove(requestId) }
        let command = DSHCommand.uploadAttachment(deviceId: deviceID, machineId: machineID,
                                                   sessionId: sessionID, name: name, data: data,
                                                   requestId: requestId)
        // The recovery deadline must reach the actual WebSocket send. A
        // reconnect inside transport.send may otherwise replay this stable
        // request id after the Bridge's tombstone window has expired.
        if let deadline = attachmentRecoveryDeadline, Date() >= deadline {
            throw DSHAttachmentUploadError.recoveryExpired
        }
        try await transport.send(command, notAfter: attachmentRecoveryDeadline)
        // A large camera image may need to cross the phone, Relay, Connector,
        // and the local Harness before the receipt comes back. The old 10
        // second window expired while the Connector was still within its
        // legitimate upload deadline, leaving the user with a false timeout.
        for _ in 0..<3_000 {
            try Task.checkCancellation()
            if let machineGeneration, machineGeneration != self.machineStateGeneration {
                throw CancellationError()
            }
            if let message = state.protocolErrorsByRequestID[requestId] {
                throw DSHRemoteCommandError(message: message)
            }
            if let uploaded = state.attachmentsBySession[sessionID]?.first(where: { $0.requestId == requestId }) {
                return uploaded.receiptId
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DSHAttachmentUploadError.timedOut
    }

    /// Just the model, without its provider prefix: rows and the composer both
    /// ran out of width showing "provider/model" when only the model differs.
    func shortModelName(for sessionID: String) -> String {
        let full = modelDisplayName(for: sessionID)
        let provider = sessions.first(where: { $0.id == sessionID })?.provider
            ?? modelCatalog?.default.provider
            ?? ""
        let model = full.split(separator: "/").last.map(String.init) ?? full
        let lowered = "\(provider)/\(full)".lowercased()
        if lowered.contains("deepseek") {
            if lowered.contains("v4.1") && lowered.contains("flash") { return "DS V4.1F" }
            if lowered.contains("v4.1") && (lowered.contains("reason") || lowered.contains("r1")) { return "DS V4.1R" }
            if lowered.contains("v4.1") { return "DS V4.1" }
            if lowered.contains("v3") { return "DS V3" }
        }
        if lowered.contains("claude") {
            if lowered.contains("opus") { return "Claude Opus" }
            if lowered.contains("sonnet") { return "Claude Sonnet" }
            if lowered.contains("haiku") { return "Claude Haiku" }
        }
        if lowered.contains("gpt-5") { return "GPT-5" }
        if lowered.contains("gpt-4") { return "GPT-4" }
        if lowered.contains("gemini") { return "Gemini" }
        return model
    }

    func modelDisplayName(for sessionID: String) -> String {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return modelCatalog?.default.model ?? "Select model"
        }
        if let model = session.model { return model }
        return modelCatalog?.default.model ?? "Select model"
    }

    /// Human-friendly abbreviations keep the compact composer readable while
    /// the model picker continues to show each provider's full name.
    func modelLabel(for selection: DSHModelSelection, compact: Bool = true) -> String {
        guard compact else { return "\(selection.provider)/\(selection.model)" }
        let raw = selection.model
        let lowered = "\(selection.provider)/\(raw)".lowercased()
        if lowered.contains("deepseek") {
            if lowered.contains("v4.1") && lowered.contains("flash") { return "DS V4.1F" }
            if lowered.contains("v4.1") && lowered.contains("reason") { return "DS V4.1R" }
            if lowered.contains("v4.1") { return "DS V4.1" }
            if lowered.contains("v3") { return "DS V3" }
            return "DeepSeek"
        }
        if lowered.contains("claude") {
            if lowered.contains("opus") { return "Claude Opus" }
            if lowered.contains("sonnet") { return "Claude Sonnet" }
            if lowered.contains("haiku") { return "Claude Haiku" }
        }
        if lowered.contains("gpt-4") { return "GPT-4" }
        if lowered.contains("gpt-5") { return "GPT-5" }
        if lowered.contains("gemini") { return "Gemini" }
        return raw
    }

    func modeLabel(for sessionID: String) -> String {
        guard let value = sessions.first(where: { $0.id == sessionID })?.mode
            ?? sessions.first(where: { $0.id == sessionID })?.agentPreset else {
            return modes.first(where: { $0.id == defaultModeID })?.name ?? "标准模式"
        }
        if let remoteName = modes.first(where: { $0.id == value })?.name { return remoteName }
        switch value.lowercased() {
        case "ptc", "plan-to-code", "plan_to_code": return "PTC 模式"
        case "custom", "self", "自建", "自建模式": return "自建模式"
        case "standard": return "标准模式"
        default: return value
        }
    }

    func cancelTurn(for sessionID: String) {
        send(DSHCommand.cancelTurn(deviceId: deviceID, machineId: machineID, sessionId: sessionID))
    }

    func decide(_ approval: DSHApprovalRequest, allow: Bool) {
        send(DSHCommand.decideApproval(deviceId: deviceID, machineId: machineID,
                                       sessionId: approval.sessionId, approvalId: approval.id, allow: allow))
    }

    func answer(_ request: DSHQuestionRequest, answers: [DSHQuestionAnswer]) {
        guard !answers.isEmpty else { return }
        send(DSHCommand.answerQuestion(deviceId: deviceID, machineId: machineID,
                                       sessionId: request.sessionId, questionId: request.id,
                                       answers: answers))
    }

    private func isDurableRemoteMutation(_ command: DSHCommand) -> Bool {
        command.type == "command.execute" || command.type == "workspace.create"
    }

    /// Returns an existing command when the same native mutation is retried.
    /// Matching the payload as well as the type prevents an unrelated command
    /// from inheriting an old request id. An expired tombstone is not safe to
    /// replay, so leave it parked and require the user to resolve it instead
    /// of silently minting a duplicate request.
    private func durableRemoteMutationCommand(_ proposed: DSHCommand) -> DSHCommand? {
        guard isDurableRemoteMutation(proposed) else { return proposed }
        guard !machineID.isEmpty else {
            errorMessage = "当前没有可用的 Mac。"
            return nil
        }
        if let existing = remoteMutationTransactionsByMachine[machineID]?.values.first(where: {
            $0.command.type == proposed.type &&
            $0.command.machineId == proposed.machineId &&
            $0.command.sessionId == proposed.sessionId &&
            $0.command.payload == proposed.payload
        }) {
            if Date() < existing.retryDeadline {
                return existing.command
            }

            if existing.failure != Self.expiredRemoteMutationConfirmation {
                var updated = existing
                updated.failure = Self.expiredRemoteMutationConfirmation
                remoteMutationTransactionsByMachine[machineID]?[existing.command.requestId] = updated
                persistCurrentTransactionsLater(for: machineID)
                errorMessage = "上一次操作结果未确认，已过期；再次执行将创建新的请求。"
                return nil
            }

            // The user explicitly confirmed the warning by tapping the same
            // mutation again. Remove the old tombstone before the new command
            // is persisted/sent so the replacement cannot race a later flush.
            remoteMutationTransactionsByMachine[machineID]?.removeValue(
                forKey: existing.command.requestId)
            if remoteMutationTransactionsByMachine[machineID]?.isEmpty == true {
                remoteMutationTransactionsByMachine.removeValue(forKey: machineID)
            }
        }
        remoteMutationTransactionsByMachine[machineID, default: [:]][proposed.requestId] =
            DSHRemoteMutationTransaction(
                command: proposed,
                failure: nil,
                retryDeadline: Date().addingTimeInterval(Self.promptIdempotencyWindow))
        return proposed
    }

    private func completeRemoteMutation(_ requestID: String, for machineID: String? = nil) {
        let targetMachineID = machineID ?? self.machineID
        guard var transactions = remoteMutationTransactionsByMachine[targetMachineID],
              transactions.removeValue(forKey: requestID) != nil else { return }
        if transactions.isEmpty {
            remoteMutationTransactionsByMachine.removeValue(forKey: targetMachineID)
        } else {
            remoteMutationTransactionsByMachine[targetMachineID] = transactions
        }
        if targetMachineID == self.machineID {
            persistCurrentTransactionsLater(for: targetMachineID)
        } else {
            persistPendingTransactionStoreLater()
        }
    }

    /// Persist the historical send boundary before invoking the transport.
    /// The returned value describes the state *before this attempt*; it lets a
    /// local `.notConnected` rejection release only a never-before-sent
    /// request while preserving a request whose earlier attempt was already
    /// result-unknown.
    private func beginRemoteMutationAttempt(_ requestID: String, for machineID: String) async -> Bool? {
        guard var transactions = remoteMutationTransactionsByMachine[machineID],
              var transaction = transactions[requestID] else { return nil }
        let hadPriorMayHaveBeenSent = transaction.deliveryState == .mayHaveBeenSent
        transaction.deliveryState = .mayHaveBeenSent
        transactions[requestID] = transaction
        remoteMutationTransactionsByMachine[machineID] = transactions
        guard await persistCurrentTransactions(for: machineID) else {
            if hadPriorMayHaveBeenSent {
                remoteMutationTransactionsByMachine[machineID]?[requestID] = transaction
            } else {
                remoteMutationTransactionsByMachine[machineID]?[requestID]?.deliveryState = .neverSent
            }
            return nil
        }
        return hadPriorMayHaveBeenSent
    }

    private func remoteMutationDefinitelyNotSent(_ error: Error) -> Bool {
        guard let websocketError = error as? DSHWebSocketError else { return false }
        switch websocketError {
        case .dedupeWindowExpired, .invalidMessage, .unsupportedProtocolVersion,
             .unauthorizedRelayRole, .authenticationRequired, .machineMismatch,
             .messageTooLarge:
            return true
        case .relay(let code, _):
            return code == "target_unavailable" || code == "invalid_message"
                || code == "unsupported_message" || code == "machine_mismatch"
                || code == "sender_mismatch" || code == "target_not_allowed"
                || code == "body_machine_mismatch" || code == "body_device_mismatch"
        case .notConnected:
            // This describes only the current send attempt. A prior attempt
            // may already have crossed Relay; the historical delivery state
            // passed to markRemoteMutationFailed decides whether release is
            // actually safe.
            return true
        case .eventBufferOverflow, .closed:
            return false
        }
    }

    private func markRemoteMutationFailed(_ requestID: String, detail: String,
                                          error: Error? = nil,
                                          hadPriorMayHaveBeenSent: Bool? = nil,
                                          machineID targetMachineID: String? = nil) {
        if let error, remoteMutationDefinitelyNotSent(error), hadPriorMayHaveBeenSent != true {
            completeRemoteMutation(requestID, for: targetMachineID)
            return
        }
        let mutationMachineID = targetMachineID ?? machineID
        guard var transactions = remoteMutationTransactionsByMachine[mutationMachineID],
              var transaction = transactions[requestID] else { return }
        transaction.deliveryState = .mayHaveBeenSent
        transaction.failure = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "连接已断开，操作结果待确认。" : detail
        transactions[requestID] = transaction
        remoteMutationTransactionsByMachine[mutationMachineID] = transactions
        if mutationMachineID == self.machineID {
            persistCurrentTransactionsLater(for: mutationMachineID)
        } else {
            persistPendingTransactionStoreLater()
        }
    }

    private func send(_ command: DSHCommand) {
        guard !removedMachineFenceUnavailable,
              !pendingTransactionPersistenceUnavailable,
              !machineID.isEmpty, !removedMachineIDs.contains(machineID) else {
            errorMessage = "当前 Mac 配对事务尚未完成，请重新配对后再试。"
            return
        }
        let attempt = command.type == "prompt.send" ? sendAttemptGenerations[command.requestId] : nil
        let promptDeadline = command.type == "prompt.send"
            ? pendingSendsByRequestID[command.requestId]?.dedupeExpiresAt
            : nil
        let machineGeneration = self.machineStateGeneration
        let expectedMachineID = self.machineID
        let readOnlyReadinessAtAttempt = self.readOnlyRecoveryReadinessRevision
        Task { @MainActor [weak self] in
            do {
                guard let self,
                      self.machineStateGeneration == machineGeneration,
                      self.machineID == expectedMachineID else { return }
                if self.isDurableRemoteMutation(command) {
                    guard let hadPriorMayHaveBeenSent = await self.beginRemoteMutationAttempt(
                        command.requestId, for: expectedMachineID) else {
                        self.markRemoteMutationFailed(
                            command.requestId,
                            detail: "无法保存待处理操作，结果尚未确认。")
                        self.errorMessage = "无法保存待处理操作，结果尚未确认。"
                        return
                    }
                    let mutationDeadline = self.remoteMutationTransactionsByMachine[expectedMachineID]?[command.requestId]?.retryDeadline
                    do {
                        try await self.transport.send(command, notAfter: promptDeadline ?? mutationDeadline)
                    } catch {
                        self.clearFailedRemoteRequest(command.requestId,
                                                      detail: error.localizedDescription,
                                                      error: error,
                                                      machineID: expectedMachineID,
                                                      hadPriorMayHaveBeenSent: hadPriorMayHaveBeenSent)
                        throw error
                    }
                    return
                }
                try await self.transport.send(command, notAfter: promptDeadline)
            }
            catch {
                guard let self else { return }
                if !self.isDurableRemoteMutation(command) {
                    self.clearFailedRemoteRequest(command.requestId, detail: error.localizedDescription,
                                                   error: error, machineID: expectedMachineID)
                }
                // A prompt that never left the phone parks for retry (with
                // its text intact) instead of only flashing an alert while
                // the draft is already gone.
                if command.type == "prompt.send" {
                    self.parkFailedPromptSend(command, error: error, attempt: attempt,
                                               machineGeneration: machineGeneration)
                } else if self.deferReadOnlyRequestAfterReconnect(command, error: error,
                                                                   machineGeneration: machineGeneration,
                                                                   readinessAtAttempt: readOnlyReadinessAtAttempt) {
                    // The command was a projection read that never left this
                    // phone. It is reissued once the current socket is ready.
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// `.notConnected` proves a read did not reach Relay. Queue only commands
    /// that cannot mutate remote state; prompts and other actions retain their
    /// normal, durable failure paths and are never silently retried here.
    private func deferReadOnlyRequestAfterReconnect(_ command: DSHCommand, error: Error,
                                                     machineGeneration: Int,
                                                     readinessAtAttempt: Int) -> Bool {
        guard machineGeneration == self.machineStateGeneration,
              command.machineId == machineID,
              (error as? DSHWebSocketError) == .notConnected,
              ["session.list", "workspace.catalog", "mode.catalog", "model.catalog", "session.open"]
                .contains(command.type) else { return false }
        if pendingReadOnlyRecoveryGeneration != machineGeneration {
            pendingReadOnlyRecoveryGeneration = machineGeneration
            requiredReadOnlyRecoveryReadinessRevision = readinessAtAttempt + 1
            pendingSessionListRecovery = false
            pendingWorkspaceCatalogRecovery = false
            pendingModeCatalogRecovery = false
            pendingModelCatalogRecovery = false
            pendingSessionOpenRecoveryIDs.removeAll(keepingCapacity: false)
        }
        switch command.type {
        case "session.list": pendingSessionListRecovery = true
        case "workspace.catalog": pendingWorkspaceCatalogRecovery = true
        case "mode.catalog": pendingModeCatalogRecovery = true
        case "model.catalog": pendingModelCatalogRecovery = true
        case "session.open":
            if let sessionID = command.sessionId, !sessionID.isEmpty {
                pendingSessionOpenRecoveryIDs.insert(sessionID)
            }
        default:
            break
        }
        scheduleReadOnlyRecoveryAttempt()
        return true
    }

    private func scheduleReadOnlyRecoveryAttempt() {
        guard readOnlyRecoveryTask == nil else { return }
        readOnlyRecoveryTask = Task { @MainActor [weak self] in
            // Commands from one appearance pass join one replacement batch.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.readOnlyRecoveryTask = nil
            self.performPendingReadOnlyRecoveryIfReady()
        }
    }

    private func performPendingReadOnlyRecoveryIfReady() {
        guard pendingReadOnlyRecoveryGeneration != nil else { return }
        guard pendingReadOnlyRecoveryGeneration == machineStateGeneration else {
            pendingReadOnlyRecoveryGeneration = nil
            requiredReadOnlyRecoveryReadinessRevision = nil
            pendingSessionListRecovery = false
            pendingWorkspaceCatalogRecovery = false
            pendingModeCatalogRecovery = false
            pendingModelCatalogRecovery = false
            pendingSessionOpenRecoveryIDs.removeAll(keepingCapacity: false)
            return
        }
        guard let requiredReadiness = requiredReadOnlyRecoveryReadinessRevision,
              readOnlyRecoveryReadinessRevision >= requiredReadiness else { return }
        guard state.transportState == .connected, state.machineOnline else { return }
        let wantsSessions = pendingSessionListRecovery
        let wantsWorkspaces = pendingWorkspaceCatalogRecovery
        let wantsModes = pendingModeCatalogRecovery
        let wantsModels = pendingModelCatalogRecovery
        let sessionIDs = pendingSessionOpenRecoveryIDs
        pendingReadOnlyRecoveryGeneration = nil
        requiredReadOnlyRecoveryReadinessRevision = nil
        pendingSessionListRecovery = false
        pendingWorkspaceCatalogRecovery = false
        pendingModeCatalogRecovery = false
        pendingModelCatalogRecovery = false
        pendingSessionOpenRecoveryIDs.removeAll(keepingCapacity: false)

        if wantsSessions { refreshSessions(includeArchived: showArchivedSessions) }
        if wantsWorkspaces { requestWorkspaces() }
        if wantsModes { requestModes() }
        if wantsModels { sendModelCatalog() }
        for sessionID in sessionIDs {
            send(DSHCommand.openSession(deviceId: deviceID, machineId: machineID,
                                        sessionId: sessionID, streaming: true))
        }
    }

    /// A local transport rejection (offline socket or an older Relay schema)
    /// has no protocol.error envelope. Clear only the request state owned by
    /// that command so folder-picker controls never remain disabled forever.
    private func clearFailedRemoteRequest(_ requestID: String, detail: String,
                                          error: Error? = nil,
                                          machineID targetMachineID: String? = nil,
                                          hadPriorMayHaveBeenSent: Bool? = nil) {
        if requestID == pendingWorkspaceCreationRequestID {
            pendingWorkspaceCreationRequestID = nil
            isCreatingWorkspace = false
        }
        if requestID == pendingDirectoryRequestID {
            pendingDirectoryRequestID = nil
            isLoadingDirectory = false
        }
        let mutationMachineID = targetMachineID ?? machineID
        if remoteMutationTransactionsByMachine[mutationMachineID]?[requestID] != nil {
            markRemoteMutationFailed(requestID, detail: detail, error: error,
                                      hadPriorMayHaveBeenSent: hadPriorMayHaveBeenSent,
                                      machineID: mutationMachineID)
            return
        }
        if pendingSessionCreationRequestIDs.contains(requestID) {
            // A transport send can fail after bytes have left the phone.  The
            // conservative classification keeps the original idempotency
            // key instead of allowing an unconfirmed retry to create twice.
            markSessionCreationFailed(requestID, detail: detail, resultUnknown: true)
            return
        }
    }

    /// Directory listings are request/response data, never broadcast state.
    /// Ignore an old or another device's reply before it reaches the reducer;
    /// otherwise a late response can visibly jump the folder browser back.
    private func shouldReduce(_ event: DSHEvent) -> Bool {
        guard case .directoryListing = event.kind else { return true }
        return event.envelope.messageId == pendingDirectoryRequestID
    }

    private func enqueue(_ event: DSHEvent) {
        pendingEvents.append(event)
        guard eventFlushTask == nil else { return }
        eventFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.eventBatchNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        eventFlushTask = nil
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)

        // Mutate a local copy and assign once. `state` is @Published, so this
        // turns a burst of assistant deltas/tool events into one UI update.
        var acceptedEvents: [DSHEvent] = []
        var next = state
        for event in events where shouldReduce(event) {
            if reducer.reduce(event, into: &next) {
                acceptedEvents.append(event)
            }
        }
        attachPendingMessageThumbnails(to: &next, events: acceptedEvents)
        invalidateTranscriptCaches(for: transcriptSessionIDs(affectedBy: acceptedEvents))
        // Do not compare the entire transcript here: that equality check would
        // walk every message/tool on every frame and cost more than the
        // notification we are trying to avoid. A batch always represents one
        // transport tick, so one assignment is the bounded publication point.
        state = next

        // Walk history markers in the same order as their accepted events.
        // Registering every marker up front would let a later history.started
        // retroactively suppress an earlier real-time terminal event merely
        // because both events happened to share one UI flush window.
        for event in acceptedEvents {
            switch event.kind {
            case .transportState(let connection) where connection != .connected:
                // The socket actor keeps one event stream across reconnects.
                // Re-arm per-connection catalogs here so a resumed Connector
                // cannot leave Home using only an old workspace/mode cache.
                requestedCatalogsForConnection = false
                markPendingSessionCreationsUnknown(
                    detail: "连接已断开，创建结果待确认。")
            case .machinePresence(false):
                markPendingSessionCreationsUnknown(
                    detail: "Mac 已离线，创建结果待确认。")
            default:
                break
            }
            let historyEvent: Bool
            let explicitlyHistorical = event.envelope.historyBatchId != nil
            switch event.kind {
            case .historyStarted:
                historyEvent = true
            case .historyCompleted(let batch):
                historyEvent = explicitlyHistorical || isReplayingHistory(sessionID: batch.sessionId)
            case .turnStateChanged(let turn):
                historyEvent = explicitlyHistorical || isReplayingHistory(sessionID: turn.sessionId)
            default:
                historyEvent = explicitlyHistorical
                    || (event.envelope.sessionId.map { isReplayingHistory(sessionID: $0) } ?? false)
            }
            if case .sessionSnapshot(let sessions) = event.kind {
                reconcileSessionCreationSnapshot(sessions)
            }
            handleSessionCreated(event)
            handleRemoteRequestCompletion(event)
            requestRemoteCatalogsWhenConnected()
            retireQueuedPrompt(event)
            confirmPromptAccepted(event)
            if !historyEvent { flushQueueOnSettle(event) }
            surfaceProtocolError(event)
            trackHistoryBatch(event)
            // A replay may contain a stored approval/question/failure state,
            // but it must not notify the user as if something just happened
            // on the live machine.
            if !historyEvent { notifyForEvent(event) }
            if case .historyCompleted(let batch) = event.kind {
                endHistoryReplay(batch)
            }
            observeReadOnlyRecoveryReadiness(event)
        }
        // A connector can report both replay-window and offline-queue loss in
        // one buffered delivery. Resolve the accumulated intent once, after
        // the whole batch has contributed its readiness state.
        performReplayResynchronizationIfReady()
        performPendingReadOnlyRecoveryIfReady()
    }

    private func observeReadOnlyRecoveryReadiness(_ event: DSHEvent) {
        switch event.kind {
        case .transportState(.connected), .connectionReady:
            readOnlyRecoveryReadinessRevision &+= 1
        default:
            break
        }
    }

    /// Mirrors the yellow/red session dots in Notification Center: the Mac is
    /// waiting on the user (approval, questions) or a turn died on an error.
    /// Each request notifies once; a session re-arms its failure notice when
    /// it leaves the failed state, so the next failure pings again.
    private func notifyForEvent(_ event: DSHEvent) {
        switch event.kind {
        case .approvalRequested(let approval):
            guard notifiedApprovalIDs.insert(approval.id).inserted else { return }
            let sessionTitle = sessions.first(where: { $0.id == approval.sessionId })?.title
            postLocalNotification(
                title: approvalNotificationTitle(sessionTitle: sessionTitle),
                body: "\(approval.toolName)：\(approval.reason)"
            )
        case .questionAsked(let request):
            guard notifiedQuestionIDs.insert(request.id).inserted else { return }
            let first = request.questions.first?.question ?? ""
            postLocalNotification(title: "需要你回答问题", body: String(first.prefix(120)))
        case .turnStateChanged(let turn):
            let failed = turn.state.lowercased() == "failed" || turn.state.lowercased() == "error"
            if failed {
                guard !notifiedFailedSessions.contains(turn.sessionId) else { return }
                notifiedFailedSessions.insert(turn.sessionId)
                let sessionTitle = sessions.first(where: { $0.id == turn.sessionId })?.title
                postLocalNotification(
                    title: "任务执行中断",
                    body: sessionTitle?.isEmpty == false ? (sessionTitle ?? "") : turn.sessionId
                )
            } else {
                notifiedFailedSessions.remove(turn.sessionId)
            }
        default:
            break
        }
    }

    private func approvalNotificationTitle(sessionTitle: String?) -> String {
        if let sessionTitle, !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "“\(sessionTitle)”需要权限确认"
        }
        return "需要权限确认"
    }

    /// Local notifications need no Info.plist key; the system prompts on
    /// first use. Silent when denied — the in-app dots remain the fallback.
    private func postLocalNotification(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.scheduleLocalNotification(title: title, body: body)
                case .notDetermined:
                    do {
                        let granted = try await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound])
                        if granted {
                            self.scheduleLocalNotification(title: title, body: body)
                        }
                    } catch {
                        // Denied or failed: stay silent, dots cover it.
                    }
                default:
                    break
                }
            }
        }
    }

    private func scheduleLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }

    /// Arms (or disarms) the force-merge fallback for one history batch. If
    /// `history.completed` never arrives, the carry entry would linger; after
    /// ten seconds it is merged back (normally a no-op, since rows are never
    /// cleared for replays) and the entry is dropped.
    private func beginHistoryReplay(_ batch: DSHHistoryBatch) {
        replayingHistoryBatches[batch.sessionId, default: []].insert(batch.batchId)
    }

    private func endHistoryReplay(_ batch: DSHHistoryBatch) {
        guard var batches = replayingHistoryBatches[batch.sessionId] else { return }
        batches.remove(batch.batchId)
        if batches.isEmpty { replayingHistoryBatches.removeValue(forKey: batch.sessionId) }
        else { replayingHistoryBatches[batch.sessionId] = batches }
    }

    private func isReplayingHistory(sessionID: String) -> Bool {
        !(replayingHistoryBatches[sessionID]?.isEmpty ?? true)
    }

    private func historyBatchKey(_ batch: DSHHistoryBatch) -> String {
        "\(batch.sessionId)\u{001F}\(batch.batchId)"
    }

    private func trackHistoryBatch(_ event: DSHEvent) {
        switch event.kind {
        case .historyStarted(let batch):
            beginHistoryReplay(batch)
            let key = historyBatchKey(batch)
            historyTimeoutTasks[key]?.cancel()
            historyTimeoutTasks[key] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.state.historyCarryOverBySession[batch.sessionId] != nil {
                    var next = self.state
                    self.reducer.completeHistory(
                        sessionId: batch.sessionId,
                        batchId: batch.batchId,
                        into: &next
                    )
                    self.invalidateTranscriptCaches(for: [batch.sessionId])
                    self.state = next
                }
                // Even when the reducer has already completed the carry (or
                // this overlapping batch was not the carry owner's batch),
                // the replay marker must be retired so queued prompts can
                // settle after a missing history.completed bracket.
                self.endHistoryReplay(batch)
                self.historyTimeoutTasks.removeValue(forKey: key)
            }
        case .historyCompleted(let batch):
            let key = historyBatchKey(batch)
            historyTimeoutTasks[key]?.cancel()
            historyTimeoutTasks.removeValue(forKey: key)
        default:
            break
        }
    }

    /// Fire-and-forget commands (`selectModel`, `setPermission`, `sendPrompt`,
    /// …) have no per-call waiter, so a Harness rejection used to sit unread
    /// in `protocolErrorsByRequestID` while the UI acted as if the tap had
    /// worked. Surface each one through the shared error alert instead.
    /// Attachment uploads are excluded: their waiter already reports the same
    /// error next to the composer, and double-reporting would just overwrite it.
    private func surfaceProtocolError(_ event: DSHEvent) {
        guard case .protocolError(let error) = event.kind else { return }
        guard !uploadWaitRequestIDs.contains(event.envelope.messageId) else { return }
        if isReplayResynchronizationNotice(error) {
            scheduleReplayResynchronization(for: event)
            return
        }
        errorMessage = error.message
    }

    /// The two notices are emitted by Connector after it has discarded old
    /// relay/replay frames. They describe stale local projections, not a
    /// rejected action, so rehydrate them silently. Keep the match to stable
    /// protocol codes; translated/error text remains free to change.
    private func isReplayResynchronizationNotice(_ error: DSHProtocolError) -> Bool {
        error.code == "replay-window-exceeded" || error.code == "offline-queue-exceeded"
    }

    /// Coalesce one or many replay-overflow notices into a single read-only
    /// refresh. A replay notice can arrive before `connection.ready`, so the
    /// scheduled task yields one event turn and then leaves the pending marker
    /// in place until the normal readiness events reach this model.
    private func scheduleReplayResynchronization(for event: DSHEvent) {
        guard event.envelope.machineId == machineID, !machineID.isEmpty else { return }
        let generation = machineStateGeneration
        if pendingReplayResynchronizationGeneration != generation {
            pendingReplayResynchronizationGeneration = generation
            pendingReplayResynchronizationSessionIDs.removeAll(keepingCapacity: false)
        }
        if let sessionID = event.envelope.sessionId, !sessionID.isEmpty {
            pendingReplayResynchronizationSessionIDs.insert(sessionID)
        } else if let visibleSessionID = visibleConversationSessionID {
            pendingReplayResynchronizationSessionIDs.insert(visibleSessionID)
        }
        guard replayResynchronizationTask == nil else { return }
        replayResynchronizationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.replayResynchronizationTask = nil
            self.performReplayResynchronizationIfReady()
        }
    }

    /// Sends no mutations and deliberately bypasses the two-second
    /// `openSession` gesture collapse: the missing history is precisely what
    /// needs a new read after an overflow. Waiting for both Relay readiness
    /// and Mac presence prevents these requests from becoming a second burst
    /// of `target_unavailable` protocol errors during startup.
    private func performReplayResynchronizationIfReady() {
        guard pendingReplayResynchronizationGeneration == machineStateGeneration else {
            pendingReplayResynchronizationGeneration = nil
            pendingReplayResynchronizationSessionIDs.removeAll(keepingCapacity: false)
            return
        }
        guard state.transportState == .connected, state.machineOnline else { return }
        var sessionIDs = pendingReplayResynchronizationSessionIDs
        pendingReplayResynchronizationGeneration = nil
        pendingReplayResynchronizationSessionIDs.removeAll(keepingCapacity: false)

        // This recovery covers every read-only projection. If a local
        // notConnected race queued the same work in this event batch, consume
        // it here so the second coordinator cannot issue duplicate opens or
        // catalogs after this method returns.
        if pendingReadOnlyRecoveryGeneration == machineStateGeneration {
            let needsWorkspaceCatalog = pendingWorkspaceCatalogRecovery
            let needsModeCatalog = pendingModeCatalogRecovery
            let handshakeCatalogsMissing = !requestedCatalogsForConnection
            pendingReadOnlyRecoveryGeneration = nil
            requiredReadOnlyRecoveryReadinessRevision = nil
            pendingSessionListRecovery = false
            pendingWorkspaceCatalogRecovery = false
            pendingModeCatalogRecovery = false
            pendingModelCatalogRecovery = false
            sessionIDs.formUnion(pendingSessionOpenRecoveryIDs)
            pendingSessionOpenRecoveryIDs.removeAll(keepingCapacity: false)
            if handshakeCatalogsMissing || needsWorkspaceCatalog {
                requestedCatalogsForConnection = true
                requestWorkspaces()
            }
            if handshakeCatalogsMissing || needsModeCatalog {
                requestedCatalogsForConnection = true
                requestModes()
            }
        }

        refreshSessions(includeArchived: showArchivedSessions)
        // A fresh relay handshake has already asked for these two catalogs.
        // If this notice arrived without that control event (for example a
        // test transport's direct Connector event), request them ourselves.
        if !requestedCatalogsForConnection {
            requestedCatalogsForConnection = true
            requestWorkspaces()
            requestModes()
        }
        sendModelCatalog()
        for sessionID in sessionIDs {
            send(DSHCommand.openSession(deviceId: deviceID, machineId: machineID,
                                        sessionId: sessionID, streaming: true))
        }
    }

    private func attachPendingMessageThumbnails(to state: inout DSHStoreState,
                                                events: [DSHEvent]) {
        for event in events {
            guard case .userMessageAccepted(let message) = event.kind,
                  let sessionID = event.envelope.sessionId,
                  let local = pendingMessageAttachmentsByRequestID[event.envelope.messageId],
                  let index = state.messagesBySession[sessionID]?.firstIndex(where: { $0.id == message.id }) else {
                continue
            }
            if state.messagesBySession[sessionID]![index].attachments.isEmpty {
                state.messagesBySession[sessionID]![index].attachments = local
            }
            clearPendingMessageAttachments(for: event.envelope.messageId)
        }
    }

    private var attachmentCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSH Anywhere/attachments", isDirectory: true)
    }

    private func handleSessionCreated(_ event: DSHEvent) {
        guard case .sessionCreated(let session) = event.kind else { return }
        // Open the session only when *this* device asked for it. The previous
        // check was `selectedSessionID == nil`, which had two failure modes: the
        // flag is only cleared by the list view, so if that view was not on
        // screen when a session arrived it stayed set and silently disabled
        // navigation from then on; and the Harness announces every new session,
        // so an unrelated one could steal the screen. Matching the request id
        // removes both.
        let requestID = session.createRequestId ?? event.envelope.messageId
        guard pendingSessionCreationRequestIDs.contains(requestID) else { return }
        completeCreatedSession(session, requestID: requestID)
    }

    /// A reconnect may lose the targeted `session.created` event while the
    /// authoritative snapshot still contains the durable create correlation.
    /// Resolve that request from the snapshot before the UI forgets the staged
    /// first message or presents it as an unrelated session.
    private func reconcileSessionCreationSnapshot(_ sessions: [DSHSessionSummary]) {
        for session in sessions {
            guard let requestID = session.createRequestId,
                  pendingSessionCreationRequestIDs.contains(requestID) else { continue }
            completeCreatedSession(session, requestID: requestID)
        }
    }

    private func completeCreatedSession(_ session: DSHSessionSummary, requestID: String) {
        pendingSessionCreationRequestIDs.remove(requestID)
        pendingSessionCreationCommandsByRequestID.removeValue(forKey: requestID)
        cancelSessionCreationTimeout(requestID: requestID)
        failedSessionCreations.removeValue(forKey: requestID)
        sessionCreationRetryDeadlines.removeValue(forKey: requestID)
        let wasDetached = detachedSessionCreationRequestIDs.remove(requestID) != nil
        sessionCreationResults[requestID] = session.id
        sessionCreationResultOrder.removeAll { $0 == requestID }
        sessionCreationResultOrder.append(requestID)
        // A result can arrive while no sheet is visible. Keep enough recent
        // request-scoped acknowledgements for a concurrent batch, but do not
        // turn this transient UI signal into an unbounded session history.
        while sessionCreationResultOrder.count > 64 {
            let expired = sessionCreationResultOrder.removeFirst()
            sessionCreationResults.removeValue(forKey: expired)
        }
        completedSessionCreationRequestID = requestID
        if !wasDetached {
            selectedSessionID = session.id
        }
        if wasDetached {
            errorMessage = "原创建请求已在 Mac 上完成；已保留原请求以避免重复创建。"
        }
        var pending = pendingInitialMessagesByRequestID[requestID]
        if var pendingMessage = pending {
            pendingMessage.sessionID = session.id
            pending = pendingMessage
            pendingInitialMessagesByRequestID[requestID] = pendingMessage
        }
        // Remove the completed create and, when present, install the initial
        // message phase in one atomic snapshot. If persistence fails, the
        // previous create transaction remains on disk and can safely replay
        // its idempotent acknowledgement after the next launch.
        let machineGeneration = self.machineStateGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.machineStateGeneration == machineGeneration,
                  self.machineID == machineID,
                  await self.persistCurrentTransactions(for: machineID) else { return }
            guard self.machineStateGeneration == machineGeneration,
                  self.machineID == machineID,
                  let pending else { return }
            await self.sendInitialMessage(pending, creationRequestID: requestID,
                                          to: session.id, machineGeneration: machineGeneration)
        }
    }

    /// Only a correlated remote acknowledgement changes picker completion
    /// state. This prevents a workspace created on another device from
    /// dismissing the local folder picker, and clears spinners on errors.
    private func handleRemoteRequestCompletion(_ event: DSHEvent) {
        let requestID = event.envelope.messageId
        switch event.kind {
        case .workspaceCreated(let workspace):
            completeRemoteMutation(requestID, for: event.envelope.machineId)
            guard requestID == pendingWorkspaceCreationRequestID else { break }
            pendingWorkspaceCreationRequestID = nil
            isCreatingWorkspace = false
            createdWorkspace = workspace
            requestWorkspaces()
        case .commandResult(let result):
            // command.result carries the request id in its payload; use it
            // instead of assuming every future Connector event keeps the
            // envelope message id equal to the original command id.
            completeRemoteMutation(result.requestId, for: event.envelope.machineId)
        case .directoryListing where requestID == pendingDirectoryRequestID:
            pendingDirectoryRequestID = nil
            isLoadingDirectory = false
        case .protocolError(let error):
            let eventMachineID = event.envelope.machineId
            if remoteMutationTransactionsByMachine[eventMachineID]?[requestID] != nil {
                if error.code == "bridge-result-unknown" || error.retryable {
                    markRemoteMutationFailed(requestID, detail: error.message, machineID: eventMachineID)
                } else {
                    // An explicit non-retryable rejection is the one case in
                    // which the Connector proves the native mutation did not
                    // commit. It is safe to mint a fresh id on a later tap.
                    completeRemoteMutation(requestID, for: eventMachineID)
                }
            }
            if requestID == pendingWorkspaceCreationRequestID {
                pendingWorkspaceCreationRequestID = nil
                isCreatingWorkspace = false
                errorMessage = error.message
            }
            if requestID == pendingDirectoryRequestID {
                pendingDirectoryRequestID = nil
                isLoadingDirectory = false
                errorMessage = error.message
            }
            if pendingSessionCreationRequestIDs.contains(requestID) {
                markSessionCreationFailed(requestID, detail: error.message,
                                           resultUnknown: error.code == "bridge-result-unknown")
                errorMessage = error.message
            }
        default:
            break
        }
    }

    private func markSessionCreationFailed(_ requestID: String, detail: String,
                                           resultUnknown: Bool = false) {
        guard pendingSessionCreationCommandsByRequestID[requestID] != nil else { return }
        cancelSessionCreationTimeout(requestID: requestID)
        let retryUntil = sessionCreationRetryDeadlines[requestID]
            ?? Date().addingTimeInterval(sessionCreationRetryWindow)
        sessionCreationRetryDeadlines[requestID] = retryUntil
        failedSessionCreations[requestID] = DSHSessionCreationFailure(
            id: requestID,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "创建会话失败。" : detail,
            resultUnknown: resultUnknown,
            retryUntil: retryUntil)
        persistCurrentTransactionsLater(for: machineID)
        errorMessage = detail
    }

    func sessionCreationFailure(for requestID: String) -> DSHSessionCreationFailure? {
        failedSessionCreations[requestID]
    }

    func consumeSessionCreationResult(for requestID: String) {
        sessionCreationResults.removeValue(forKey: requestID)
        sessionCreationResultOrder.removeAll { $0 == requestID }
    }

    /// Returns the most recent unresolved create for the active Mac so a new
    /// sheet can restore a transaction after a machine switch.
    func recoverableSessionCreationRequestID() -> String? {
        guard !suspendingTransactions else { return nil }
        if let lastSessionCreationRequestID,
           pendingSessionCreationRequestIDs.contains(lastSessionCreationRequestID),
           !detachedSessionCreationRequestIDs.contains(lastSessionCreationRequestID) {
            return lastSessionCreationRequestID
        }
        return pendingSessionCreationRequestIDs.first {
            !detachedSessionCreationRequestIDs.contains($0)
        }
    }

    func sessionCreationDraft(for requestID: String) -> (text: String, attachments: [DSHStagedAttachment])? {
        guard let pending = pendingInitialMessagesByRequestID[requestID] else { return nil }
        return (pending.text, pending.attachments)
    }

    func sessionCreationRetryExpired(for requestID: String) -> Bool {
        guard let deadline = sessionCreationRetryDeadlines[requestID] else { return false }
        return Date() >= deadline
    }

    /// Re-sends the exact original create command. The request id is retained
    /// so a timeout/unknown result is coalesced by Connector and Bridge
    /// idempotency instead of creating a second session.
    func retrySessionCreation(requestID: String) {
        guard !pendingTransactionPersistenceUnavailable else {
            errorMessage = "待处理请求存储不可用，已停止重试以避免重复会话。"
            return
        }
        guard let command = pendingSessionCreationCommandsByRequestID[requestID],
              pendingSessionCreationRequestIDs.contains(requestID) else { return }
        // The Bridge keeps the create request/result in its durable journal
        // and resumes a committed-but-partially-configured session by the
        // same request id.  Do not apply the old in-memory ten-minute cutoff:
        // after that HTTP cache expires, refusing this recovery request would
        // strand a real session whose setup never completed.
        failedSessionCreations.removeValue(forKey: requestID)
        detachedSessionCreationRequestIDs.remove(requestID)
        let expectedMachineGeneration = machineStateGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.machineStateGeneration == expectedMachineGeneration,
                  self.machineID == machineID else { return }
            guard await self.persistCurrentTransactions(for: machineID) else {
                self.cancelSessionCreationTimeout(requestID: requestID)
                self.failedSessionCreations[requestID] = DSHSessionCreationFailure(
                    id: requestID,
                    detail: "无法保存待处理请求，消息尚未发送。",
                    resultUnknown: false,
                    retryUntil: .now)
                self.errorMessage = "无法保存待处理请求，消息尚未发送。"
                return
            }
            guard self.machineStateGeneration == expectedMachineGeneration,
                  self.machineID == machineID else { return }
            self.armSessionCreationTimeout(requestID: requestID)
            self.send(command)
        }
    }

    /// Keeps an unknown-result request correlated while the user edits a new
    /// draft.  It is deliberately not a cancellation: a late `session.created`
    /// still settles the original operation and sends its original first
    /// message, while a later draft receives a distinct request id.
    func retainSessionCreationForEditing(requestID: String) {
        guard let failure = failedSessionCreations[requestID], failure.resultUnknown,
              pendingSessionCreationCommandsByRequestID[requestID] != nil else { return }
        detachedSessionCreationRequestIDs.insert(requestID)
        persistCurrentTransactionsLater(for: machineID)
        errorMessage = "原创建请求结果待确认；已保留它，稍后若 Mac 已创建会话会单独提示。"
    }

    /// Cancels a failed create explicitly. This is the only path that drops
    /// the staged initial text and attachments before a session exists; the
    /// new-session sheet keeps its local draft so the user can edit and submit
    /// it again with a fresh request id.
    func cancelSessionCreation(requestID: String) {
        if let failure = failedSessionCreations[requestID], failure.resultUnknown {
            // There is no remote cancel primitive.  Never discard an
            // operation whose side effect may already have committed.
            retainSessionCreationForEditing(requestID: requestID)
            return
        }
        pendingSessionCreationRequestIDs.remove(requestID)
        pendingSessionCreationCommandsByRequestID.removeValue(forKey: requestID)
        pendingInitialMessagesByRequestID.removeValue(forKey: requestID)
        failedSessionCreations.removeValue(forKey: requestID)
        sessionCreationRetryDeadlines.removeValue(forKey: requestID)
        detachedSessionCreationRequestIDs.remove(requestID)
        removeStoredSessionCreationTransaction(requestID, for: machineID)
        cancelSessionCreationTimeout(requestID: requestID)
        if lastSessionCreationRequestID == requestID { lastSessionCreationRequestID = nil }
    }

    /// The home view may appear before its socket handshake completes. Ask for
    /// the server-owned workspace and mode catalogs at the actual connection
    /// boundary as well, so empty projects do not depend on a SwiftUI timing
    /// race. The transport's schema gate keeps this harmless on older Relays.
    private func requestRemoteCatalogsWhenConnected() {
        guard state.transportState == .connected, state.machineOnline,
              !requestedCatalogsForConnection else { return }
        requestedCatalogsForConnection = true
        requestWorkspaces()
        requestModes()
        resumeStagedPromptUploads()
        resumeQueuedPromptTransactions()
    }

    /// Repairs the one unavoidable boundary between UserDefaults (the local
    /// queue mirror) and the transaction journal.  A crash after the mirror
    /// was marked `sent` but before the journal commit leaves no pending map;
    /// while the remote tombstone window is still valid, replay the same
    /// stable request id so the prompt is either coalesced or accepted once.
    private func resumeQueuedPromptTransactions() {
        guard connectionState == .connected else { return }
        let generation = machineStateGeneration
        let activeMachineID = machineID
        let cutoff = Date().addingTimeInterval(-Self.promptIdempotencyWindow)
        // If the process died after the durable prompt journal committed but
        // before the UserDefaults mirror was promoted from dispatchPrepared
        // to sent, the journal is authoritative. Promote the mirror without
        // sending a second request.
        var reconciled = false
        for (sessionID, items) in queuedPromptsBySession {
            var next = items
            for index in next.indices {
                guard next[index].dispatchPrepared,
                      let requestID = next[index].requestId,
                      pendingSendsByRequestID[requestID] != nil ||
                          failedSendsByRequestID[requestID] != nil else { continue }
                let item = next[index]
                next[index] = DSHQueuedPrompt(
                    id: item.id, text: item.text, mode: item.mode,
                    sentAt: item.sentAt, dispatchAt: item.dispatchAt,
                    sent: true, requestId: requestID)
                reconciled = true
            }
            queuedPromptsBySession[sessionID] = next
        }
        if reconciled { persistQueuedPrompts() }
        let candidates = queuedPromptsBySession.flatMap { sessionID, items in
            items.filter { item in
                (item.dispatchPrepared ||
                    (item.sent && (item.dispatchAt ?? item.sentAt) >= cutoff)) &&
                    item.requestId != nil &&
                    pendingSendsByRequestID[item.requestId!] == nil &&
                    failedSendsByRequestID[item.requestId!] == nil
            }.map { (sessionID: sessionID, item: $0) }
        }
        for candidate in candidates {
            let sessionID = candidate.sessionID
            let item = candidate.item
            guard let requestID = item.requestId else { continue }
            if item.dispatchPrepared {
                // Known-unsent preparation: sendQueuedPrompt intentionally
                // starts a fresh local dedupe window, even if the queue item
                // waited longer than the remote tombstone lifetime.
                sendQueuedPrompt(id: item.id, sessionID: sessionID)
                continue
            }
            guard queuedPromptSendIDs.insert(item.id).inserted else { continue }
            Task { @MainActor [weak self] in
                defer { self?.queuedPromptSendIDs.remove(item.id) }
                guard let self,
                      self.machineStateGeneration == generation,
                      self.machineID == activeMachineID else { return }
                _ = await self.sendPromptPersisted(
                    item.text, attachments: [], to: sessionID,
                    mode: item.mode, requestId: requestID,
                    expectedMachineGeneration: generation,
                    expectedMachineID: activeMachineID,
                    dedupeExpiresAt: (item.dispatchAt ?? item.sentAt)
                        .addingTimeInterval(Self.promptIdempotencyWindow))
            }
        }
    }

    private func resumeStagedPromptUploads() {
        guard connectionState == .connected else { return }
        let generation = machineStateGeneration
        let machine = machineID
        for pending in pendingSendsByRequestID.values where
            pending.phase == .preparing || pending.phase == .readyToSend {
            guard stagedPromptResumeIDs.insert(pending.id).inserted else { continue }
            Task { @MainActor [weak self] in
                defer { self?.stagedPromptResumeIDs.remove(pending.id) }
                guard let self else { return }
                do {
                    _ = try await self.sendStagedPromptPersisted(
                        pending.text, attachments: pending.stagedAttachments,
                        to: pending.sessionID, mode: pending.mode,
                        requestId: pending.id,
                        expectedMachineGeneration: generation,
                        expectedMachineID: machine)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func sendInitialMessage(_ pending: DSHPendingInitialMessage,
                                    creationRequestID: String,
                                    to sessionID: String,
                                    machineGeneration: Int? = nil) async {
        guard !pendingTransactionPersistenceUnavailable else {
            errorMessage = "待处理请求存储不可用，已停止发送首条消息。"
            return
        }
        guard pendingInitialMessageUploads.insert(creationRequestID).inserted else { return }
        defer { pendingInitialMessageUploads.remove(creationRequestID) }
        if let machineGeneration, machineGeneration != self.machineStateGeneration { return }
        var pendingMessage = pending
        do {
            let hasUnuploadedAttachment = pendingMessage.attachments.contains {
                pendingMessage.uploadedAttachments[$0.id.uuidString] == nil
            }
            if let deadline = pendingMessage.attachmentRecoveryDeadline,
               Date() >= deadline,
               hasUnuploadedAttachment { throw DSHAttachmentUploadError.recoveryExpired }
            var receipts: [String] = []
            var messageAttachments: [DSHMessageAttachment] = []
            receipts.reserveCapacity(pendingMessage.attachments.count)
            messageAttachments.reserveCapacity(pendingMessage.attachments.count)
            for attachment in pendingMessage.attachments {
                if let machineGeneration, machineGeneration != self.machineStateGeneration {
                    throw CancellationError()
                }
                let attachmentKey = attachment.id.uuidString
                if let uploaded = pendingMessage.uploadedAttachments[attachmentKey] {
                    receipts.append(uploaded.receiptId ?? uploaded.id)
                    messageAttachments.append(uploaded)
                    continue
                }
                let uploadRequestID = "\(creationRequestID)/attachment/\(attachmentKey)"
                let receipt = try await uploadAttachmentAndWait(name: attachment.name,
                                                                 data: attachment.data,
                                                                 for: sessionID,
                                                                 machineGeneration: machineGeneration,
                                                                 requestID: uploadRequestID,
                                                                 attachmentRecoveryDeadline: pendingMessage.attachmentRecoveryDeadline)
                let mediaType = attachment.isImage ? "image/jpeg" : nil
                cacheAttachmentData(attachment.data, for: receipt)
                let uploaded = DSHMessageAttachment(id: receipt,
                                                     name: attachment.name,
                                                     mediaType: mediaType,
                                                     receiptId: receipt)
                pendingMessage.uploadedAttachments[attachmentKey] = uploaded
                pendingInitialMessagesByRequestID[creationRequestID] = pendingMessage
                guard await persistCurrentTransactions(for: machineID) else {
                    throw DSHAttachmentUploadError.persistenceUnavailable
                }
                receipts.append(receipt)
                messageAttachments.append(uploaded)
            }
            if let machineGeneration, machineGeneration != self.machineStateGeneration { return }
            // Once the initial text has entered the ordinary prompt transport,
            // its request id has the same finite remote dedupe lifetime as any
            // other prompt. Do not let this separate initial-message journal
            // create a second, unbounded retry path.
            if let existing = pendingSendsByRequestID[pendingMessage.promptRequestID],
               existing.phase == .awaitingAck || existing.phase == .preparing || existing.phase == .readyToSend {
                return
            }
            let inheritedDeadline = pendingMessage.dedupeExpiresAt
                ?? pendingSendsByRequestID[pendingMessage.promptRequestID]?.dedupeExpiresAt
                ?? failedSendsByRequestID[pendingMessage.promptRequestID]?.retryUntil
            if let inheritedDeadline, Date() >= inheritedDeadline {
                throw DSHAttachmentUploadError.persistenceUnavailable
            }
            let dedupeDeadline = inheritedDeadline
                ?? Date().addingTimeInterval(Self.promptIdempotencyWindow)
            pendingMessage.dedupeExpiresAt = dedupeDeadline
            pendingInitialMessagesByRequestID[creationRequestID] = pendingMessage
            guard await persistCurrentTransactions(for: machineID) else {
                throw DSHAttachmentUploadError.persistenceUnavailable
            }
            let sent = await sendPromptPersisted(
                pendingMessage.text, attachments: receipts,
                messageAttachments: messageAttachments, to: sessionID,
                requestId: pendingMessage.promptRequestID,
                expectedMachineGeneration: machineGeneration,
                expectedMachineID: machineID,
                dedupeExpiresAt: dedupeDeadline)
            guard sent else {
                throw DSHAttachmentUploadError.persistenceUnavailable
            }
        } catch {
            if let machineGeneration, machineGeneration != self.machineStateGeneration { return }
            failedInitialMessages[creationRequestID] = DSHInitialMessageFailure(
                id: creationRequestID, sessionID: sessionID, text: pendingMessage.text,
                detail: error.localizedDescription)
            _ = await persistCurrentTransactions(for: machineID)
            errorMessage = error.localizedDescription
        }
    }

    /// Retries an initial upload that failed before a normal prompt request
    /// could be sent. The staged bytes remain in the pending map until the
    /// matching `prompt.accepted` receipt arrives.
    func failedInitialMessage(for sessionID: String) -> DSHInitialMessageFailure? {
        failedInitialMessages.values.first { $0.sessionID == sessionID }
    }

    /// Compatibility accessor for callers that only need any outstanding
    /// failure. Conversation screens should prefer the session-scoped method.
    var failedInitialMessage: DSHInitialMessageFailure? {
        failedInitialMessages.values.first
    }

    func retryFailedInitialMessage(_ failure: DSHInitialMessageFailure) {
        guard !pendingTransactionPersistenceUnavailable else {
            errorMessage = "待处理请求存储不可用，已停止重试以避免重复发送。"
            return
        }
        guard let pending = pendingInitialMessagesByRequestID[failure.id],
              let sessionID = pending.sessionID else { return }
        // After the initial upload reaches prompt.send, the normal prompt
        // transaction owns its request id and deadline. Reuse that path so
        // this UI button cannot bypass the finite dedupe window.
        if let promptFailure = failedSendsByRequestID[pending.promptRequestID] {
            retryFailedSend(requestID: promptFailure.id)
            return
        }
        if let prompt = pendingSendsByRequestID[pending.promptRequestID] {
            if prompt.phase == .awaitingAck || prompt.phase == .preparing || prompt.phase == .readyToSend {
                return
            }
        }
        if let deadline = pending.dedupeExpiresAt, Date() >= deadline {
            errorMessage = "首条消息已超过安全重试窗口，请重新发送以避免重复执行。"
            return
        }
        failedInitialMessages.removeValue(forKey: failure.id)
        let generation = machineStateGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.machineStateGeneration == generation,
                  await self.persistCurrentTransactions(for: self.machineID) else { return }
            await self.sendInitialMessage(pending, creationRequestID: failure.id,
                                          to: sessionID, machineGeneration: generation)
        }
    }

    func retryFailedInitialMessage() {
        guard let failure = failedInitialMessage else { return }
        retryFailedInitialMessage(failure)
    }

    func dismissFailedInitialMessage(_ failure: DSHInitialMessageFailure) {
        // Dismissing an expired/unrecoverable initial message is a terminal
        // disposition.  Remove both the visible failure and the staged
        // payload only after the journal confirms the deletion.  If the app
        // is killed before that write, the failure remains visible and the
        // staged bytes are still recoverable on the next launch.
        let machineID = self.machineID
        let generation = machineStateGeneration
        let previousFailure = failedInitialMessages[failure.id]
        let previousPending = pendingInitialMessagesByRequestID[failure.id]
        guard previousFailure != nil || previousPending != nil else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.machineStateGeneration == generation,
                  self.failedInitialMessages[failure.id] != nil
                    || self.pendingInitialMessagesByRequestID[failure.id] != nil else { return }
            self.failedInitialMessages.removeValue(forKey: failure.id)
            self.pendingInitialMessagesByRequestID.removeValue(forKey: failure.id)
            guard await self.persistCurrentTransactions(for: machineID) else {
                if let previousFailure {
                    self.failedInitialMessages[failure.id] = previousFailure
                }
                if let previousPending {
                    self.pendingInitialMessagesByRequestID[failure.id] = previousPending
                }
                self.errorMessage = "无法保存初始消息的关闭状态，请稍后重试。"
                return
            }
        }
    }

    func dismissFailedInitialMessage() {
        if let failure = failedInitialMessage {
            dismissFailedInitialMessage(failure)
        }
    }

    static func preview(longConversation: Bool = false) -> DSHAppModel {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let session = DSHSessionSummary(id: "preview-session", title: "Plan the iOS client",
                                        updatedAt: now,
                                        cwd: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                                        workspaceId: "preview-dsh",
                                        workspaceName: "DSH-ANYWHERE", running: true,
                                        provider: "deepseek", model: "deepseek-v4.1-flash",
                                        reasoningEffort: "medium", branch: "main")
        let second = DSHSessionSummary(id: "preview-session-2", title: "Debug attachment upload",
                                       updatedAt: now - 45_000,
                                       cwd: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                                       workspaceId: "preview-dsh", workspaceName: "DSH-ANYWHERE",
                                       model: "deepseek-v4.1-flash", branch: "main")
        let third = DSHSessionSummary(id: "preview-session-3", title: "Research relay reconnect",
                                      updatedAt: now - 180_000,
                                      cwd: "/Users/aluvien/Documents/Develop/App/tihu-test",
                                      workspaceId: "preview-lab", workspaceName: "tihu-test",
                                      model: "deepseek-v4.1-flash", branch: "main")
        var state = DSHStoreState()
        state.sessions = [session, second, third]
        // The remote catalog intentionally has a project with no sessions;
        // previews exercise the same source of truth as the production home.
        state.workspaceCatalog = [
            DSHWorkspaceOption(id: "preview-dsh", name: "DSH-ANYWHERE",
                               path: "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE"),
            DSHWorkspaceOption(id: "preview-lab", name: "tihu-test",
                               path: "/Users/aluvien/Documents/Develop/App/tihu-test"),
            DSHWorkspaceOption(id: "preview-empty", name: "未开始项目",
                               path: "/Users/aluvien/Documents/Develop/App/empty-project"),
        ]
        state.modeCatalog = DSHModeCatalog(defaultMode: "standard", modes: [
            DSHModeOption(id: "standard", name: "标准模式", description: "通用任务执行"),
            DSHModeOption(id: "plan", name: "规划模式", description: "先制定方案再执行"),
            DSHModeOption(id: "review", name: "审查模式", description: "检查已有工作"),
        ])
        state.hasLoadedSessions = true
        state.transportState = .connected
        state.machineOnline = true
        state.bridgeReachable = true
        state.connectionState = .connected
        let efforts = [
            DSHModelReasoningEffort(id: "low", name: "Low"),
            DSHModelReasoningEffort(id: "medium", name: "Medium"),
            DSHModelReasoningEffort(id: "high", name: "High"),
        ]
        state.modelCatalog = DSHModelCatalog(
            default: DSHModelSelection(provider: "deepseek", model: "deepseek-v4.1-flash",
                                       reasoningEffort: "medium"),
            routableProviders: ["deepseek"],
            groups: [DSHModelCatalogGroup(
                id: "deepseek", name: "DeepSeek",
                models: [DSHModelCatalogModel(
                    id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash",
                    reasoning: DSHModelReasoning(efforts: efforts, defaultEffort: "medium")
                )]
            )],
            failures: []
        )
        state.messagesBySession[session.id] = [
            DSHChatMessage(id: "preview-user", role: .user, markdown: "Build a native client for my local Harness."),
            DSHChatMessage(id: "preview-assistant", role: .assistant, markdown: "I can help you plan and implement the native client.")
        ]
        #if DEBUG
        if longConversation || ProcessInfo.processInfo.arguments.contains("--dsh-preview-long-conversation") {
            state.messagesBySession[session.id] = (0..<12).flatMap { index in
                [DSHChatMessage(id: "user-\(index)", role: .user, markdown: "第 \(index + 1) 轮：测试长对话布局"),
                 DSHChatMessage(id: "assistant-\(index)", role: .assistant,
                                markdown: "第 \(index + 1) 轮回答。\n\n打开输入框后，这段文字应随可见区域抬起。\n\n最后一行必须完整显示在输入框上方。")]
            }
        }
        #endif
        state.toolsBySession[session.id] = [
            DSHToolActivity(id: "preview-tool", name: "read_project", status: "completed", detail: "Read 12 files")
        ]
        let model = DSHAppModel(transport: DSHPreviewTransport(), initialState: state, isPaired: true)
        model.machineName = "macmini"
        model.selectedSessionID = session.id
        model.showMessageActionsByDefault = true
        return model
    }

    #if DEBUG
    static func previewHome(grouped: Bool = false) -> DSHAppModel {
        let model = preview()
        model.selectedSessionID = nil
        model.groupsSessionsByWorkspace = grouped
        return model
    }

    /// Preview fixture for the same disconnected home state shown by Happy.
    /// It is DEBUG-only so production builds never expose a hidden launch flag.
    static func previewHomeUnreachable() -> DSHAppModel {
        let model = previewHome()
        model.state.sessions = []
        model.state.hasLoadedSessions = true
        model.state.connectionState = .failed("macmini is unreachable")
        model.machineName = "macmini"
        return model
    }
    #endif

    private func sessionReadKey(_ sessionID: String) -> String {
        "\(machineID)\u{001F}\(sessionID)"
    }

    private static func loadLastReadSessionTimestamps() -> [String: Int64] {
        guard let values = UserDefaults.standard.dictionary(forKey: lastReadSessionsKey) else { return [:] }
        return values.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    private static func loadOrCreateUnreadBaseline() -> Int64 {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: unreadBaselineKey) as? NSNumber {
            return stored.int64Value
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        defaults.set(now, forKey: unreadBaselineKey)
        return now
    }
}

private extension String {
    /// Receipt ids are opaque, so encode them into a portable filename rather
    /// than using them directly as a path component.
    var dshAttachmentCacheFileName: String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
