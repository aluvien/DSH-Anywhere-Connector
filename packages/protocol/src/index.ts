import { z } from "zod";

/** The wire format is intentionally pinned. Bump this only with a migration plan. */
export const PROTOCOL_VERSION = 1 as const;

const IdentifierSchema = z.string().min(1).max(256);
const TimestampSchema = z.number().int().nonnegative();
export const SequenceSchema = z.number().int().positive();

const StrictObject = <T extends z.ZodRawShape>(shape: T) => z.object(shape).strict();

export const SessionStatusSchema = z.enum([
  "idle",
  "running",
  "waiting_approval",
  "error",
  "closed",
]);
export type SessionStatus = z.infer<typeof SessionStatusSchema>;

export const SessionSummarySchema = StrictObject({
  id: IdentifierSchema,
  title: z.string().min(1).max(512),
  updatedAt: TimestampSchema,
  cwd: z.string().min(1).optional(),
  workspaceId: IdentifierSchema.optional(),
  workspaceName: z.string().min(1).max(512).optional(),
  archived: z.boolean().optional(),
  running: z.boolean().optional(),
  blank: z.boolean().optional(),
  parentSessionId: IdentifierSchema.optional(),
  provider: z.string().min(1).max(256).optional(),
  model: z.string().min(1).max(512).optional(),
  reasoningEffort: z.string().min(1).max(256).optional(),
  permissionMode: z.enum(["ask", "never", "read-only", "workspace-write", "danger-full-access"]).optional(),
  usage: z.lazy(() => SessionUsageSchema).optional(),
});
export type SessionSummary = z.infer<typeof SessionSummarySchema>;

export const SessionUsageSchema = StrictObject({
  rounds: z.number().int().nonnegative().optional(),
  steps: z.number().int().nonnegative().optional(),
  inputTokens: z.number().nonnegative().optional(),
  outputTokens: z.number().nonnegative().optional(),
  totalTokens: z.number().nonnegative().optional(),
  cacheReadTokens: z.number().nonnegative().optional(),
  cacheWriteTokens: z.number().nonnegative().optional(),
  cacheHitPercent: z.number().min(0).max(100).optional(),
  tokensPerSecond: z.number().nonnegative().optional(),
  contextUsed: z.number().nonnegative().optional(),
  contextWindow: z.number().positive().optional(),
});
export type SessionUsage = z.infer<typeof SessionUsageSchema>;

export const ModelSelectionSchema = StrictObject({
  provider: z.string().min(1).max(256),
  model: z.string().min(1).max(512),
  reasoningEffort: z.string().min(1).max(256).optional(),
});
export type ModelSelection = z.infer<typeof ModelSelectionSchema>;

export const ModelReasoningEffortSchema = StrictObject({
  id: IdentifierSchema,
  name: z.string().min(1).max(256),
  description: z.string().max(2_000).optional(),
});
export const ModelCatalogModelSchema = StrictObject({
  id: IdentifierSchema,
  name: z.string().min(1).max(512),
  description: z.string().max(2_000).optional(),
  reasoning: StrictObject({
    efforts: z.array(ModelReasoningEffortSchema).max(100),
    defaultEffort: IdentifierSchema.optional(),
  }).optional(),
});
export const ModelCatalogGroupSchema = StrictObject({
  id: IdentifierSchema,
  name: z.string().min(1).max(512),
  models: z.array(ModelCatalogModelSchema).max(500),
});
export const ModelCatalogPayloadSchema = StrictObject({
  default: ModelSelectionSchema,
  routableProviders: z.array(IdentifierSchema).max(100),
  groups: z.array(ModelCatalogGroupSchema).max(100),
  failures: z.array(StrictObject({
    id: IdentifierSchema,
    name: z.string().min(1).max(512),
    message: z.string().max(4_000),
  })).max(100),
});
export type ModelCatalogPayload = z.infer<typeof ModelCatalogPayloadSchema>;

