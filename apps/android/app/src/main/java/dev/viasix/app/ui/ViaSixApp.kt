package dev.viasix.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.viasix.app.net.ExitIPDetectionMode
import dev.viasix.app.runtime.RuntimeComponentId
import dev.viasix.app.session.AppRoutingMode
import dev.viasix.app.session.DnsRoutingMode
import dev.viasix.app.session.Ipv6RoutingMode
import dev.viasix.app.session.ConnectionPhase
import dev.viasix.app.state.SessionUiState
import dev.viasix.app.ui.screens.LogsScreen
import dev.viasix.app.ui.screens.NodesScreen
import dev.viasix.app.ui.screens.OverviewScreen
import dev.viasix.app.ui.screens.ProfilesScreen
import dev.viasix.app.ui.screens.SettingsScreen
import dev.viasix.app.ui.theme.AppTone
import dev.viasix.app.ui.theme.LocalViaSixColors
import dev.viasix.app.ui.theme.StatusBadge
import dev.viasix.app.ui.theme.VisualStyle
import dev.viasix.app.ui.theme.ViaSixTheme
import dev.viasix.core.projection.RoutingMode
import dev.viasix.core.speedtest.IPSourceMode
import dev.viasix.core.speedtest.NodeSortKey
import dev.viasix.core.speedtest.SpeedTestParameters

