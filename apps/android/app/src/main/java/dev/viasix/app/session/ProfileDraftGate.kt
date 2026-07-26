package dev.viasix.app.session

/**
 * Fast, pure validation for the editable profile draft.
 * Full projection validation still runs before the draft is applied.
 */
object ProfileDraftGate {
    sealed class Result {
        data object Ok : Result()

        data class Blocked(val message: String) : Result()
    }

    fun evaluate(profileYaml: String): Result {
        if (profileYaml.isBlank()) return Result.Blocked("配置草稿为空")

        // Memoized: evaluated per keystroke via SessionUiState.profileDraftIssue.
        val summary = MemoizedProfileSummaryParser.shared.summaryFor(profileYaml)
        summary.warnings.firstOrNull {
            it.startsWith("YAML 解析失败") || it.startsWith("顶层必须")
        }?.let { return Result.Blocked(it) }

        if (summary.primary == null) {
            return Result.Blocked(summary.warnings.firstOrNull() ?: "未找到有效代理入口")
        }
        if (!summary.hasXViasix) {
            return Result.Blocked("缺少 x-viasix 管理段")
        }
        if (summary.primaryServerMarker != "selected-ip") {
            return Result.Blocked("x-viasix.primary-server 必须为 selected-ip")
        }
        return Result.Ok
    }
}
