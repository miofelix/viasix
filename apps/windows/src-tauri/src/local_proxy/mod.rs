//! Local mixed-proxy invariants aligned with macOS (loopback-only listen).

use std::net::Ipv6Addr;

/// Returns Ok(normalized) when address is loopback; Err with contract-style message otherwise.
pub fn validate_listen_address(raw: &str) -> Result<String, String> {
    let addr = raw.trim();
    if addr.is_empty() {
        return Err("listenAddress required".into());
    }
    // macOS ViaSix only allows loopback mixed-proxy listeners.
    let ok = matches!(addr, "127.0.0.1" | "::1" | "localhost" | "0:0:0:0:0:0:0:1")
        || addr.eq_ignore_ascii_case("localhost");
    if !ok {
        return Err(format!(
            "listenAddress must be loopback (127.0.0.1 or ::1), got {addr}"
        ));
    }
    if addr.eq_ignore_ascii_case("localhost") || addr == "0:0:0:0:0:0:0:1" {
        return Ok("127.0.0.1".into());
    }
    if addr == "::1" {
        return Ok("::1".into());
    }
    Ok("127.0.0.1".into())
}

pub fn validate_port(port: u16, name: &str) -> Result<u16, String> {
    if port == 0 {
        return Err(format!("{name} must be in 1..=65535"));
    }
    Ok(port)
}

/// mixed and controller ports must both be valid and distinct (macOS local-proxy invariant).
pub fn validate_proxy_ports(mixed_port: u16, controller_port: u16) -> Result<(), String> {
    let mixed = validate_port(mixed_port, "mixedPort")?;
    let controller = validate_port(controller_port, "controllerPort")?;
    if mixed == controller {
        return Err(format!(
            "mixedPort and controllerPort must differ (both {mixed})"
        ));
    }
    Ok(())
}

/// IPv6-first selection rule: direct mode needs no node; rule/global require IPv6.
pub fn validate_selected_address_for_mode(
    routing_mode: &str,
    selected_address: Option<&str>,
) -> Result<Option<String>, String> {
    let mode = routing_mode.trim().to_ascii_lowercase();
    if mode == "direct" {
        return Ok(None);
    }
    if mode != "rule" && mode != "global" {
        return Err(format!("invalid routingMode: {routing_mode}"));
    }
    let raw = selected_address.map(str::trim).unwrap_or("");
    if raw.is_empty() {
        return Err("selectedAddress required for rule/global modes".into());
    }
    if !looks_like_ipv6(raw) {
        return Err(format!(
            "selectedAddress must be IPv6 (IPv6-first), got {raw}"
        ));
    }
    Ok(Some(raw.to_string()))
}

fn looks_like_ipv6(value: &str) -> bool {
    value
        .parse::<Ipv6Addr>()
        .is_ok_and(|address| address.to_ipv4_mapped().is_none())
}

/// Merge kernel log tail lines into display-friendly activity messages.
pub fn kernel_log_lines_for_activity(raw: &str, max_lines: usize) -> Vec<String> {
    let take = max_lines.max(1);
    raw.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .rev()
        .take(take)
        .map(|l| format!("[mihomo] {l}"))
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}

/// Format activity entries for file export (TSV-ish, stable for diagnostics).
pub fn format_activity_export(entries: &[(u64, &str, &str, &str)]) -> String {
    // (at_ms, level, source, message)
    let mut out = String::from("at_ms\tlevel\tsource\tmessage\n");
    for (at, level, source, message) in entries {
        let msg = message.replace('\t', " ").replace('\n', " ");
        out.push_str(&format!("{at}\t{level}\t{source}\t{msg}\n"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_loopback_v4() {
        assert_eq!(validate_listen_address("127.0.0.1").unwrap(), "127.0.0.1");
        assert_eq!(validate_listen_address(" localhost ").unwrap(), "127.0.0.1");
    }

    #[test]
    fn accepts_loopback_v6() {
        assert_eq!(validate_listen_address("::1").unwrap(), "::1");
    }

    #[test]
    fn rejects_lan_bind() {
        let err = validate_listen_address("0.0.0.0").unwrap_err();
        assert!(err.contains("loopback"), "{err}");
        let err = validate_listen_address("192.168.1.1").unwrap_err();
        assert!(err.contains("loopback"), "{err}");
    }

    #[test]
    fn kernel_log_lines_preserve_order_and_cap() {
        let raw = "a\nb\nc\nd\n";
        let lines = kernel_log_lines_for_activity(raw, 2);
        assert_eq!(
            lines,
            vec!["[mihomo] c".to_string(), "[mihomo] d".to_string()]
        );
    }

    #[test]
    fn validate_port_rejects_zero() {
        let err = validate_port(0, "mixedPort").unwrap_err();
        assert!(err.contains("mixedPort"), "{err}");
        assert_eq!(validate_port(11451, "mixedPort").unwrap(), 11451);
    }

    #[test]
    fn rejects_empty_listen() {
        assert!(validate_listen_address("").is_err());
        assert!(validate_listen_address("   ").is_err());
    }

    #[test]
    fn proxy_ports_must_differ() {
        assert!(validate_proxy_ports(11451, 9090).is_ok());
        let err = validate_proxy_ports(9090, 9090).unwrap_err();
        assert!(err.contains("must differ"), "{err}");
    }

    #[test]
    fn selected_address_rules_match_ipv6_first() {
        assert_eq!(
            validate_selected_address_for_mode("direct", None).unwrap(),
            None
        );
        assert!(validate_selected_address_for_mode("rule", None).is_err());
        assert!(validate_selected_address_for_mode("rule", Some("1.2.3.4")).is_err());
        assert_eq!(
            validate_selected_address_for_mode("global", Some("2001:db8::1"))
                .unwrap()
                .as_deref(),
            Some("2001:db8::1")
        );
    }

    #[test]
    fn selected_address_uses_the_same_strict_ipv6_parser_as_projection() {
        for invalid in [
            ":::1",
            "2001:db8::1::2",
            "2001:db8:zz::1",
            "fe80::1%12",
            "::ffff:192.0.2.1",
            "::ffff:c000:201",
        ] {
            let error =
                validate_selected_address_for_mode("rule", Some(invalid)).expect_err(invalid);
            assert!(error.contains("must be IPv6"), "{invalid}: {error}");
        }

        assert_eq!(
            validate_selected_address_for_mode(
                "rule",
                Some("2001:0DB8:0000:0000:0000:0000:0000:0001"),
            )
            .unwrap()
            .as_deref(),
            Some("2001:0DB8:0000:0000:0000:0000:0000:0001")
        );
    }

    #[test]
    fn activity_export_is_tsv() {
        let rows = [(1u64, "info", "app", "hello\tworld")];
        let text = format_activity_export(&rows);
        assert!(text.starts_with("at_ms\tlevel\tsource\tmessage\n"));
        assert!(text.contains("hello world"));
        assert!(!text.contains("hello\tworld\n"));
    }
}
