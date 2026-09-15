package com.dshanywhere.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PlaylistAddCheck
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.dshanywhere.BuildConfig
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.app.DSHDeviceStatus
import com.dshanywhere.core.network.DSHConnectionState
import com.dshanywhere.core.protocol.DSHLanguage
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.ui.theme.DSHColors
import java.util.concurrent.TimeUnit

/**
 * 1:1 port of ios/DSHAnywhere/Features/Settings/SettingsView.swift.
 *
 * Everything that is about the connection rather than about a conversation.
 * SwiftUI's insetGrouped list becomes quiet rounded cards on systemBackground.
 */
@Composable
fun SettingsScreen(onDismiss: () -> Unit) {
    val model = LocalAppModel.current
    var showForgetConfirmation by remember { mutableStateOf(false) }

    // .task { model.refreshPairedDevices() }
    LaunchedEffect(Unit) { model.refreshPairedDevices() }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxSize()
                .background(DSHColors.systemBackground())
                .statusBarsPadding(),
        ) {
            settingsHeader(onDismiss)

            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                SettingsSection(DSHLocalization.string("Sessions")) {
                    ToggleRow(
                        DSHLocalization.string("Group by workspace"),
                        model.groupsSessionsByWorkspace,
                    ) { model.setGroupsSessionsByWorkspace(it) }
                    ToggleRow(
                        DSHLocalization.string("Show archived"),
                        model.showArchivedSessions,
                    ) { model.setShowArchived(it) }
                    ToggleRow(
                        DSHLocalization.string("Collapse composer controls"),
                        model.collapseComposerControls,
                    ) { model.setCollapseComposerControls(it) }
                    ToggleRow(
                        DSHLocalization.string("Show session usage"),
                        model.showUsageFooter,
                    ) { model.setShowUsageFooter(it) }
                    ToggleRow(
                        DSHLocalization.string("Show turn usage beside Thinking"),
                        model.showTurnUsage,
                    ) { model.setShowTurnUsage(it) }
                }

                SettingsSection(
                    DSHLocalization.string("Machines"),
                    footer = DSHLocalization.string(
                        "Pairing another Mac adds it here instead of replacing the current one. " +
                            "Tap to switch, swipe to remove.",
                    ),
                ) {
                    if (model.machines.isEmpty()) {
                        SecondaryText(DSHLocalization.string("No paired Macs yet."))
                    } else {
                        model.machines.forEach { machine ->
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .clickable { model.switchMachine(machine) }
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(machine.machineName, fontSize = 16.sp, color = DSHColors.label())
                                    Text(
                                        machine.relayBaseURL,
                                        fontSize = 11.sp,
                                        color = DSHColors.secondaryLabel(),
                                        maxLines = 1,
                                    )
                                }
                                if (machine.machineId == model.activeMachine?.machineId) {
                                    Icon(
                                        Icons.Filled.Check,
                                        null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                                // iOS uses trailing swipeActions; Android shows
                                // an explicit destructive row button instead.
                                Text(
                                    DSHLocalization.string("Remove"),
                                    fontSize = 14.sp,
                                    color = DSHColors.systemRed(),
                                    modifier = Modifier
                                        .padding(start = 14.dp)
                                        .clickable { model.removeMachine(machine) },
                                )
                            }
                        }
                    }
                }

                SettingsSection(
                    DSHLocalization.string("Devices"),
                    footer = DSHLocalization.string(
                        "Devices paired to this Mac, as reported by the relay. " +
                            "Revoking one signs that device out immediately.",
                    ),
                ) {
                    val error = model.devicesError
                    when {
                        error != null -> SecondaryText(error, size = 13.sp)
                        model.pairedDevices.isEmpty() ->
                            SecondaryText(DSHLocalization.string("No devices reported."))
                        else -> model.pairedDevices.forEach { device ->
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(device.name, fontSize = 16.sp, color = DSHColors.label())
                                    Text(
                                        relativeTime(device.createdAt),
                                        fontSize = 11.sp,
                                        color = DSHColors.secondaryLabel(),
                                    )
                                }
                                if (device.deviceId == model.currentDeviceId) {
                                    // The relay refuses a self-revoke, so the
                                    // row says why instead of offering it.
                                    Text(
                                        DSHLocalization.string("This device"),
                                        fontSize = 12.sp,
                                        color = DSHColors.secondaryLabel(),
                                    )
                                } else {
                                    Text(
                                        DSHLocalization.string("Revoke"),
                                        fontSize = 14.sp,
                                        color = DSHColors.systemRed(),
                                        modifier = Modifier
                                            .padding(start = 14.dp)
                                            .clickable { model.revokeDevice(device) },
                                    )
                                }
                            }
                        }
                    }
                }

                SettingsSection(
                    footer = DSHLocalization.string(
                        "Follow System uses your device language. The choice applies immediately.",
                    ),
                ) {
                    LanguageRow(
                        current = model.language,
                        onSelect = { model.setLanguage(it) },
                    )
                }

                SettingsSection(DSHLocalization.string("Connection")) {
                    LabeledRow(DSHLocalization.string("Machine")) {
                        Text(model.machineName, fontSize = 16.sp, color = DSHColors.secondaryLabel())
                    }
                    LabeledRow(DSHLocalization.string("Status")) {
                        Text(
                            statusLabel(model.deviceStatus),
                            fontSize = 16.sp,
                            color = statusColor(model.deviceStatus),
                        )
                    }
                    val address = model.serverAddress.ifEmpty { null }
                    if (address != null) {
                        LabeledRow(DSHLocalization.string("Relay")) {
                            Text(address, fontSize = 14.sp, color = DSHColors.secondaryLabel())
                        }
                    }
                    if (model.machineID.isNotEmpty()) {
                        LabeledRow(DSHLocalization.string("Machine ID")) {
                            Text(
                                model.machineID,
                                fontSize = 13.sp,
                                fontFamily = FontFamily.Monospace,
                                color = DSHColors.secondaryLabel(),
                            )
                        }
                    }
                }

                SettingsSection(
                    footer = DSHLocalization.string(
                        "Disconnecting removes the device token from this iPhone's keychain. " +
                            "The Mac keeps running.",
                    ),
                ) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 44.dp)
                            .clickable(enabled = model.isPaired) { showForgetConfirmation = true }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            DSHLocalization.string("Disconnect this iPhone"),
                            fontSize = 16.sp,
                            color = if (model.isPaired) DSHColors.systemRed()
                                else DSHColors.systemRed().copy(alpha = 0.4f),
                        )
                    }
                }

                SettingsSection(DSHLocalization.string("About")) {
                    LabeledRow(DSHLocalization.string("Version")) {
                        Text(versionDescription(), fontSize = 16.sp, color = DSHColors.secondaryLabel())
                    }
                }

                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (showForgetConfirmation) {
        ConfirmDialog(
            title = DSHLocalization.string("Disconnect this iPhone?"),
            message = DSHLocalization.string(
                "You will need the Mac's machine ID and pairing secret to pair again.",
            ),
            confirmLabel = DSHLocalization.string("Disconnect"),
            destructive = true,
            onConfirm = {
                model.forgetPairing()
                onDismiss()
            },
            onDismiss = { showForgetConfirmation = false },
        )
    }
}