const EnvelopeFields = {
  version: z.literal(PROTOCOL_VERSION),
  messageId: IdentifierSchema,
  machineId: IdentifierSchema,
  deviceId: IdentifierSchema,
  sessionId: IdentifierSchema.optional(),
  sequence: SequenceSchema,
  timestamp: TimestampSchema,
};

const EventEnvelope = <T extends z.ZodTypeAny, K extends string>(
  type: K,
  payload: T,
) => StrictObject({ ...EnvelopeFields, type: z.literal(type), payload });

export const ConnectionReadyPayloadSchema = StrictObject({
  machineId: IdentifierSchema,
  deviceId: IdentifierSchema,
  serverTime: TimestampSchema,
  capabilities: z.array(IdentifierSchema).max(100),
  resumedFrom: SequenceSchema.optional(),
});
export type ConnectionReadyPayload = z.infer<typeof ConnectionReadyPayloadSchema>;

export const SessionSnapshotPayloadSchema = z.array(SessionSummarySchema);
export type SessionSnapshotPayload = z.infer<typeof SessionSnapshotPayloadSchema>;

export const SessionCreatedPayloadSchema = SessionSummarySchema;
export type SessionCreatedPayload = z.infer<typeof SessionCreatedPayloadSchema>;

export const ChatRoleSchema = z.enum(["user", "assistant", "system"]);
export type ChatRole = z.infer<typeof ChatRoleSchema>;

export const AssistantMessageDeltaPayloadSchema = StrictObject({
  messageId: IdentifierSchema,
  text: z.string(),
});
export type AssistantMessageDeltaPayload = z.infer<typeof AssistantMessageDeltaPayloadSchema>;

export const ChatMessagePayloadSchema = StrictObject({
  id: IdentifierSchema,
  role: ChatRoleSchema,
  markdown: z.string(),
  usage: z.lazy(() => SessionUsageSchema).optional(),
  provider: z.string().min(1).max(256).optional(),
  model: z.string().min(1).max(512).optional(),
  reasoningEffort: z.string().min(1).max(256).optional(),
  contextWindow: z.number().positive().optional(),
});
export type ChatMessagePayload = z.infer<typeof ChatMessagePayloadSchema>;

export const ToolStartedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  name: IdentifierSchema,
  status: z.string().min(1),
  detail: z.string().optional(),
});
export type ToolStartedPayload = z.infer<typeof ToolStartedPayloadSchema>;

export const ToolResultStatusSchema = z.enum(["succeeded", "failed", "cancelled"]);
export type ToolResultStatus = z.infer<typeof ToolResultStatusSchema>;

export const ToolCompletedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  name: IdentifierSchema,
  status: z.string().min(1),
  detail: z.string().optional(),
});
export type ToolCompletedPayload = z.infer<typeof ToolCompletedPayloadSchema>;

export const ApprovalDecisionSchema = z.enum(["allow-once", "rejected", "expired"]);
export type ApprovalDecision = z.infer<typeof ApprovalDecisionSchema>;

export const ApprovalRequestedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  sessionId: IdentifierSchema,
  toolName: IdentifierSchema,
  reason: z.string().min(1).max(4_000),
  expiresAt: TimestampSchema.optional(),
});
export type ApprovalRequestedPayload = z.infer<typeof ApprovalRequestedPayloadSchema>;

export const ApprovalResolvedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  allowed: z.boolean(),
});
export type ApprovalResolvedPayload = z.infer<typeof ApprovalResolvedPayloadSchema>;

export const TurnStateSchema = z.enum([
  "queued",
  "running",
  "awaiting_approval",
  "completed",
  "failed",
  "cancelled",
]);
export type TurnState = z.infer<typeof TurnStateSchema>;

export const TurnStateChangedPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  state: z.string().min(1),
});
export type TurnStateChangedPayload = z.infer<typeof TurnStateChangedPayloadSchema>;

export const ProtocolErrorPayloadSchema = StrictObject({
  code: IdentifierSchema,
  message: z.string().min(1).max(4_000),
  retryable: z.boolean(),
});
export type ProtocolErrorPayload = z.infer<typeof ProtocolErrorPayloadSchema>;

