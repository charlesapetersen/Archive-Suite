package com.archiveprocessor.capture.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

private val MONTHS = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

/** Minimal on-phone tagging shown when a document segment is finished: priority + date.
 *  Subjects are intentionally NOT here — the Mac handles those. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SegmentTagSheet(
    recentYears: List<Int>,
    onApply: (priority: String?, year: Int?, month: Int?) -> Unit
) {
    var priority by remember { mutableStateOf<String?>(null) }
    var year by remember { mutableStateOf<Int?>(null) }
    var month by remember { mutableStateOf<Int?>(null) }
    var customYear by remember { mutableStateOf("") }

    Column(
        Modifier.fillMaxWidth().padding(20.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Tag this document", style = MaterialTheme.typography.titleLarge)

        Text("Priority", style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("P10", "P9", "P8", "P7").forEach { p ->
                FilterChip(
                    selected = priority == p,
                    onClick = { priority = if (priority == p) null else p },
                    label = { Text(p) }
                )
            }
        }

        Text("Year", style = MaterialTheme.typography.labelLarge)
        if (recentYears.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                recentYears.forEach { y ->
                    FilterChip(
                        selected = year == y && customYear.isEmpty(),
                        onClick = { year = if (year == y) null else y; customYear = "" },
                        label = { Text(y.toString()) }
                    )
                }
            }
        }
        OutlinedTextField(
            value = customYear,
            onValueChange = { s -> customYear = s.filter { it.isDigit() }.take(4); year = customYear.toIntOrNull() },
            label = { Text("Specific year") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
        )

        Text("Month", style = MaterialTheme.typography.labelLarge)
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            MONTHS.forEachIndexed { i, name ->
                FilterChip(
                    selected = month == i + 1,
                    onClick = { month = if (month == i + 1) null else i + 1 },
                    label = { Text(name) }
                )
            }
        }

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(onClick = { onApply(null, null, null) }, modifier = Modifier.weight(1f)) { Text("Skip") }
            Button(onClick = { onApply(priority, year, month) }, modifier = Modifier.weight(1f)) { Text("Apply & continue") }
        }
        Spacer(Modifier.height(8.dp))
    }
}
