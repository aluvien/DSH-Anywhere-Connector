package com.dshanywhere.features.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CropSquare
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.core.protocol.DSHApprovalRequest
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHQuestion
import com.dshanywhere.core.protocol.DSHQuestionAnswer
import com.dshanywhere.core.protocol.DSHQuestionOption
import com.dshanywhere.core.protocol.DSHQuestionRequest
import com.dshanywhere.ui.theme.DSHColors

/**
 * ApprovalCard.swift and QuestionCard.swift ports. These render the fixed
 * pending approval / question cards shown above the composer.
 */

// MARK: - Approval card

/** SwiftUI: `ApprovalCard`. */
@Composable
internal fun ApprovalCard(approval: DSHApprovalRequest, onDecision: (Boolean) -> Unit) {
    val orange = DSHColors.systemOrange()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // Color.orange.opacity(0.1) fill + .stroke(opacity 0.35) border, radius 14.
            .background(orange.copy(alpha = 0.1f), RoundedCornerShape(14.dp))
            .border(1.dp, orange.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(
                Icons.Filled.Warning, // exclamationmark.triangle.fill
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = orange,
            )
            Text(
                DSHLocalization.string("Permission required"),
                style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), // .headline
                color = orange,
            )
        }
        Text(
            approval.toolName,
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), // .subheadline.weight(.semibold)
            color = DSHColors.label(),
        )
        Text(
            approval.reason,
            style = TextStyle(fontSize = 15.sp), // .subheadline
            color = DSHColors.secondaryLabel(),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { onDecision(false) }) {
                Text(DSHLocalization.string("Reject"), color = DSHColors.systemRed())
            }
            Spacer(Modifier.weight(1f))
            Button(onClick = { onDecision(true) }) { // borderedProminent
                Text(DSHLocalization.string("Allow once"), color = MaterialTheme.colorScheme.onPrimary)
            }
        }
    }
}

// MARK: - Question card

/** SwiftUI: `QuestionCard`. */
@Composable
internal fun QuestionCard(request: DSHQuestionRequest, onAnswer: (List<DSHQuestionAnswer>) -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    val selections = remember { mutableStateMapOf<String, Set<String>>() }
    val custom = remember { mutableStateMapOf<String, String>() }
    var isSubmitting by remember { mutableStateOf(false) }

    fun hasAnswer(question: DSHQuestion): Boolean {
        if (selections[question.id]?.isNotEmpty() == true) return true
        return custom[question.id]?.isBlank() == false
    }
    val isComplete = request.questions.all { hasAnswer(it) }

    fun submitCompleteAnswers() {
        if (isSubmitting || !isComplete) return
        isSubmitting = true
        onAnswer(
            request.questions.map { question ->
                val text = custom[question.id]?.trim().orEmpty()
                DSHQuestionAnswer(
                    id = question.id,
                    selected = (selections[question.id] ?: emptySet()).sorted(),
                    custom = text.ifEmpty { null },
                )
            },
        )
    }

    val title = when {
        request.questions.size == 1 && !request.questions.first().header.isNullOrEmpty() ->
            request.questions.first().header!!
        request.questions.size == 1 -> DSHLocalization.string("Question")
        else -> "${request.questions.size} questions"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(accent.copy(alpha = 0.1f), RoundedCornerShape(14.dp))
            .border(1.dp, accent.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(
                Icons.Filled.ChatBubble, // questionmark.bubble.fill
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = accent,
            )
            Text(
                title,
                style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), // .headline
                color = accent,
            )
        }

        request.questions.forEach { question ->
            QuestionBody(
                question = question,
                showHeader = request.questions.size > 1,
                selected = selections[question.id] ?: emptySet(),
                customText = custom[question.id] ?: "",
                isSubmitting = isSubmitting,
                onToggleOption = { option ->
                    if (isSubmitting) return@QuestionBody
                    if (question.multiSelect == true) {
                        val current = (selections[question.id] ?: emptySet()).toMutableSet()
                        if (option.label in current) current.remove(option.label) else current.add(option.label)
                        selections[question.id] = current
                    } else {
                        // Single-select: a tap is the whole answer, submit at once.
                        selections[question.id] = setOf(option.label)
                        custom[question.id] = ""
                        submitCompleteAnswers()
                    }
                },
                onCustomChange = { custom[question.id] = it },
                onSubmit = { submitCompleteAnswers() },
            )
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { submitCompleteAnswers() },
                enabled = !isSubmitting && isComplete,
            ) {
                Text(DSHLocalization.string("Send answer"), color = MaterialTheme.colorScheme.onPrimary)
            }
        }
    }
}