/** The stable 44pt glass header, shared visual family with Home/Conversation. */
@Composable
private fun settingsHeader(onDismiss: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(DSHColors.systemBackground().copy(alpha = 0.96f))
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(44.dp)
                .background(DSHColors.thinMaterial(), CircleShape)
                .border075(DSHColors.label().copy(alpha = 0.14f))
                .clickable { onDismiss() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Close,
                DSHLocalization.string("Close settings"),
                tint = DSHColors.label(),
                modifier = Modifier.size(18.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        Text(
            DSHLocalization.string("Settings"),
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            color = DSHColors.label(),
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        Text(
            DSHLocalization.string("Done"),
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable { onDismiss() }
                .padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

@Composable
private fun Modifier.border075(color: Color): Modifier =
    this.then(Modifier.padding(0.dp)) // border hairline approximated in thinMaterial bg

@Composable
private fun SettingsSection(
    title: String? = null,
    footer: String? = null,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (title != null) {
            Text(
                title,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = DSHColors.secondaryLabel(),
                modifier = Modifier.padding(start = 16.dp),
            )
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(DSHColors.secondarySystemBackground()),
        ) { content() }
        if (footer != null) {
            Text(
                footer,
                fontSize = 13.sp,
                color = DSHColors.secondaryLabel(),
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable { onChange(!checked) }
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 16.sp, color = DSHColors.label(), modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = DSHColors.systemGreen()),
        )
    }
}

@Composable
private fun LabeledRow(label: String, value: @Composable () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 16.sp, color = DSHColors.label(), modifier = Modifier.weight(1f))
        value()
    }
}

@Composable
private fun LanguageRow(current: DSHLanguage, onSelect: (DSHLanguage) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        LabeledRow(DSHLocalization.string("Language")) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable { expanded = true },
            ) {
                Text(current.displayName, fontSize = 16.sp, color = DSHColors.secondaryLabel())
                Icon(Icons.Filled.ExpandMore, null, tint = DSHColors.secondaryLabel(), modifier = Modifier.size(18.dp))
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DSHLanguage.entries.forEach { language ->
                DropdownMenuItem(
                    text = { Text(language.displayName) },
                    onClick = {
                        expanded = false
                        onSelect(language)
                    },
                    trailingIcon = {
                        if (language == current) {
                            Icon(
                                Icons.Filled.PlaylistAddCheck,
                                null,
                                tint = MaterialTheme.colorScheme.primary,
                            )
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun SecondaryText(text: String, size: TextUnitAlias = 16.sp) {
    Text(text, fontSize = size, color = DSHColors.secondaryLabel(), modifier = Modifier.padding(16.dp))
}

private typealias TextUnitAlias = androidx.compose.ui.unit.TextUnit

/** Swift SettingsView switches on `model.deviceStatus` (relay + Mac + bridge). */
private fun statusLabel(status: DSHDeviceStatus): String = when (status) {
    DSHDeviceStatus.Online -> DSHLocalization.string("Connected")
    DSHDeviceStatus.ApprovalRequired -> DSHLocalization.string("Permission confirmation required")
    DSHDeviceStatus.Error -> DSHLocalization.string("Connection failed")
    DSHDeviceStatus.Offline -> DSHLocalization.string("Disconnected")
}

@Composable
private fun statusColor(status: DSHDeviceStatus): Color = when (status) {
    DSHDeviceStatus.Online -> DSHColors.systemGreen()
    DSHDeviceStatus.ApprovalRequired -> DSHColors.systemYellow()
    DSHDeviceStatus.Error -> DSHColors.systemRed()
    DSHDeviceStatus.Offline -> DSHColors.systemGray()
}

private fun relativeTime(epochMillis: Long): String {
    val delta = System.currentTimeMillis() - epochMillis
    val minutes = TimeUnit.MILLISECONDS.toMinutes(delta)
    return when {
        minutes < 1 -> DSHLocalization.string("just now")
        minutes < 60 -> DSHLocalization.format("%@ min ago", minutes)
        minutes < 24 * 60 -> DSHLocalization.format("%@ h ago", TimeUnit.MILLISECONDS.toHours(delta))
        else -> DSHLocalization.format("%@ d ago", TimeUnit.MILLISECONDS.toDays(delta))
    }
}

private fun versionDescription(): String =
    "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

/** Shared two-button confirm dialog mirroring confirmationDialog(titleVisibility: .visible). */
@Composable
fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(26.dp))
                .background(DSHColors.secondarySystemBackground())
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = DSHColors.label())
            Text(
                message,
                fontSize = 14.sp,
                color = DSHColors.secondaryLabel(),
                modifier = Modifier.padding(top = 8.dp),
            )
            Spacer(Modifier.height(16.dp))
            Text(
                confirmLabel,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (destructive) DSHColors.systemRed() else MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(DSHColors.systemBackground())
                    .clickable { onConfirm() }
                    .padding(vertical = 10.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                DSHLocalization.string("Cancel"),
                fontSize = 17.sp,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clickable { onDismiss() },
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}