export const UsageUpdatedPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  usage: SessionUsageSchema,
});
export type UsageUpdatedPayload = z.infer<typeof UsageUpdatedPayloadSchema>;

export const PermissionUpdatedPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  mode: z.enum(["ask", "never", "read-only", "workspace-write", "danger-full-access"]),
  approvalPolicy: z.enum(["ask", "never"]).optional(),
});
export type PermissionUpdatedPayload = z.infer<typeof PermissionUpdatedPayloadSchema>;

export const SessionMetadataUpdatedPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  provider: z.string().min(1).max(256).optional(),
  model: z.string().min(1).max(512).optional(),
  reasoningEffort: z.string().min(1).max(256).optional(),
  contextWindow: z.number().positive().optional(),
});
export type SessionMetadataUpdatedPayload = z.infer<typeof SessionMetadataUpdatedPayloadSchema>;

export const CommandResultPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  requestId: IdentifierSchema,
  matched: z.boolean(),
  commandId: IdentifierSchema.optional(),
  kind: z.enum(["success", "error"]).optional(),
  text: z.string().max(100_000).optional(),
});
export type CommandResultPayload = z.infer<typeof CommandResultPayloadSchema>;

export const AttachmentUploadedPayloadSchema = StrictObject({
  sessionId: IdentifierSchema,
  requestId: IdentifierSchema,
  receiptId: IdentifierSchema,
  name: z.string().min(1).max(512),
  mediaType: z.string().min(1).max(256).optional(),
  size: z.number().int().nonnegative().optional(),
});
export type AttachmentUploadedPayload = z.infer<typeof AttachmentUploadedPayloadSchema>;

/**
 * Model reasoning is deliberately kept out of the answer markdown: the phone
 * transcript stays readable, and a client that wants the chain-of-thought can
 * collapse it behind a disclosure instead of mixing it into the reply.
 */
export const AssistantReasoningPayloadSchema = StrictObject({
  messageId: IdentifierSchema,
  text: z.string().min(1).max(200_000),
});
export type AssistantReasoningPayload = z.infer<typeof AssistantReasoningPayloadSchema>;

/** One selectable answer offered for a user question. */
export const AskUserQuestionOptionSchema = StrictObject({
  label: z.string().min(1).max(512),
  description: z.string().max(2_000).optional(),
});
export type AskUserQuestionOption = z.infer<typeof AskUserQuestionOptionSchema>;

export const AskUserQuestionItemSchema = StrictObject({
  id: IdentifierSchema,
  question: z.string().min(1).max(4_000),
  header: z.string().max(512).optional(),
  /** Supporting detail (a plan under review, for example), kept out of labels. */
  detail: z.string().max(200_000).optional(),
  options: z.array(AskUserQuestionOptionSchema).max(32).optional(),
  multiSelect: z.boolean().optional(),
});
export type AskUserQuestionItem = z.infer<typeof AskUserQuestionItemSchema>;

export const QuestionAskedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  sessionId: IdentifierSchema,
  questions: z.array(AskUserQuestionItemSchema).min(1).max(16),
  expiresAt: TimestampSchema.optional(),
});
export type QuestionAskedPayload = z.infer<typeof QuestionAskedPayloadSchema>;

export const QuestionResolvedPayloadSchema = StrictObject({
  id: IdentifierSchema,
  sessionId: IdentifierSchema,
});
export type QuestionResolvedPayload = z.infer<typeof QuestionResolvedPayloadSchema>;

