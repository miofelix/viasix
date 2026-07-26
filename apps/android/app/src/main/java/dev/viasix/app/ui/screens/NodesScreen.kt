package dev.viasix.app.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.automirrored.outlined.PlaylistAddCheck
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.viasix.app.runtime.RuntimeComponentId
import dev.viasix.app.state.SessionUiState
import dev.viasix.app.ui.AppSection
import dev.viasix.app.ui.theme.AppPageHeader
import dev.viasix.app.ui.theme.AppTone
import dev.viasix.app.ui.theme.CardHeader
import dev.viasix.app.ui.theme.LocalViaSixColors
import dev.viasix.app.ui.theme.StatusBadge
import dev.viasix.app.ui.theme.SurfaceCard
import dev.viasix.app.ui.theme.VisualStyle
import dev.viasix.core.net.Ipv6Address
import dev.viasix.core.speedtest.IPSourceMode
import dev.viasix.core.speedtest.Ipv6IpPresets
import dev.viasix.core.speedtest.NodeSortKey
import dev.viasix.core.speedtest.SpeedTestParameters
import dev.viasix.core.speedtest.SpeedTestResult

@Composable
fun NodesScreen(
    state: SessionUiState,
    onSelectedAddressChange: (String) -> Unit,
    onApplyNode: (address: String, reconnect: Boolean) -> Unit,
    onRemoveCandidate: (String) -> Unit,
    onCopy: (label: String, value: String) -> Unit,
    onSpeedParametersChange: (SpeedTestParameters) -> Unit = {},
    onIpSourceModeChange: (IPSourceMode) -> Unit = {},
    onCustomIpFilePathChange: (String) -> Unit = {},
    onResetSpeedParameters: () -> Unit = {},
    onToggleParametersExpanded: () -> Unit = {},
    onStartSpeedTest: () -> Unit = {},
    onStopSpeedTest: () -> Unit = {},
    onStartCurrentNodeTest: () -> Unit = {},
    onSpeedSortChange: (NodeSortKey) -> Unit = {},
) {
    val colors = LocalViaSixColors.current
    val looksValid = Ipv6Address.isValid(state.selectedAddress)
    val speed = state.speedTest
    val cfstRepairing = state.runtimeComponents.repairing == RuntimeComponentId.CFST

    Column(Modifier.fillMaxSize()) {
        AppPageHeader(
            title = AppSection.NODES.title,
            subtitle = AppSection.NODES.subtitle,
        ) {
            StatusBadge(
                title =
                    when {
                        speed.isRunning -> "测速中"
                        looksValid -> "已选择"
                        else -> "未选择"
                    },
                tone =
                    when {
                        speed.isRunning -> AppTone.Warning
                        looksValid -> AppTone.Accent
                        else -> AppTone.Warning
                    },
            )
        }

        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(
                        horizontal = VisualStyle.pageHorizontalPadding,
                        // Extra bottom inset so the last result-row actions (应用 / 复制)
                        // can scroll fully above the bottom navigation bar.
                        vertical = VisualStyle.pageVerticalPadding,
                    )
                    .padding(bottom = 72.dp),
            verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
        ) {
            SurfaceCard {
                CardHeader(
                    title = "CloudflareSpeedTest",
                    icon = Icons.Outlined.Speed,
                    tone = if (speed.isRunning) AppTone.Warning else AppTone.Accent,
                ) {
                    StatusBadge(
                        if (speed.binaryReady) "CFST 就绪" else "需拉取二进制",
                        tone = if (speed.binaryReady) AppTone.Accent else AppTone.Neutral,
                    )
                }
                HorizontalDivider(color = colors.surfaceBorder)
                Column(
                    modifier = Modifier.padding(VisualStyle.spacing16),
                    verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
                ) {
                    Text(
                        speed.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (speed.isRunning) {
                        if (speed.hasProgress) {
                            LinearProgressIndicator(
                                progress = { speed.progressFraction },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Text(
                                "${speed.progressCurrent} / ${speed.progressTotal}" +
                                    "（${(speed.progressFraction * 100f).toInt()}%）",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        } else {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                            Text(
                                "等待 CFST 进度…",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Text(
                        speed.parameterSummaryText,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    speed.parameterValidationMessage?.let { msg ->
                        Text(
                            msg,
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.negative,
                        )
                    }

                    // 数据源 — macOS IPSourceMode picker (no IPv4)
                    Text("数据源", style = MaterialTheme.typography.titleSmall)
                    Row(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        IPSourceMode.nodesPickerModes.forEach { mode ->
                            FilterChip(
                                selected = speed.ipSourceMode == mode,
                                onClick = { onIpSourceModeChange(mode) },
                                enabled = !speed.isRunning,
                                label = { Text(mode.title) },
                            )
                        }
                    }
                    when (speed.ipSourceMode) {
                        IPSourceMode.IPV6 ->
                            Text(
                                "使用内置 ipv6.txt（macOS 默认 IPv6 列表，CFST -f）。",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        IPSourceMode.RANGE -> {
                            Row(
                                modifier =
                                    Modifier
                                        .fillMaxWidth()
                                        .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                            ) {
                                Ipv6IpPresets.all.forEach { preset ->
                                    FilterChip(
                                        selected = speed.parameters.ipRange == preset.ipRange,
                                        onClick = {
                                            onSpeedParametersChange(
                                                speed.parameters.copy(ipRange = preset.ipRange),
                                            )
                                        },
                                        enabled = !speed.isRunning,
                                        label = { Text(preset.title) },
                                    )
                                }
                            }
                            OutlinedTextField(
                                value = speed.parameters.ipRange,
                                onValueChange = {
                                    onSpeedParametersChange(speed.parameters.copy(ipRange = it))
                                },
                                modifier = Modifier.fillMaxWidth(),
                                label = { Text("自定义 CIDR / IP") },
                                enabled = !speed.isRunning,
                                textStyle =
                                    MaterialTheme.typography.bodyMedium.copy(
                                        fontFamily = FontFamily.Monospace,
                                    ),
                                supportingText = {
                                    Text("多个 IPv6 地址或 CIDR 用英文逗号分隔")
                                },
                            )
                        }
                        IPSourceMode.FILE ->
                            OutlinedTextField(
                                value = speed.customIpFilePath,
                                onValueChange = onCustomIpFilePathChange,
                                modifier = Modifier.fillMaxWidth(),
                                label = { Text("IP 文件路径") },
                                enabled = !speed.isRunning,
                                textStyle =
                                    MaterialTheme.typography.bodyMedium.copy(
                                        fontFamily = FontFamily.Monospace,
                                    ),
                                supportingText = {
                                    Text("应用私有目录下的列表文件绝对路径（CFST -f）")
                                },
                            )
                    }

                    OutlinedButton(
                        onClick = onToggleParametersExpanded,
                        enabled = !speed.isRunning,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            if (speed.parametersExpanded) {
                                "收起测速设置"
                            } else {
                                "测速设置（模式 · 筛选 · 性能）"
                            },
                        )
                    }

                    if (speed.parametersExpanded) {
                        MacosStyleParametersPanel(
                            parameters = speed.parameters,
                            enabled = !speed.isRunning,
                            onChange = onSpeedParametersChange,
                            onReset = onResetSpeedParameters,
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        Button(
                            onClick = onStartSpeedTest,
                            enabled = speed.canStartSpeedTest && !cfstRepairing,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text(
                                when {
                                    speed.isRunning && !speed.isNodeTest -> "测速中…"
                                    cfstRepairing -> "CFST 修复中…"
                                    else -> "开始测速"
                                },
                            )
                        }
                        OutlinedButton(
                            onClick = onStopSpeedTest,
                            enabled = speed.isRunning,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("停止")
                        }
                    }
                    OutlinedButton(
                        onClick = onStartCurrentNodeTest,
                        enabled = !speed.isRunning && looksValid && !cfstRepairing,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            if (speed.isRunning && speed.isNodeTest) {
                                "当前节点测速中…"
                            } else if (cfstRepairing) {
                                "CFST 修复中…"
                            } else {
                                "当前节点测速"
                            },
                        )
                    }
                    Text(
                        "「当前节点测速」对齐 macOS 配置测速：保留当前参数并放宽筛选，仅测选中 IPv6。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (speed.results.isNotEmpty()) {
                SurfaceCard {
                    CardHeader(
                        title = "测速结果",
                        icon = Icons.Outlined.Speed,
                        tone = AppTone.Accent,
                    ) {
                        StatusBadge("${speed.results.size}", tone = AppTone.Neutral)
                    }
                    HorizontalDivider(color = colors.surfaceBorder)
                    Column(
                        modifier = Modifier.padding(top = VisualStyle.spacing8),
                        verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        Text(
                            "排序（再点同一列切换升/降序；缺失值始终靠后）",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = VisualStyle.spacing16),
                        )
                        Row(
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState())
                                    .padding(horizontal = VisualStyle.spacing12),
                            horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                        ) {
                            SortChip(
                                label = "延迟",
                                key = NodeSortKey.LATENCY,
                                current = speed.sortKey,
                                ascending = speed.sortAscending,
                                onClick = onSpeedSortChange,
                            )
                            SortChip(
                                label = "丢包",
                                key = NodeSortKey.LOSS,
                                current = speed.sortKey,
                                ascending = speed.sortAscending,
                                onClick = onSpeedSortChange,
                            )
                            SortChip(
                                label = "速度",
                                key = NodeSortKey.SPEED,
                                current = speed.sortKey,
                                ascending = speed.sortAscending,
                                onClick = onSpeedSortChange,
                            )
                            SortChip(
                                label = "地区",
                                key = NodeSortKey.REGION,
                                current = speed.sortKey,
                                ascending = speed.sortAscending,
                                onClick = onSpeedSortChange,
                            )
                            SortChip(
                                label = "IP",
                                key = NodeSortKey.IP,
                                current = speed.sortKey,
                                ascending = speed.sortAscending,
                                onClick = onSpeedSortChange,
                            )
                        }
                        HorizontalDivider(color = colors.surfaceBorder)
                        val sorted = speed.sortedResults
                        sorted.forEachIndexed { index, row ->
                            SpeedResultRow(
                                result = row,
                                vpnRunning = state.runtime.running,
                                onApply = { onApplyNode(row.ip, false) },
                                onApplyReconnect = { onApplyNode(row.ip, true) },
                                onCopy = { onCopy("IPv6", row.ip) },
                            )
                            if (index != sorted.lastIndex) {
                                HorizontalDivider(
                                    color = colors.surfaceBorder,
                                    modifier = Modifier.padding(start = 16.dp),
                                )
                            }
                        }
                    }
                }
            }

            SurfaceCard {
                CardHeader(
                    title = "当前 IPv6 节点",
                    icon = Icons.Outlined.Hub,
                    tone = if (looksValid) AppTone.Accent else AppTone.Warning,
                )
                HorizontalDivider(color = colors.surfaceBorder)
                Column(
                    modifier = Modifier.padding(VisualStyle.spacing16),
                    verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
                ) {
                    OutlinedTextField(
                        value = state.selectedAddress,
                        onValueChange = onSelectedAddressChange,
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("选中 IPv6") },
                        singleLine = true,
                        textStyle =
                            MaterialTheme.typography.bodyLarge.copy(
                                fontFamily = FontFamily.Monospace,
                            ),
                        supportingText = {
                            Text(
                                if (looksValid) {
                                    "合法 IPv6 · 将作为 primary-server 注入运行配置"
                                } else {
                                    "需要合法 IPv6（支持 [brackets] 与 zone id 规范化）"
                                },
                            )
                        },
                        isError = state.selectedAddress.isNotBlank() && !looksValid,
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        Button(
                            onClick = { onApplyNode(state.selectedAddress, false) },
                            enabled = looksValid,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("应用节点")
                        }
                        FilledTonalButton(
                            onClick = { onApplyNode(state.selectedAddress, true) },
                            enabled = looksValid && state.runtime.running,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("应用并重连")
                        }
                    }
                    if (state.runtime.running) {
                        Text(
                            "「应用并重连」会短暂中断本地代理，并以所选节点重新建立 VpnService 会话。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            SurfaceCard {
                CardHeader(
                    title = "候选节点",
                    icon = Icons.AutoMirrored.Outlined.PlaylistAddCheck,
                    tone = AppTone.Accent,
                ) {
                    StatusBadge(
                        "${state.candidateAddresses.size}",
                        tone = AppTone.Neutral,
                    )
                }
                HorizontalDivider(color = colors.surfaceBorder)
                if (state.candidateAddresses.isEmpty()) {
                    Text(
                        "应用合法 IPv6 或测速结果后会出现在候选列表，便于快速切换。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(VisualStyle.spacing16),
                    )
                } else {
                    Column {
                        state.candidateAddresses.forEachIndexed { index, address ->
                            val selected = address == Ipv6Address.normalize(state.selectedAddress)
                            Row(
                                modifier =
                                    Modifier
                                        .fillMaxWidth()
                                        .padding(
                                            horizontal = VisualStyle.spacing12,
                                            vertical = VisualStyle.spacing8,
                                        ),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        address,
                                        style =
                                            MaterialTheme.typography.bodyMedium.copy(
                                                fontFamily = FontFamily.Monospace,
                                            ),
                                        maxLines = 2,
                                    )
                                    if (selected) {
                                        Text(
                                            "当前使用",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = colors.accent,
                                        )
                                    }
                                }
                                IconButton(onClick = { onCopy("IPv6", address) }) {
                                    Icon(Icons.Outlined.ContentCopy, contentDescription = "复制")
                                }
                                OutlinedButton(
                                    onClick = { onApplyNode(address, false) },
                                    modifier = Modifier.height(34.dp),
                                ) { Text("选用") }
                                if (state.runtime.running) {
                                    FilledTonalButton(
                                        onClick = { onApplyNode(address, true) },
                                        modifier = Modifier.height(34.dp),
                                    ) { Text("重连") }
                                }
                                IconButton(onClick = { onRemoveCandidate(address) }) {
                                    Icon(Icons.Outlined.Delete, contentDescription = "移除")
                                }
                            }
                            if (index != state.candidateAddresses.lastIndex) {
                                HorizontalDivider(
                                    color = colors.surfaceBorder,
                                    modifier = Modifier.padding(start = 16.dp),
                                )
                            }
                        }
                    }
                }
            }

            SurfaceCard {
                CardHeader(title = "说明", icon = Icons.Outlined.Info, tone = AppTone.Neutral)
                HorizontalDivider(color = colors.surfaceBorder)
                Column(
                    modifier = Modifier.padding(VisualStyle.spacing16),
                    verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                ) {
                    Text(
                        "测速使用 CloudflareSpeedTest（CFST）v2.3.5，行为对齐 macOS：" +
                            "结果可应用为选中节点；选用或「应用并重连」走同一 projection / VpnService 路径。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "当前仅打包 arm64（linux_arm64）二进制；其他 ABI 需自行提供或等待后续扩展。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "直连模式下不需要 IPv6 节点；规则 / 全局模式投影要求 selectedNodeMustBeIPv6。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun MacosStyleParametersPanel(
    parameters: SpeedTestParameters,
    enabled: Boolean,
    onChange: (SpeedTestParameters) -> Unit,
    onReset: () -> Unit,
) {
    val p = parameters
    Column(verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12)) {
        Text("测速模式", style = MaterialTheme.typography.titleSmall)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
        ) {
            FilterChip(
                selected = !p.httping,
                onClick = { onChange(p.copy(httping = false)) },
                enabled = enabled,
                label = { Text("TCPing") },
            )
            FilterChip(
                selected = p.httping,
                onClick = { onChange(p.copy(httping = true)) },
                enabled = enabled,
                label = { Text("HTTPing") },
            )
        }
        IntField(
            label = "测速端口",
            value = p.port,
            enabled = enabled,
            onValue = { onChange(p.copy(port = it)) },
        )
        if (p.httping) {
            IntField(
                label = "HTTP 状态码（0=默认）",
                value = p.httpingCode,
                enabled = enabled,
                onValue = { onChange(p.copy(httpingCode = it)) },
            )
        }
        OutlinedTextField(
            value = p.colo,
            onValueChange = { onChange(p.copy(colo = it)) },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("区域过滤（IATA，逗号分隔）") },
            enabled = enabled,
            singleLine = true,
        )
        OutlinedTextField(
            value = p.url,
            onValueChange = { onChange(p.copy(url = it)) },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("测速 URL（可空）") },
            enabled = enabled && !p.disableDownload,
            singleLine = true,
        )

        Text("筛选条件", style = MaterialTheme.typography.titleSmall)
        IntField("延迟上限 (ms)", p.latencyUpperBound, enabled) {
            onChange(p.copy(latencyUpperBound = it))
        }
        IntField("延迟下限 (ms)", p.latencyLowerBound, enabled) {
            onChange(p.copy(latencyLowerBound = it))
        }
        DoubleField("丢包率上限 (0–1)", p.lossRateUpperBound, enabled) {
            onChange(p.copy(lossRateUpperBound = it))
        }
        DoubleField("下载速度下限 (MB/s)", p.speedLowerBound, enabled && !p.disableDownload) {
            onChange(p.copy(speedLowerBound = it))
        }

        Text("性能调优", style = MaterialTheme.typography.titleSmall)
        IntField("延迟测速线程", p.threads, enabled) { onChange(p.copy(threads = it)) }
        IntField("单 IP Ping 次数", p.pingCount, enabled) { onChange(p.copy(pingCount = it)) }
        IntField("下载测速数量", p.downloadCount, enabled && !p.disableDownload) {
            onChange(p.copy(downloadCount = it))
        }
        IntField("单 IP 下载时长 (s)", p.downloadTime, enabled && !p.disableDownload) {
            onChange(p.copy(downloadTime = it))
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("禁用下载测速", modifier = Modifier.weight(1f))
            Switch(
                checked = p.disableDownload,
                onCheckedChange = { onChange(p.copy(disableDownload = it)) },
                enabled = enabled,
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("调试模式", modifier = Modifier.weight(1f))
            Switch(
                checked = p.debug,
                onCheckedChange = { onChange(p.copy(debug = it)) },
                enabled = enabled,
            )
        }
        TextButton(onClick = onReset, enabled = enabled) {
            Text("恢复默认测速设置")
        }
    }
}

@Composable
private fun IntField(
    label: String,
    value: Int,
    enabled: Boolean,
    onValue: (Int) -> Unit,
) {
    NumericField(
        label = label,
        value = value,
        enabled = enabled,
        format = Int::toString,
        // Digits-only keeps the previous non-negative semantics (no "-"/"+").
        parse = { raw -> raw.takeIf { it.isNotEmpty() && it.all(Char::isDigit) }?.toIntOrNull() },
        keyboardType = KeyboardType.Number,
        errorText = "请输入整数",
        onValue = onValue,
    )
}

@Composable
private fun DoubleField(
    label: String,
    value: Double,
    enabled: Boolean,
    onValue: (Double) -> Unit,
) {
    NumericField(
        label = label,
        value = value,
        enabled = enabled,
        format = { v ->
            if (v == v.toLong().toDouble()) {
                v.toLong().toString()
            } else {
                v.toString()
            }
        },
        parse = String::toDoubleOrNull,
        keyboardType = KeyboardType.Decimal,
        errorText = "请输入数字",
        onValue = onValue,
    )
}

/** Text + last value committed upward; raw is kept as typed until it parses. */
private data class NumericFieldText<T>(val raw: String, val committed: T)

@Composable
private fun <T : Any> NumericField(
    label: String,
    value: T,
    enabled: Boolean,
    format: (T) -> String,
    parse: (String) -> T?,
    keyboardType: KeyboardType,
    errorText: String,
    onValue: (T) -> Unit,
) {
    // Raw text is local so intermediate edits (empty field, "0.") never snap
    // back to the committed value mid-typing; only valid parses commit upward.
    var field by remember { mutableStateOf(NumericFieldText(format(value), value)) }
    if (field.committed != value) {
        // External change (恢复默认测速设置 / preset): re-sync the visible text.
        field = NumericFieldText(format(value), value)
    }
    val parseFailed = parse(field.raw) == null
    OutlinedTextField(
        value = field.raw,
        onValueChange = { raw ->
            val parsed = parse(raw)
            field = NumericFieldText(raw, parsed ?: field.committed)
            parsed?.let(onValue)
        },
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        enabled = enabled,
        singleLine = true,
        isError = parseFailed,
        supportingText = if (parseFailed) ({ Text(errorText) }) else null,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
    )
}

@Composable
private fun SortChip(
    label: String,
    key: NodeSortKey,
    current: NodeSortKey,
    ascending: Boolean,
    onClick: (NodeSortKey) -> Unit,
) {
    val selected = current == key
    val arrow =
        when {
            !selected -> ""
            ascending -> " ↑"
            else -> " ↓"
        }
    FilterChip(
        selected = selected,
        onClick = { onClick(key) },
        label = { Text("$label$arrow") },
    )
}

@Composable
private fun SpeedResultRow(
    result: SpeedTestResult,
    vpnRunning: Boolean,
    onApply: () -> Unit,
    onApplyReconnect: () -> Unit,
    onCopy: () -> Unit,
) {
    val valid = Ipv6Address.isValid(result.ip)
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = VisualStyle.spacing12,
                    vertical = VisualStyle.spacing8,
                ),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            result.ip,
            style =
                MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = FontFamily.Monospace,
                ),
            maxLines = 2,
        )
        Text(
            buildString {
                append("延迟 ${result.latency.ifBlank { "—" }}")
                append(" · 丢包 ${result.loss.ifBlank { "—" }}")
                append(" · 速度 ${result.speed.ifBlank { "—" }}")
                if (result.region.isNotBlank()) append(" · ${result.region}")
            },
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onCopy) {
                Icon(Icons.Outlined.ContentCopy, contentDescription = "复制")
            }
            OutlinedButton(
                onClick = onApply,
                enabled = valid,
                modifier = Modifier.height(34.dp),
            ) { Text("应用") }
            if (vpnRunning) {
                FilledTonalButton(
                    onClick = onApplyReconnect,
                    enabled = valid,
                    modifier = Modifier.height(34.dp),
                ) { Text("应用并重连") }
            }
        }
    }
}
