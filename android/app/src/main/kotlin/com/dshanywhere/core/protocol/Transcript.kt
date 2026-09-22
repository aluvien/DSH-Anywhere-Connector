package com.dshanywhere.core.protocol

/**
 * One row of the transcript, in the order the events actually arrived.
 * Mirrors `DSHTranscriptEntry` in DSHProtocol.swift.
 */
private sealed interface Arrival {
    val sequence: Long
}

private data class Msg(val message: DSHChatMessage, override val sequence: Long) : Arrival
private data class ToolA(val tool: DSHToolActivity, override val sequence: Long) : Arrival
private data class CmdA(val result: DSHCommandResult, override val sequence: Long) : Arrival
private data class ModelA(val notice: DSHModelChangeNotice, override val sequence: Long) : Arrival

sealed interface DSHTranscriptEntry {
    val id: String
    val sequence: Long

    data class Turn(val block: DSHTranscriptBlock) : DSHTranscriptEntry {
        override val id: String get() = "turn-${block.id}"
        override val sequence: Long get() = block.sequence
    }

    data class Tool(val tool: DSHToolActivity) : DSHTranscriptEntry {
        override val id: String get() = "tool-${tool.id}"
        override val sequence: Long get() = tool.sequence ?: 0
    }

    data class Command(val result: DSHCommandResult) : DSHTranscriptEntry {
        override val id: String get() = "command-${result.id}"
        override val sequence: Long get() = result.sequence ?: 0
    }

    data class ModelChange(val notice: DSHModelChangeNotice) : DSHTranscriptEntry {
        override val id: String get() = "model-change-${notice.id}"
        override val sequence: Long get() = notice.sequence
    }
}

/**
 * One row of the transcript: a single user message, or the consecutive
 * assistant messages that belong to one turn.
 *
 * Grouping exists so the reply is what you read: every assistant message of a
 * turn renders as an answer, and all of that turn's chain-of-thought collapses
 * into one disclosure placed after the answers rather than one per message.
 */
data class DSHTranscriptBlock(
    val id: String,
    val messages: List<DSHChatMessage>,
    /** Present only on the first assistant block of one user task. */
    val taskTimeline: DSHTaskTimeline? = null,
) {
    val isUserTurn: Boolean get() = messages.firstOrNull()?.role == DSHMessageRole.user

    /** Sequence of the first message, used to interleave with tool calls. */
    val sequence: Long get() = messages.firstOrNull()?.sequence ?: 0

    /**
     * Answers in order. An empty markdown only happens when reasoning arrived
     * before the streamed text, so it must not produce an empty bubble. A user
     * message can legitimately have no text when it contains only an
     * image/file; keep those rows so the attachment thumbnail is visible.
     */
    val visibleMessages: List<DSHChatMessage>
        get() = messages.filter { it.markdown.isNotEmpty() || it.attachments.isNotEmpty() }

    /** Every reasoning fragment this turn produced, in arrival order. */
    val reasoning: String
        get() = messages.mapNotNull { it.reasoning }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n\n")
}

data class DSHTaskTimeline(
    val promptID: String?,
    val startedAt: Long?,
    val messages: List<DSHChatMessage>,
    val tools: List<DSHToolActivity>,
) {
    val reasoning: String
        get() = messages.mapNotNull { it.reasoning }.filter { it.isNotBlank() }.joinToString("\n\n")

    /** Returns seconds and whether it was estimated from output speed. */
    fun duration(now: Long? = null): Pair<Int, Boolean>? {
        val end = now ?: messages.mapNotNull { it.taskCompletedAt }.maxOrNull()
            ?: messages.mapNotNull { it.completedAt }.maxOrNull()
        if (startedAt != null && startedAt > 0 && end != null && end >= startedAt) {
            return (((end - startedAt) / 1_000L).toInt()) to false
        }
        val estimates = messages.mapNotNull { message ->
            val speed = message.usage?.tokensPerSecond
            val tokens = message.usage?.outputTokens
            if (speed != null && speed.isFinite() && speed > 0 &&
                tokens != null && tokens.isFinite() && tokens > 0) tokens / speed else null
        }
        if (estimates.isEmpty()) return null
        val total = estimates.sum()
        if (!total.isFinite()) return null
        return kotlin.math.max(1, kotlin.math.round(total).toInt()) to true
    }
}

/**
 * Messages and tool calls interleaved by arrival sequence.
 *
 * Rendering them as two separate runs put every tool call after every message,
 * which is not the order the turn happened in: in reality the model writes,
 * calls a tool, writes again, and so on.
 */
