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