export const EventEnvelopeSchema = z.discriminatedUnion("type", [
  EventEnvelope("connection.ready", ConnectionReadyPayloadSchema),
  EventEnvelope("session.snapshot", SessionSnapshotPayloadSchema),
  EventEnvelope("session.created", SessionCreatedPayloadSchema),
  EventEnvelope("user.message.accepted", ChatMessagePayloadSchema),
  EventEnvelope("assistant.message.delta", AssistantMessageDeltaPayloadSchema),
  EventEnvelope("assistant.message.completed", ChatMessagePayloadSchema),
  EventEnvelope("tool.started", ToolStartedPayloadSchema),
  EventEnvelope("tool.completed", ToolCompletedPayloadSchema),
  EventEnvelope("approval.requested", ApprovalRequestedPayloadSchema),
  EventEnvelope("approval.resolved", ApprovalResolvedPayloadSchema),
  EventEnvelope("turn.state.changed", TurnStateChangedPayloadSchema),
  EventEnvelope("model.catalog", ModelCatalogPayloadSchema),
  EventEnvelope("usage.updated", UsageUpdatedPayloadSchema),
  EventEnvelope("permission.updated", PermissionUpdatedPayloadSchema),
  EventEnvelope("session.metadata.updated", SessionMetadataUpdatedPayloadSchema),
  EventEnvelope("command.result", CommandResultPayloadSchema),
  EventEnvelope("attachment.uploaded", AttachmentUploadedPayloadSchema),
  EventEnvelope("assistant.reasoning", AssistantReasoningPayloadSchema),
  EventEnvelope("question.asked", QuestionAskedPayloadSchema),
  EventEnvelope("question.resolved", QuestionResolvedPayloadSchema),
  EventEnvelope("protocol.error", ProtocolErrorPayloadSchema),
]);
export type EventEnvelope = z.infer<typeof EventEnvelopeSchema>;
export type EventType = EventEnvelope["type"];

const CommandFields = {
  version: z.literal(PROTOCOL_VERSION),
  requestId: IdentifierSchema,
  machineId: IdentifierSchema,
  deviceId: IdentifierSchema,
  sessionId: IdentifierSchema.optional(),
  timestamp: TimestampSchema,
};

const CommandEnvelope = <T extends z.ZodTypeAny, K extends string>(
  type: K,
  payload: T,
) => StrictObject({ ...CommandFields, type: z.literal(type), payload });

// Keep an index signature here for source-compatible callers that construct a
// command union by hand (older clients send an empty object). The bridge still
// reads only the declared `includeArchived` field.
export const SessionListPayloadSchema = z.object({
  includeArchived: z.boolean().optional(),
}).catchall(z.unknown());
export const SessionCreatePayloadSchema = StrictObject({
  title: z.string().min(1).max(512).optional(),
  workingDirectory: z.string().min(1).optional(),
  workspaceId: IdentifierSchema.optional(),
  agentPreset: z.string().min(1).max(256).optional(),
  model: ModelSelectionSchema.optional(),
  initialPrompt: z.string().max(100_000).optional(),
});
export const SessionOpenPayloadSchema = StrictObject({ sessionId: IdentifierSchema });
export const ConnectionResumePayloadSchema = StrictObject({ lastSequence: z.number().int().nonnegative() });
/**
 * A reference to a file that was already uploaded. The Harness resolves these
 * receipt ids out of the prompt content and binds them to the message, which is
 * why they must travel inside `content` rather than beside it.
 */
export const PromptFilePartSchema = StrictObject({
  type: z.literal("file"),
  receiptId: IdentifierSchema,
});

