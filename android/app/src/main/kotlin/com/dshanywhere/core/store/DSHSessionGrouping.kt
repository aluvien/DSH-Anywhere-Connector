package com.dshanywhere.core.store

import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHSessionSummary
import kotlinx.serialization.Serializable

/** How the sessions list arranges what it shows. */
enum class DSHSessionGrouping(val key: String) {
    ByWorkspace("byWorkspace"),
    Flat("flat"),
    ;

    val title: String
        get() = when (this) {
            ByWorkspace -> DSHLocalization.string("By workspace")
            Flat -> DSHLocalization.string("Flat list")
        }
}

/** One section of the sessions list. */
data class DSHSessionGroup(
    val id: String,
    val title: String,
    val sessions: List<DSHSessionSummary>,
    /**
     * True for the bucket holding sessions that belong to no workspace, which
     * is sorted last and never merged with a real workspace of the same name.
     */
    val isUnfiled: Boolean = false,
)

/** A workspace the user can start a session in. */
@Serializable
data class DSHWorkspaceOption(
    val id: String,
    val name: String = "",
    val title: String? = null,
    val path: String? = null,
) {
    val resolvedName: String get() = title?.takeIf { it.isNotBlank() } ?: name
}

@Serializable
data class DSHDirectoryEntry(val name: String, val path: String)

@Serializable
data class DSHDirectoryListing(
    val path: String,
    val parentPath: String? = null,
    val directories: List<DSHDirectoryEntry> = emptyList(),
)

@Serializable
data class DSHModeOption(val id: String, val name: String, val description: String? = null)

@Serializable
data class DSHModeCatalog(val defaultMode: String? = null, val modes: List<DSHModeOption> = emptyList())

const val FLAT_GROUP_ID = "__flat__"
const val UNFILED_GROUP_ID = "__unfiled__"
const val UNFILED_GROUP_TITLE = "Other"

/**
 * Workspaces offered when starting a session, derived from the sessions on
 * hand rather than a dedicated endpoint: the wire protocol has no
 * workspace-list message.
 */
fun List<DSHSessionSummary>.workspaceOptions(): List<DSHWorkspaceOption> {
    val seen = mutableSetOf<String>()
    return mapNotNull { session ->
        val id = session.workspaceId ?: return@mapNotNull null
        val name = session.workspaceName ?: return@mapNotNull null
        if (!seen.add(id)) return@mapNotNull null
        DSHWorkspaceOption(id = id, name = name)
    }.sortedBy { it.name.lowercase() }
}

/**
 * Sections the list should render, already filtered and sorted.
 *
 * Sessions outside every registered workspace are dropped rather than collected
 * into an "Other" bucket: that bucket was mostly sessions the user never
 * opened (delegated subagent runs have no workspace either), and the Harness
 * sidebar only lists registered workspaces.
 */
fun List<DSHSessionSummary>.groupedForList(
    grouping: DSHSessionGrouping,
    showArchived: Boolean,
): List<DSHSessionGroup> {
    val visible = filter { showArchived || it.archived != true }
        .filter { it.workspaceName != null }
    val recentFirst = visible.sortedByDescending { it.updatedAt }

    return when (grouping) {
        DSHSessionGrouping.Flat -> {
            if (recentFirst.isEmpty()) emptyList()
            else listOf(DSHSessionGroup(id = FLAT_GROUP_ID, title = "", sessions = recentFirst))
        }
        DSHSessionGrouping.ByWorkspace -> {
            // Group by the stable registry id when one is available. The
            // display title is mutable, so using it as an id made a project
            // rename look like a delete plus a new project.
            val buckets = visible.groupBy { it.workspaceId ?: it.workspaceName ?: UNFILED_GROUP_ID }
            buckets.keys
                .sortedWith { left, right ->
                    val leftTitle = buckets[left]?.firstOrNull()?.workspaceName ?: UNFILED_GROUP_TITLE
                    val rightTitle = buckets[right]?.firstOrNull()?.workspaceName ?: UNFILED_GROUP_TITLE
                    when {
                        left == UNFILED_GROUP_ID -> 1
                        right == UNFILED_GROUP_ID -> -1
                        else -> leftTitle.compareTo(rightTitle, ignoreCase = true)
                    }
                }
                .mapNotNull { key ->
                    val sessions = (buckets[key] ?: emptyList())
                        .sortedByDescending { it.updatedAt }
                    if (sessions.isEmpty()) return@mapNotNull null
                    val title = sessions.firstOrNull()?.workspaceName ?: UNFILED_GROUP_TITLE
                    val unfiled = key == UNFILED_GROUP_ID
                    DSHSessionGroup(
                        id = if (unfiled) UNFILED_GROUP_ID else key,
                        title = title,
                        sessions = sessions,
                        isUnfiled = unfiled,
                    )
                }
        }
    }
}
