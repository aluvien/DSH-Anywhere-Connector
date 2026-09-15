# Android Port Spec (agent contract)

Rules for porting the SwiftUI client in `ios/` (READ-ONLY reference — never
modify anything under `ios/` or under `android/app/src/main/kotlin/com/dshanywhere/{core,app}/`
or `MainActivity.kt`) to Jetpack Compose in `android/app/src/main/kotlin/com/dshanywhere/features/`.

## Fidelity requirements

- Reproduce layout 1:1: paddings, font sizes (`.font(.system(size: x))` → `fontSize = x.sp`),
  weights, corner radii, spacing, ordering. If a SwiftUI construct has no Compose
  equivalent, pick the closest behaviour and leave a `// SwiftUI: …` comment noting it.
- Colors come from `com.dshanywhere.ui.theme.DSHColors` (`systemBackground()`,
  `secondarySystemBackground()`, `label()`, `secondaryLabel()`, `separator()`,
  `systemBlue()`, `systemGreen()`, `systemRed()`, `systemOrange()`, `systemGray()…6`,
  `thinMaterial()`, brand constants `greenStart/greenEnd/purpleStart/purpleEnd/
  claudeOrange/claudeBackdrop`). If a view uses a color not in the palette, define it
  as a private composable val in YOUR file with light/dark values from iOS semantics.
- Every user-facing string wraps in `DSHLocalization.string("English literal")`, with
  the literal taken VERBATIM from the SwiftUI code (the English literal IS the
  localization key; zh-Hans comes from the generated map). `DSHLocalization.format(key, …)`
  replaces `%@` placeholders. Chinese literals inside iOS code (e.g. `重命名项目`, `新会话`,
  `PTC 模式`) stay as-is, unwrapped.
- SF Symbols → `androidx.compose.material.icons.Icons.*` closest match, comment the
  original symbol name.
- `.ultraThinMaterial` / `.thinMaterial` → translucent `DSHColors.thinMaterial()`
  background (no blur below API 31; acceptable).
- Haptics/animations: use `spring()` with similar stiffness; skip haptics.

## Core API you consume (already implemented — do not edit)

`com.dshanywhere.LocalAppModel` — `@Composable fun localModel(): DSHAppModel` via
`androidx.compose.runtime.compositionLocalOf`; read with `val model = LocalAppModel.current`.

`DSHAppModel` (com.dshanywhere.app), snapshot-observed properties:
`state, isPaired, isPairing, machineID, pairingSecret, serverAddress, machineName,
selectedSessionID, draft, showArchivedSessions, showUsageFooter, showTurnUsage,
collapseComposerControls, groupsSessionsByWorkspace, collapsedSessionGroups,
workspaceAliases, hiddenWorkspaceIDs, hiddenMessageKeys, language, errorMessage,
machines, pairedDevices, devicesError`

Methods: `messagesFor(id) toolsFor(id) transcriptEntriesFor(id) modelChangesFor(id)
turnStateFor(id) usageFor(id) permissionModeFor(id) commandResultsFor(id)
attachmentsFor(id) hideMessage(msgID, sessionID) discardAttachment(id, sessionID)
attachmentData(DSHMessageAttachment) pair() connect() disconnect() forgetPairing()
switchMachine(DSHRemoteProfile) removeMachine(profile) refreshPairedDevices()
revokeDevice(DSHRelayDevice) createSession(...) refreshSessions(includeArchived: Boolean? = null)
sendModelCatalog() setShowArchived(Boolean) setLanguage(DSHLanguage)
setGroupsSessionsByWorkspace(Boolean) setShowUsageFooter setShowTurnUsage
setCollapseComposerControls isGroupCollapsed(id) setGroup(id, collapsed)
workspaceDisplayNameFor(id, fallback) renameWorkspace(id, name) deleteWorkspace(group)
archive(summary, archived=true) sendPrompt(text, sessionID) sendPrompt(text,
attachments, messageAttachments, sessionID) selectModel(selection, sessionID)
reasoningConfiguration(sessionID) setPermission(mode, sessionID) executeCommand(line, sessionID)
uploadAttachment(name, data, sessionID) suspend uploadAttachmentAndWait(name, data, sessionID): String
cancelTurn(sessionID) decide(approval, allow) answer(request, answers) shortModelName(sessionID)
modelDisplayName(sessionID) modelLabel(selection, compact) modeLabel(sessionID)`
computed: `activeMachine currentDeviceId workspaces sessions hasLoadedSessions
modelCatalog pendingApprovals pendingQuestions connectionState sessionGrouping`