export const PromptSendPayloadSchema = StrictObject({
  text: z.string().max(100_000).optional(),
  /**
   * Files to attach. Declared here because this object is strict: while it was
   * undeclared, a prompt carrying an attachment was rejected whole by the Relay
   * — taking the typed text with it, so the file arrived and the message did not.
   */
  attachments: z.array(PromptFilePartSchema).max(16).optional(),
  content: z.array(z.union([
    PromptFilePartSchema,
    StrictObject({ type: z.literal("text"), text: z.string().max(100_000) }),
    StrictObject({
      type: z.literal("image"),
      mediaType: z.enum(["image/png", "image/jpeg", "image/webp", "image/gif"]),
      data: z.string().min(1),
      name: z.string().min(1).max(512).optional(),
    }),
    StrictObject({ type: z.literal("file"), receiptId: IdentifierSchema }),
  ])).max(64).optional(),
  mode: z.enum(["queue", "steer"]).optional(),
  clientTimeZone: z.string().max(128).optional(),
}).superRefine((value, context) => {
  const hasText = typeof value.text === "string" && value.text.trim().length > 0;
  const hasContent = value.content?.some((part) => part.type !== "text" || part.text.trim().length > 0) ?? false;
  if (!hasText && !hasContent) context.addIssue({ code: z.ZodIssueCode.custom, message: "prompt requires text or an attachment" });
});
export const TurnCancelPayloadSchema = StrictObject({});
export const ApprovalDecidePayloadSchema = StrictObject({
  approvalId: IdentifierSchema,
  allow: z.boolean(),
});
export const DeviceRevokePayloadSchema = StrictObject({ targetDeviceId: IdentifierSchema });
export const SessionArchivePayloadSchema = StrictObject({ archived: z.boolean() });
export const SessionModelPayloadSchema = ModelSelectionSchema;
export const CommandExecutePayloadSchema = StrictObject({
  line: z.string().min(1).max(20_000),
  attachments: PromptSendPayloadSchema.shape.content.optional(),
});
export const PermissionSetPayloadSchema = StrictObject({
  mode: z.enum(["ask", "never", "read-only", "workspace-write", "danger-full-access"]),
});
export const AttachmentUploadPayloadSchema = StrictObject({
  name: z.string().min(1).max(512),
  data: z.string().min(1),
});
/** One answered question. `selected` carries option labels verbatim. */
export const QuestionAnswerItemSchema = StrictObject({
  id: IdentifierSchema,
  selected: z.array(z.string().min(1).max(512)).max(32),
  custom: z.string().max(4_000).optional(),
});
export type QuestionAnswerItem = z.infer<typeof QuestionAnswerItemSchema>;

export const QuestionAnswerPayloadSchema = StrictObject({
  questionId: IdentifierSchema,
  answers: z.array(QuestionAnswerItemSchema).min(1).max(16),
});

export type SessionListPayload = z.infer<typeof SessionListPayloadSchema>;
export type SessionCreatePayload = z.infer<typeof SessionCreatePayloadSchema>;
export type SessionOpenPayload = z.infer<typeof SessionOpenPayloadSchema>;
export type PromptSendPayload = z.infer<typeof PromptSendPayloadSchema>;
export type TurnCancelPayload = z.infer<typeof TurnCancelPayloadSchema>;
export type ApprovalDecidePayload = z.infer<typeof ApprovalDecidePayloadSchema>;
export type DeviceRevokePayload = z.infer<typeof DeviceRevokePayloadSchema>;
export type SessionArchivePayload = z.infer<typeof SessionArchivePayloadSchema>;
export type SessionModelPayload = z.infer<typeof SessionModelPayloadSchema>;
export type CommandExecutePayload = z.infer<typeof CommandExecutePayloadSchema>;
export type PermissionSetPayload = z.infer<typeof PermissionSetPayloadSchema>;
export type AttachmentUploadPayload = z.infer<typeof AttachmentUploadPayloadSchema>;
export type QuestionAnswerPayload = z.infer<typeof QuestionAnswerPayloadSchema>;

export const CommandEnvelopeSchema = z.discriminatedUnion("type", [
  CommandEnvelope("connection.resume", ConnectionResumePayloadSchema),
  CommandEnvelope("session.list", SessionListPayloadSchema),
  CommandEnvelope("session.create", SessionCreatePayloadSchema),
  CommandEnvelope("session.open", SessionOpenPayloadSchema),
  CommandEnvelope("prompt.send", PromptSendPayloadSchema),
  CommandEnvelope("turn.cancel", TurnCancelPayloadSchema),
  CommandEnvelope("approval.decide", ApprovalDecidePayloadSchema),
  CommandEnvelope("session.archive", SessionArchivePayloadSchema),
  CommandEnvelope("session.model", SessionModelPayloadSchema),
  CommandEnvelope("model.catalog", StrictObject({})),
  CommandEnvelope("command.execute", CommandExecutePayloadSchema),
  CommandEnvelope("permission.set", PermissionSetPayloadSchema),
  CommandEnvelope("attachment.upload", AttachmentUploadPayloadSchema),
  CommandEnvelope("question.answer", QuestionAnswerPayloadSchema),
  CommandEnvelope("device.revoke", DeviceRevokePayloadSchema),
]);
export type CommandEnvelope = z.infer<typeof CommandEnvelopeSchema>;
export type CommandType = CommandEnvelope["type"];