fun List<DSHChatMessage>.transcriptEntries(
    tools: List<DSHToolActivity>,
    commandResults: List<DSHCommandResult> = emptyList(),
    modelChanges: List<DSHModelChangeNotice> = emptyList(),
): List<DSHTranscriptEntry> {
    // Stable by construction: a tie keeps arrival order. Sorting on the
    // sequence alone is not enough, because state persisted before sequences
    // existed carries none, and any arbitrary tie-break (id order, say) would
    // scramble the whole transcript on upgrade.
    val ordered = mutableListOf<Arrival>()
    this.forEach { ordered.add(Msg(it, it.sequence ?: 0)) }
    tools.forEach { ordered.add(ToolA(it, it.sequence ?: 0)) }
    commandResults.forEach { ordered.add(CmdA(it, it.sequence ?: 0)) }
    modelChanges.forEach { ordered.add(ModelA(it, it.sequence)) }
    // Kotlin's sortBy is stable, preserving the manual arrival order on ties.
    ordered.sortBy { it.sequence }

    val entries = mutableListOf<DSHTranscriptEntry>()
    var run = mutableListOf<DSHChatMessage>()
    fun flushRun() {
        val first = run.firstOrNull() ?: return
        entries.add(DSHTranscriptEntry.Turn(DSHTranscriptBlock(id = first.id, messages = run.toList())))
        run = mutableListOf()
    }

    for (arrival in ordered) {
        when (arrival) {
            is Msg -> if (arrival.message.role == DSHMessageRole.assistant) {
                // Consecutive assistant messages belong to one turn.
                run.add(arrival.message)
            } else {
                // A user message stands alone and ends any assistant run.
                flushRun()
                entries.add(DSHTranscriptEntry.Turn(DSHTranscriptBlock(arrival.message.id, listOf(arrival.message))))
            }
            is ToolA -> {
                // Break the run here. Grouping blindly merged a whole turn's
                // messages into one block, which pushed every call made between
                // them to the end — the very clumping this ordering is for.
                flushRun()
                entries.add(DSHTranscriptEntry.Tool(arrival.tool))
            }
            is CmdA -> {
                // Command acknowledgements are transcript content too. Keep them
                // at the event's original sequence instead of rendering a second
                // array after all messages (which pinned every "Command
                // completed" card to the bottom of the conversation).
                flushRun()
                entries.add(DSHTranscriptEntry.Command(arrival.result))
            }
            is ModelA -> {
                flushRun()
                entries.add(DSHTranscriptEntry.ModelChange(arrival.notice))
            }
        }
    }
    flushRun()
    return entries
}

/** Adds one total timeline to the first visible assistant block of each task. */
fun List<DSHTranscriptEntry>.withTaskTimelines(): List<DSHTranscriptEntry> {
    val result = toMutableList()
    var prompt: DSHChatMessage? = null
    var assistantIndices = mutableListOf<Int>()
    var taskTools = mutableListOf<DSHToolActivity>()

    fun flush() {
        if (assistantIndices.isEmpty()) {
            taskTools.clear()
            return
        }
        val blocks = assistantIndices.mapNotNull { (result[it] as? DSHTranscriptEntry.Turn)?.block }
        val messages = blocks.flatMap { it.messages }
        val headerIndex = assistantIndices.firstOrNull {
            (result[it] as? DSHTranscriptEntry.Turn)?.block?.visibleMessages?.isNotEmpty() == true
        } ?: assistantIndices.first()
        val entry = result[headerIndex] as DSHTranscriptEntry.Turn
        result[headerIndex] = DSHTranscriptEntry.Turn(entry.block.copy(
            taskTimeline = DSHTaskTimeline(
                promptID = prompt?.id,
                startedAt = prompt?.timestamp ?: messages.firstOrNull()?.timestamp,
                messages = messages,
                tools = taskTools.toList(),
            ),
        ))
        assistantIndices = mutableListOf()
        taskTools = mutableListOf()
    }

    result.indices.forEach { index ->
        when (val entry = result[index]) {
            is DSHTranscriptEntry.Turn -> if (entry.block.isUserTurn) {
                flush()
                prompt = entry.block.messages.firstOrNull()
            } else assistantIndices += index
            is DSHTranscriptEntry.Tool -> taskTools += entry.tool
            else -> Unit
        }
    }
    flush()
    return result
}