Types: `DSHStagedAttachment(name: String, data: ByteArray, isImage: Boolean)`,
`DSHReasoningConfiguration`, protocol models in `com.dshanywhere.core.protocol`
(`DSHTranscriptEntry` sealed: Turn(block)/Tool/Command/ModelChange; `DSHTranscriptBlock`
has `messages/visibleMessages/reasoning/isUserTurn`; `DSHMarkdown.blocks(text)`;
`DSHPairingLink.parse(url)`, `DSHPairingCredential.detect(raw)` incl. `CODE_ALPHABET`;
`DSHQuestionAnswer(id, selected, custom)`), store grouping in `com.dshanywhere.core.store`
(`DSHSessionGroup`, `DSHSessionGrouping`, `groupedForList(grouping, showArchived)`,
`workspaceOptions()`, `FLAT_GROUP_ID/UNFILED_GROUP_ID/UNFILED_GROUP_TITLE`).

`connectionState` is `DSHConnectionState` sealed: `Connected / Connecting /
Reconnecting(attempt) / Failed(message) / Disconnected`.

Navigation (implemented in MainActivity; your screens plug into it):
- `SessionListScreen(onOpenSession: (String) -> Unit)` — home; also owns the
  settings sheet + new-session full-sheet + rename/delete dialogs, and must
  `LaunchedEffect(model.selectedSessionID)` → when set, call `onOpenSession(id)`
  (programmatic navigation after `session.created`).
- `ConversationScreen(sessionID: String)` — detail; back arrow pops the route.
- `PairingScreen()` — unpaired root; no nav params.
- `SettingsScreen(onDismiss: () -> Unit)` (in features/settings) — presented by
  SessionListScreen as a ModalBottomSheet/dialog; render the iOS NavigationStack sheet.

## Practical conversions

- `TextField(text = binding)` → `BasicTextField` / M3 `TextField` bound to
  `model.xxx` state (these are `by mutableStateOf`, so `model.serverAddress = …` works).
- Photos picker: `rememberLauncherForActivityResult(ActivityResultContracts.GetContent())`
  or `OpenMultipleDocuments`; downsample images with `BitmapFactory.Options.inSampleSize`
  to ≤ 2048px, compress JPEG q≈82 → `DSHStagedAttachment`.
- QR scanning: CameraX (`PreviewView` in AndroidView) + ML Kit barcode scanning
  (`barcode-scanning` dep present); runtime CAMERA permission via
  `rememberLauncherForActivityResult(RequestPermission())`.
- Context menus (`.contextMenu`): `CombinedClickable(onLongClick=…)` → `DropdownMenu`.
- `.sheet`/`.fullScreenCover` → `ModalBottomSheet` or `Dialog(usePlatformDefaultWidth=false)`
  matching the visual style; the new-session sheet in iOS is a full sheet — use a
  full-height `Dialog`.
- `ScrollView` → `verticalScroll(rememberScrollState())`; `LazyVStack` → `LazyColumn`.
- For streaming lists replicate SwiftUI `ScrollViewReader`-style auto-scroll:
  stay pinned to bottom while the user is at bottom, stop when they scroll up.
- Do NOT run gradle (the orchestrator compiles). Keep each screen self-contained in
  its own files; helpers shared by 2+ screens go into `ui/common/` ONLY if you create
  them there with distinct file names (prefix `DSH`+screen name to avoid collisions).

## Definition of done per screen