export const PairingRequestSchema = StrictObject({
  version: z.literal(PROTOCOL_VERSION),
  type: z.literal("pairing.request"),
  requestId: IdentifierSchema,
  deviceName: z.string().min(1).max(256),
  pairingCode: z.string().regex(/^\d{6}$/, "pairing code must be six digits"),
  timestamp: TimestampSchema,
});
export type PairingRequest = z.infer<typeof PairingRequestSchema>;

export const PairingResponseSchema = StrictObject({
  version: z.literal(PROTOCOL_VERSION),
  type: z.literal("pairing.response"),
  requestId: IdentifierSchema,
  machineId: IdentifierSchema,
  deviceId: IdentifierSchema,
  status: z.enum(["accepted", "rejected"]),
  deviceToken: z.string().min(1).max(16_384).optional(),
  expiresAt: TimestampSchema.optional(),
  error: z.string().max(4_000).optional(),
}).superRefine((value, context) => {
  if (value.status === "accepted" && !value.deviceToken) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "accepted pairing responses require a token" });
  }
  if (value.status === "rejected" && !value.error) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["error"], message: "rejected pairing responses require an error" });
  }
});
export type PairingResponse = z.infer<typeof PairingResponseSchema>;

export const WireMessageSchema = z.union([
  EventEnvelopeSchema,
  CommandEnvelopeSchema,
  PairingRequestSchema,
  PairingResponseSchema,
]);
export type WireMessage = z.infer<typeof WireMessageSchema>;

/**
 * Messages carried by the public Relay.  Unlike WireMessage, these envelopes
 * are deliberately small: the Relay authenticates the sender and only routes
 * a WireMessage to peers which belong to the same machine.
 */
export const RelayRoleSchema = z.enum(["machine", "device"]);
export type RelayRole = z.infer<typeof RelayRoleSchema>;

export const RelayReadyMessageSchema = StrictObject({
  type: z.literal("relay.ready"),
  machineId: IdentifierSchema,
  role: RelayRoleSchema,
  connectionId: IdentifierSchema,
  serverTime: TimestampSchema,
});
export type RelayReadyMessage = z.infer<typeof RelayReadyMessageSchema>;

export const RelayPresenceMessageSchema = StrictObject({
  type: z.literal("relay.presence"),
  machineId: IdentifierSchema,
  role: RelayRoleSchema,
  online: z.boolean(),
  deviceId: IdentifierSchema.optional(),
  serverTime: TimestampSchema,
});
export type RelayPresenceMessage = z.infer<typeof RelayPresenceMessageSchema>;

export const RelayPayloadMessageSchema = StrictObject({
  type: z.literal("relay.payload"),
  machineId: IdentifierSchema,
  messageId: IdentifierSchema,
  sender: RelayRoleSchema,
  targetDeviceId: IdentifierSchema.optional(),
  body: WireMessageSchema,
});
export type RelayPayloadMessage = z.infer<typeof RelayPayloadMessageSchema>;

export const RelayErrorMessageSchema = StrictObject({
  type: z.literal("relay.error"),
  code: IdentifierSchema,
  message: z.string().min(1).max(4_000),
  machineId: IdentifierSchema.optional(),
  messageId: IdentifierSchema.optional(),
});
export type RelayErrorMessage = z.infer<typeof RelayErrorMessageSchema>;

export const RelayMessageSchema = z.discriminatedUnion("type", [
  RelayReadyMessageSchema,
  RelayPresenceMessageSchema,
  RelayPayloadMessageSchema,
  RelayErrorMessageSchema,
]);
export type RelayMessage = z.infer<typeof RelayMessageSchema>;

export const parseRelayMessage = (value: unknown): RelayMessage => RelayMessageSchema.parse(value);