@Composable
private fun QuestionBody(
    question: DSHQuestion,
    showHeader: Boolean,
    selected: Set<String>,
    customText: String,
    isSubmitting: Boolean,
    onToggleOption: (DSHQuestionOption) -> Unit,
    onCustomChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    val options = question.options ?: emptyList()
    val isMulti = question.multiSelect == true

    Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.Start) {
        if (showHeader && !question.header.isNullOrEmpty()) {
            Text(
                question.header,
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                color = DSHColors.secondaryLabel(),
            )
        }
        Text(
            question.question,
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = DSHColors.label(),
        )

        val detail = question.detail
        if (!detail.isNullOrEmpty()) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 180.dp)
                    .background(DSHColors.secondaryLabel().copy(alpha = 0.08f), RoundedCornerShape(10.dp))
                    .verticalScroll(rememberScrollState())
                    .padding(10.dp),
            ) {
                Text(detail, style = TextStyle(fontSize = 12.sp), color = DSHColors.secondaryLabel())
            }
        }

        if (options.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                options.forEach { option ->
                    QuestionOptionRow(
                        option = option,
                        isSelected = option.label in selected,
                        isMulti = isMulti,
                        onClick = { onToggleOption(option) },
                    )
                }
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = customText,
                onValueChange = onCustomChange,
                modifier = Modifier.weight(1f),
                placeholder = {
                    Text(
                        if (options.isEmpty()) {
                            DSHLocalization.string("Type your answer")
                        } else {
                            DSHLocalization.string("Other answer")
                        },
                    )
                },
                singleLine = false,
                maxLines = 3,
            )
            if (isMulti || options.isEmpty()) {
                OutlinedButton(
                    onClick = onSubmit,
                    enabled = !isSubmitting &&
                        (selected.isNotEmpty() || customText.isNotBlank()),
                ) {
                    Text(DSHLocalization.string("Send"))
                }
            }
        }
    }
}

@Composable
private fun QuestionOptionRow(
    option: DSHQuestionOption,
    isSelected: Boolean,
    isMulti: Boolean,
    onClick: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (isSelected) accent.copy(alpha = 0.16f) else DSHColors.secondaryLabel().copy(alpha = 0.08f),
                RoundedCornerShape(10.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = questionSymbol(isSelected = isSelected, isMulti = isMulti),
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = if (isSelected) accent else DSHColors.secondaryLabel(),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            horizontalAlignment = Alignment.Start,
        ) {
            Text(
                option.label,
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
                color = DSHColors.label(),
            )
            val description = option.description
            if (!description.isNullOrEmpty()) {
                Text(description, style = TextStyle(fontSize = 12.sp), color = DSHColors.secondaryLabel())
            }
        }
    }
}

/** SwiftUI: `QuestionCard.symbol(isSelected:isMulti:)`. */
private fun questionSymbol(
    isSelected: Boolean,
    isMulti: Boolean,
): ImageVector {
    // checkmark.square.fill / square / largecircle.fill.circle / circle
    return when {
        isMulti && isSelected -> Icons.Filled.CheckBox
        isMulti -> Icons.Filled.CropSquare
        isSelected -> Icons.Filled.RadioButtonChecked
        else -> Icons.Filled.RadioButtonUnchecked
    }
}