1. Replaces the stub file(s) you own.
2. Compiles against the core API listed above (no invented members — if something
   is missing, implement a local TODO workaround and list it in your final report).
3. All interactive controls wired to the model (no dead buttons except genuinely
   iOS-only ones, which you note).
4. Final report: files written, decisions taken, unresolved needs.

## Addendum (discovered during integration)

- Material icons: the `automirrored` package holds only a handful of mirrored
  glyphs (Send, ArrowBack, Feedback, List, ChatBubble, Login/Logout…).
  Everything else (AttachFile, SlashCommand, Code, Description, Settings…) is
  in `androidx.compose.material.icons.filled.*`.
- Popup/dropdown offsets take `DpOffset`, not `IntOffset`.
- When two names would collide, remember `var x by mutableStateOf(...)` already
  synthesizes `setX`; a Swift-style helper `setX(value)` needs
  `@set:JvmName` or a different Kotlin name (the core uses JvmName, callers are
  unaffected).

## Addendum 2 — connection status & unread (synced from iOS at 01:55)

The iOS client distinguishes three independent things; Android mirrors it:

| State | Meaning |
|---|---|
| `state.transportState` | phone ↔ relay socket (`Connecting/Connected/Reconnecting/Failed/Disconnected`) |
| `state.machineOnline` | Mac Connector presence reported by the relay (`machine.presence`) |
| `state.bridgeReachable` | `null` = unknown, `true` = Harness answered, `false` = bridge request failed |

- `DSHDeviceStatus` (`Offline/Error/Online/ApprovalRequired`) is derived exactly like
  Swift's `model.deviceStatus`; every status surface (home dot, conversation status
  bar, settings row, new-session machine row) switches on it, not on `connectionState`.
- Control events (`transport.state`, `machine.presence`) are yielded by the socket
  with `sequence = 0` and handled by the reducer **before** the replay-window gate,
  so they neither consume nor disturb `lastSequence`.
- Unread: `lastReadSessionTimestamps` (keyed `machineID\u001FSessionID`) +
  `unreadBaseline`; rows highlight when `running || isSessionUnread`;
  `markSessionRead` fires on conversation open (and its messages/updatedAt changes).

### Gotcha this port cost us

`encodeDefaults = false` silently drops any property whose value equals its
declaration-site default. `DSHRelayPayloadMessage.type` had `= "relay.payload"`,
so the relay received payload messages **without** `type` and rejected every
command (`invalid_message`) — the client connected and then never saw an event.
Swift always encodes non-optional properties, so this only bites Kotlin. Rule:
never give a wire-required field a declaration-site default.

## Addendum 3 — ConversationView sync (iOS edit at 03:12)

Diffed the grown `ConversationView.swift` (1671 → 1783 lines) against the Android
port and closed the real gaps:

1. **Unread clearing while the conversation is open.** SwiftUI fires
   `markSessionRead` from `.onChange(of: messages.count)` and
   `.onChange(of: session?.updatedAt)`, not just from `.task(id:)`. Android now
   has both `LaunchedEffect`s next to the task hook.
2. **`isRunning` is strictly `turnState == "running"`.** The port had widened it
   to `!= "idle"` (my earlier prompt's wording); restored to iOS semantics so the
   stop affordance only appears for a running turn.

Already at parity (verified, no change needed): header menu with
Select model / Permission / Refresh session info / Archive session,
`refreshSession()` + 1.2s `didRefresh` feedback, `archiveSession()` with the
`emptySession` fallback, photo-failure message text, 2048px/JPEG-0.82
downsampling off the main thread, keyboard dismissal on drag, jump-to-latest
overlay, and the bottom-anchor auto-follow.

iOS-only by design (no Android port): `DSHInteractivePopGestureEnabler`
(re-enables UIKit's edge-swipe pop because the custom header hides the nav bar —
Android already routes the system back gesture), `.scrollBounceBehavior(.always)`
and `.defaultScrollAnchor(.bottom)` (Compose has no equivalents; initial
scroll-to-bottom is handled by the existing pinning effect).