@Composable
fun ViaSixApp(
    state: SessionUiState,
    selectedSection: AppSection,
    onSectionChange: (AppSection) -> Unit,
    onProfileChange: (String) -> Unit,
    onApplyProfile: (reconnect: Boolean) -> Unit,
    onRevertProfile: () -> Unit,
    onImportProfile: () -> Unit,
    onImportClipboard: () -> Unit = {},
    onSelectedAddressChange: (String) -> Unit,
    onApplyNode: (address: String, reconnect: Boolean) -> Unit,
    onRemoveCandidate: (String) -> Unit,
    onSpeedParametersChange: (SpeedTestParameters) -> Unit = {},
    onIpSourceModeChange: (IPSourceMode) -> Unit = {},
    onCustomIpFilePathChange: (String) -> Unit = {},
    onResetSpeedParameters: () -> Unit = {},
    onToggleParametersExpanded: () -> Unit = {},
    onStartSpeedTest: () -> Unit = {},
    onStopSpeedTest: () -> Unit = {},
    onStartCurrentNodeTest: () -> Unit = {},
    onSpeedSortChange: (NodeSortKey) -> Unit = {},
    onInspectRuntimeComponents: () -> Unit = {},
    onRepairRuntimeComponent: (RuntimeComponentId) -> Unit = {},
    onManageNotificationPermission: () -> Unit = {},
    onManageVpnPermission: () -> Unit = {},
    onManageBatteryOptimization: () -> Unit = {},
    onAppRoutingModeChange: (AppRoutingMode) -> Unit = {},
    onToggleAppRoutingPackage: (String) -> Unit = {},
    onClearSelectedAppPackages: () -> Unit = {},
    onRefreshInstalledApps: () -> Unit = {},
    onDnsRoutingModeChange: (DnsRoutingMode) -> Unit = {},
    onDnsServerChange: (String) -> Unit = {},
    onVpnMtuChange: (String) -> Unit = {},
    onVpnMeteredChange: (Boolean) -> Unit = {},
    onBypassLocalNetworkChange: (Boolean) -> Unit = {},
    onIpv6RoutingModeChange: (Ipv6RoutingMode) -> Unit = {},
    onRoutingModeChange: (RoutingMode) -> Unit,
    onFullTunnelChange: (Boolean) -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onProjectPreview: () -> Unit,
    onDetectExitIp: () -> Unit,
    onExitIpModeChange: (ExitIPDetectionMode) -> Unit,
    onExitIpEndpointChange: (String) -> Unit,
    onDelayTest: () -> Unit,
    onCopy: (label: String, value: String) -> Unit,
    onClearLogs: () -> Unit,
    onDismissNotice: () -> Unit,
    onClearSessionData: () -> Unit,
    speedParameterInputs: SpeedParameterInputs = remember { SpeedParameterInputs() },
) {
    ViaSixTheme {
        val colors = LocalViaSixColors.current
        val snackbarHostState = remember { SnackbarHostState() }

        LaunchedEffect(state.notice?.id) {
            val notice = state.notice ?: return@LaunchedEffect
            val result =
                snackbarHostState.showSnackbar(
                    message = notice.message,
                    actionLabel = if (notice.actionOpenSettings) "设置" else null,
                    withDismissAction = true,
                )
            if (result == androidx.compose.material3.SnackbarResult.ActionPerformed &&
                notice.actionOpenSettings
            ) {
                onSectionChange(AppSection.SETTINGS)
            }
            onDismissNotice()
        }

        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val navigationLayout =
                AppNavigationLayout.forWidthDp(maxWidth.value.toInt())
            val showRailContext = maxHeight >= 520.dp

            Scaffold(
                containerColor = colors.pageBackground,
                snackbarHost = { SnackbarHost(snackbarHostState) },
                bottomBar = {
                    if (navigationLayout == AppNavigationLayout.BOTTOM_BAR) {
                        AppBottomNavigation(
                            selectedSection = selectedSection,
                            onSectionChange = onSectionChange,
                        )
                    }
                },
            ) { padding ->
                Row(
                    modifier =
                        Modifier
                            .fillMaxSize()
                            .padding(padding),
                ) {
                    when (navigationLayout) {
                        AppNavigationLayout.BOTTOM_BAR -> Unit
                        AppNavigationLayout.NAVIGATION_RAIL -> {
                            AppNavigationRail(
                                state = state,
                                selectedSection = selectedSection,
                                showContext = showRailContext,
                                onSectionChange = onSectionChange,
                            )
                            VerticalDivider(color = colors.surfaceBorder)
                        }
                        AppNavigationLayout.SIDEBAR -> {
                            AppNavigationSidebar(
                                state = state,
                                selectedSection = selectedSection,
                                onSectionChange = onSectionChange,
                            )
                            VerticalDivider(color = colors.surfaceBorder)
                        }
                    }

                    Box(
                        modifier =
                            Modifier
                                .weight(1f)
                                .fillMaxHeight(),
                    ) {
                        when (selectedSection) {
                            AppSection.OVERVIEW ->
                                OverviewScreen(
                                    state = state,
                                    onRoutingModeChange = onRoutingModeChange,
                                    onFullTunnelChange = onFullTunnelChange,
                                    onStart = onStart,
                                    onStop = onStop,
                                    onNavigate = onSectionChange,
                                    onDetectExitIp = onDetectExitIp,
                                    onExitIpModeChange = onExitIpModeChange,
                                    onDelayTest = onDelayTest,
                                    onCopy = onCopy,
                                    onStartCurrentNodeTest = onStartCurrentNodeTest,
                                    onStopSpeedTest = onStopSpeedTest,
                                )
                            AppSection.NODES ->
                                NodesScreen(
                                    state = state,
                                    parameterInputs = speedParameterInputs,
                                    onSelectedAddressChange = onSelectedAddressChange,
                                    onApplyNode = onApplyNode,
                                    onRemoveCandidate = onRemoveCandidate,
                                    onCopy = onCopy,
                                    onSpeedParametersChange = onSpeedParametersChange,
                                    onIpSourceModeChange = onIpSourceModeChange,
                                    onCustomIpFilePathChange = onCustomIpFilePathChange,
                                    onResetSpeedParameters = onResetSpeedParameters,
                                    onToggleParametersExpanded = onToggleParametersExpanded,
                                    onStartSpeedTest = onStartSpeedTest,
                                    onStopSpeedTest = onStopSpeedTest,
                                    onStartCurrentNodeTest = onStartCurrentNodeTest,
                                    onSpeedSortChange = onSpeedSortChange,
                                )
                            AppSection.PROFILES ->
                                ProfilesScreen(
                                    state = state,
                                    onProfileChange = onProfileChange,
                                    onApplyProfile = onApplyProfile,
                                    onRevertProfile = onRevertProfile,
                                    onProjectPreview = onProjectPreview,
                                    onImportProfile = onImportProfile,
                                    onImportClipboard = onImportClipboard,
                                )
                            AppSection.LOGS ->
                                LogsScreen(
                                    state = state,
                                    onClear = onClearLogs,
                                )
                            AppSection.SETTINGS ->
                                SettingsScreen(
                                    state = state,
                                    onFullTunnelChange = onFullTunnelChange,
                                    onExitIpModeChange = onExitIpModeChange,
                                    onExitIpEndpointChange = onExitIpEndpointChange,
                                    onDetectExitIp = onDetectExitIp,
                                    onClearSessionData = onClearSessionData,
                                    onInspectRuntimeComponents = onInspectRuntimeComponents,
                                    onRepairRuntimeComponent = onRepairRuntimeComponent,
                                    onManageNotificationPermission = onManageNotificationPermission,
                                    onManageVpnPermission = onManageVpnPermission,
                                    onManageBatteryOptimization = onManageBatteryOptimization,
                                    onAppRoutingModeChange = onAppRoutingModeChange,
                                    onToggleAppRoutingPackage = onToggleAppRoutingPackage,
                                    onClearSelectedAppPackages = onClearSelectedAppPackages,
                                    onRefreshInstalledApps = onRefreshInstalledApps,
                                    onDnsRoutingModeChange = onDnsRoutingModeChange,
                                    onDnsServerChange = onDnsServerChange,
                                    onVpnMtuChange = onVpnMtuChange,
                                    onVpnMeteredChange = onVpnMeteredChange,
                                    onBypassLocalNetworkChange = onBypassLocalNetworkChange,
                                    onIpv6RoutingModeChange = onIpv6RoutingModeChange,
                                )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AppBottomNavigation(
    selectedSection: AppSection,
    onSectionChange: (AppSection) -> Unit,
) {
    val colors = LocalViaSixColors.current
    NavigationBar(
        containerColor = colors.surface,
        contentColor = colors.accent,
    ) {
        AppSection.entries.forEach { section ->
            val selected = selectedSection == section
            NavigationBarItem(
                selected = selected,
                onClick = { onSectionChange(section) },
                icon = {
                    Icon(
                        imageVector = section.icon,
                        contentDescription = section.title,
                    )
                },
                label = {
                    Text(
                        text = section.title,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                colors =
                    NavigationBarItemDefaults.colors(
                        selectedIconColor = colors.accent,
                        selectedTextColor = colors.accent,
                        indicatorColor = colors.accent.copy(alpha = 0.14f),
                    ),
            )
        }
    }
}

@Composable
private fun AppNavigationRail(
    state: SessionUiState,
    selectedSection: AppSection,
    showContext: Boolean,
    onSectionChange: (AppSection) -> Unit,
) {
    val colors = LocalViaSixColors.current
    NavigationRail(
        modifier = Modifier.fillMaxHeight().width(104.dp),
        containerColor = colors.sidebarBackground,
        header = {
            Box(
                modifier =
                    Modifier
                        .padding(top = VisualStyle.spacing8, bottom = VisualStyle.spacing4)
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(colors.accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "V6",
                    color = colors.accent,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                )
            }
        },
    ) {
        AppSection.entries.forEach { section ->
            val selected = selectedSection == section
            NavigationRailItem(
                selected = selected,
                onClick = { onSectionChange(section) },
                icon = {
                    Icon(
                        imageVector = section.icon,
                        contentDescription = section.title,
                    )
                },
                label = {
                    Text(
                        text = section.title,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                alwaysShowLabel = true,
                colors =
                    NavigationRailItemDefaults.colors(
                        selectedIconColor = colors.accent,
                        selectedTextColor = colors.accent,
                        indicatorColor = colors.accent.copy(alpha = 0.14f),
                    ),
            )
        }

        if (showContext) {
            Spacer(Modifier.weight(1f))
            StatusBadge(
                title = state.connectionPhase.statusLabel(),
                tone = state.connectionPhase.navigationTone(),
            )
            Text(
                text = state.selectedAddress.ifBlank { "未选择节点" },
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = VisualStyle.spacing8, vertical = VisualStyle.spacing12),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun AppNavigationSidebar(
    state: SessionUiState,
    selectedSection: AppSection,
    onSectionChange: (AppSection) -> Unit,
) {
    val colors = LocalViaSixColors.current
    Column(
        modifier =
            Modifier
                .fillMaxHeight()
                .width(236.dp)
                .background(colors.sidebarBackground),
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = VisualStyle.spacing16, vertical = VisualStyle.spacing20),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VisualStyle.spacing12),
        ) {
            Box(
                modifier =
                    Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(colors.accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "V6",
                    color = colors.accent,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                )
            }
            Text(
                text = "ViaSix",
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
            )
        }

        AppSection.entries.forEach { section ->
            val selected = selectedSection == section
            NavigationDrawerItem(
                label = {
                    Column {
                        Text(
                            text = section.title,
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                        )
                        if (selected) {
                            Text(
                                text = section.subtitle,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.labelSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                },
                icon = {
                    Icon(
                        imageVector = section.icon,
                        contentDescription = section.title,
                    )
                },
                selected = selected,
                onClick = { onSectionChange(section) },
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = VisualStyle.spacing8, vertical = 2.dp),
                colors =
                    NavigationDrawerItemDefaults.colors(
                        selectedContainerColor = colors.accent.copy(alpha = 0.14f),
                        selectedIconColor = colors.accent,
                        selectedTextColor = MaterialTheme.colorScheme.onSurface,
                    ),
            )
        }

        Spacer(Modifier.weight(1f))
        HorizontalDivider(
            modifier = Modifier.fillMaxWidth(),
            color = colors.surfaceBorder,
        )
        Column(
            modifier = Modifier.padding(VisualStyle.spacing16),
            verticalArrangement = Arrangement.spacedBy(VisualStyle.spacing8),
        ) {
            StatusBadge(
                title = state.connectionPhase.statusLabel(),
                tone = state.connectionPhase.navigationTone(),
            )
            Text(
                text = "IPv6 代理入口",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
            Text(
                text = state.selectedAddress.ifBlank { "尚未选择" },
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun ConnectionPhase.navigationTone(): AppTone =
    when (this) {
        ConnectionPhase.STOPPED -> AppTone.Neutral
        ConnectionPhase.STARTING -> AppTone.Accent
        ConnectionPhase.RUNNING -> AppTone.Positive
        ConnectionPhase.STOPPING -> AppTone.Warning
    }