/** Parse helpers keep callers from accidentally accepting a different protocol version. */
export const parseEvent = (value: unknown): EventEnvelope => EventEnvelopeSchema.parse(value);
export const parseCommand = (value: unknown): CommandEnvelope => CommandEnvelopeSchema.parse(value);
export const parsePairingRequest = (value: unknown): PairingRequest => PairingRequestSchema.parse(value);
export const parsePairingResponse = (value: unknown): PairingResponse => PairingResponseSchema.parse(value);
export const parseWireMessage = (value: unknown): WireMessage => WireMessageSchema.parse(value);

/** Sequence values are positive and strictly increasing for a given stream. */
export const validateSequence = (previousSequence: number | undefined, sequence: unknown): sequence is number => {
  const parsed = SequenceSchema.safeParse(sequence);
  return parsed.success && (previousSequence === undefined || parsed.data > previousSequence);
};

export const assertSequence = (previousSequence: number | undefined, sequence: unknown): number => {
  if (!validateSequence(previousSequence, sequence)) {
    throw new Error("sequence must be a positive integer greater than the previous sequence");
  }
  return sequence;
};

/**
 * QR pairing payload, shared by the Mac connector (producer) and the native
 * client (consumer) so the two cannot drift apart.
 *
 * The iPhone derives both its HTTPS pairing call and its WSS session socket
 * from a single base address, so the encoded relay always uses the https://
 * form even though the connector stores wss://.
 */
export const PAIRING_LINK_SCHEME = "dshanywhere";

/**
 * A pairing link carries exactly one credential: the long-lived `secret`, or a
 * single-use `code` minted by the machine. Modelling it as a union rather than
 * two optional fields means a caller cannot build a link with neither, and
 * existing links keep parsing unchanged.
 */
export type PairingLinkPayload =
  | { readonly relay: string; readonly machineId: string; readonly pairingSecret: string }
  | { readonly relay: string; readonly machineId: string; readonly pairingCode: string };

/** Rewrites a stored wss:// (or ws://) relay address into its HTTPS form. */
export const relayHTTPSURL = (value: string): string => {
  const url = new URL(value);
  if (url.protocol === "wss:") url.protocol = "https:";
  else if (url.protocol === "ws:") url.protocol = "http:";
  else if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("relay must be an absolute HTTPS URL");
  }
  return url.toString().replace(/\/+$/, "");
};

export const pairingLink = (payload: PairingLinkPayload): string => {
  const url = new URL(`${PAIRING_LINK_SCHEME}://pair`);
  url.searchParams.set("relay", relayHTTPSURL(payload.relay));
  url.searchParams.set("machineId", payload.machineId);
  if ("pairingSecret" in payload) url.searchParams.set("secret", payload.pairingSecret);
  else url.searchParams.set("code", payload.pairingCode);
  return url.toString();
};

/** Returns undefined rather than throwing so a scanner can reject foreign codes. */
export const parsePairingLink = (value: string): PairingLinkPayload | undefined => {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    return undefined;
  }
  if (url.protocol !== `${PAIRING_LINK_SCHEME}:`) return undefined;
  const relay = url.searchParams.get("relay");
  const machineId = url.searchParams.get("machineId");
  const pairingSecret = url.searchParams.get("secret");
  const pairingCode = url.searchParams.get("code");
  if (relay === null || machineId === null || machineId.trim() === "") return undefined;
  const secret = pairingSecret?.trim() ?? "";
  const code = pairingCode?.trim().toUpperCase() ?? "";
  if (secret === "" && code === "") return undefined;
  try {
    const resolvedRelay = relayHTTPSURL(relay);
    const resolvedMachineId = machineId.trim();
    // A link carrying both is ambiguous; the one-time code wins because it is
    // the narrower credential and what a freshly minted link carries.
    return code !== ""
      ? { relay: resolvedRelay, machineId: resolvedMachineId, pairingCode: code }
      : { relay: resolvedRelay, machineId: resolvedMachineId, pairingSecret: secret };
  } catch {
    return undefined;
  }
};
