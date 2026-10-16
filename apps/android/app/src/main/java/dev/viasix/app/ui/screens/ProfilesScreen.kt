package dev.viasix.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FileOpen
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Science
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.viasix.app.state.SessionUiState
import dev.viasix.app.session.SessionConfigurationActions
import dev.viasix.app.ui.AppSection
import dev.viasix.app.ui.theme.AppPageHeader
import dev.viasix.app.ui.theme.AppTone
import dev.viasix.app.ui.theme.CardHeader
import dev.viasix.app.ui.theme.CompactInfoRow
import dev.viasix.app.ui.theme.LocalViaSixColors
import dev.viasix.app.ui.theme.StatusBadge
import dev.viasix.app.ui.theme.SurfaceCard
import dev.viasix.app.ui.theme.VisualStyle

@Composable
fun ProfilesScreen(
    state: SessionUiState,
    onProfileChange: (String) -> Unit,
    onApplyProfile: (reconnect: Boolean) -> Unit,
    onRevertProfile: () -> Unit,
    onProjectPreview: () -> Unit,
    onImportProfile: () -> Unit,
    onImportClipboard: () -> Unit = {},
) {
    val colors = LocalViaSixColors.current
    val summary = state.profileSummary
    val draftSummary = state.profileDraftSummary
    val draftIssue = state.profileDraftIssue
    val canApply = state.profileHasUnsavedChanges && draftIssue == null &&
        SessionConfigurationActions.canApply(state.connectionPhase)
    val tone =
        when {
            summary.isManaged -> AppTone.Accent
            summary.primary != null -> AppTone.Warning
            else -> AppTone.Negative
        }

    Column(Modifier.fillMaxSize()) {
        AppPageHeader(
            title = AppSection.PROFILES.title,
            subtitle = AppSection.PROFILES.subtitle,
        ) {
            StatusBadge(
                title = if (state.profileHasUnsavedChanges) "草稿未应用" else summary.statusLabel,
                tone = if (state.profileHasUnsavedChanges) AppTone.Warning else tone,
            )
        }

        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(
                        horizontal = VisualStyle.pageHorizontalPadding,
                        vertical = VisualStyle.pageVerticalPadding,
                    ),
            verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
        ) {
            SurfaceCard {
                CardHeader(
                    title = "已应用代理入口",
                    icon = Icons.Outlined.Inventory2,
                    tone = tone,
                )
                HorizontalDivider(color = colors.surfaceBorder)
                CompactInfoRow("名称", summary.primary?.name ?: "—")
                HorizontalDivider(color = colors.surfaceBorder, modifier = Modifier.padding(start = 40.dp))
                CompactInfoRow("类型", summary.primary?.type ?: "—")
                HorizontalDivider(color = colors.surfaceBorder, modifier = Modifier.padding(start = 40.dp))
                CompactInfoRow(
                    "服务端",
                    summary.primary?.let { primary ->
                        primary.server?.let { s ->
                            primary.port?.let { "$s:$it" } ?: s
                        } ?: "—"
                    } ?: "—",
                )
                HorizontalDivider(color = colors.surfaceBorder, modifier = Modifier.padding(start = 40.dp))
                CompactInfoRow("proxies", "${summary.proxyCount}")
                HorizontalDivider(color = colors.surfaceBorder, modifier = Modifier.padding(start = 40.dp))
                CompactInfoRow(
                    "x-viasix",
                    if (summary.hasXViasix) {
                        summary.primaryServerMarker ?: "已声明"
                    } else {
                        "缺失"
                    },
                )
                if (summary.warnings.isNotEmpty()) {
                    Column(
                        modifier = Modifier.padding(VisualStyle.spacing16),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        summary.warnings.forEach { warning ->
                            Text(
                                "• $warning",
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.warning,
                            )
                        }
                    }
                } else {
                    androidx.compose.foundation.layout.Spacer(
                        Modifier.height(VisualStyle.spacing12),
                    )
                }
            }

            SurfaceCard {
                CardHeader(
                    title = "编辑 YAML",
                    icon = Icons.Outlined.Science,
                    tone = if (draftIssue == null) AppTone.Accent else AppTone.Warning,
                ) {
                    StatusBadge(
                        title =
                            when {
                                draftIssue != null -> "需要修正"
                                state.profileHasUnsavedChanges -> "可以应用"
                                else -> "已同步"
                            },
                        tone =
                            when {
                                draftIssue != null -> AppTone.Warning
                                state.profileHasUnsavedChanges -> AppTone.Accent
                                else -> AppTone.Positive
                            },
                    )
                }
                HorizontalDivider(color = colors.surfaceBorder)
                Column(
                    modifier = Modifier.padding(VisualStyle.spacing16),
                    verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
                ) {
                    Text(
                        "草稿与当前运行配置相互隔离。校验并应用后才会替换已保存配置；" +
                            "运行中可选择立即重连。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = state.profileDraft,
                        onValueChange = onProfileChange,
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .height(280.dp),
                        label = { Text("Profile YAML") },
                        isError = draftIssue != null,
                        supportingText = {
                            Text(
                                draftIssue
                                    ?: if (state.profileHasUnsavedChanges) {
                                        "草稿尚未应用；当前连接仍使用上一次有效配置。"
                                    } else {
                                        "草稿与已应用配置一致。"
                                    },
                            )
                        },
                        textStyle =
                            MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                            ),
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        OutlinedButton(onClick = onImportProfile) {
                            Text("导入文件")
                        }
                        OutlinedButton(onClick = onImportClipboard) {
                            Text("粘贴剪贴板")
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                    ) {
                        OutlinedButton(
                            onClick = onRevertProfile,
                            enabled = state.profileHasUnsavedChanges,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("还原草稿")
                        }
                        OutlinedButton(
                            onClick = onProjectPreview,
                            enabled = state.profileDraft.isNotBlank(),
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("投影预览")
                        }
                    }
                    if (state.runtime.running) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
                        ) {
                            OutlinedButton(
                                onClick = { onApplyProfile(false) },
                                enabled = canApply,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("仅保存")
                            }
                            Button(
                                onClick = { onApplyProfile(true) },
                                enabled = canApply,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("应用并重连")
                            }
                        }
                    } else {
                        Button(
                            onClick = { onApplyProfile(false) },
                            enabled = canApply,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("应用配置")
                        }
                    }
                }
            }

            if (state.configPreview.isNotBlank()) {
                SurfaceCard {
                    CardHeader(
                        title = "运行配置预览",
                        icon = Icons.Outlined.FileOpen,
                        tone = AppTone.Accent,
                    )
                    HorizontalDivider(color = colors.surfaceBorder)
                    Text(
                        text = state.configPreview,
                        style =
                            MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                            ),
                        modifier = Modifier.padding(VisualStyle.spacing16),
                    )
                }
            }

            SurfaceCard {
                CardHeader(
                    title = "安全提示",
                    icon = Icons.Outlined.Shield,
                    tone = AppTone.Warning,
                )
                HorizontalDivider(color = colors.surfaceBorder)
                Text(
                    text =
                        "配置仅保存在本机 SharedPreferences，不会上传。" +
                            "编辑草稿不会覆盖上一次有效配置；请勿分享含有 uuid / 密钥的完整 YAML。" +
                            "应用前会按 contracts 投影规则再次校验。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(VisualStyle.spacing16),
                )
            }

            if (draftIssue != null) {
                SurfaceCard {
                    CardHeader(
                        title = "草稿需要修正",
                        icon = Icons.Outlined.WarningAmber,
                        tone = AppTone.Warning,
                    )
                    HorizontalDivider(color = colors.surfaceBorder)
                    Text(
                        draftIssue +
                            if (draftSummary.warnings.isNotEmpty()) {
                                "\n${draftSummary.warnings.joinToString("；")}"
                            } else {
                                ""
                            },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(VisualStyle.spacing16),
                    )
                }
            }
        }
    }
}
