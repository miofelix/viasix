//! Mihomo runtime projection aligned with monorepo `contracts/fixtures`.

use serde_yaml::{Mapping, Value};
use std::net::Ipv6Addr;
use std::str::FromStr;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutingMode {
    Rule,
    Global,
    Direct,
}

impl RoutingMode {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "rule" => Some(Self::Rule),
            "global" => Some(Self::Global),
            "direct" => Some(Self::Direct),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rule => "rule",
            Self::Global => "global",
            Self::Direct => "direct",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectionKind {
    User,
    PrivilegedTun,
}

impl ProjectionKind {
    #[cfg(test)]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "user" => Some(Self::User),
            "privilegedTun" => Some(Self::PrivilegedTun),
            _ => None,
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProjectError {
    #[error("selectedNodeMustBeIPv6")]
    SelectedNodeMustBeIPv6,
    #[error("ipv6ManagedProfileRequired")]
    Ipv6ManagedProfileRequired,
    #[error("missingTunConfiguration")]
    MissingTunConfiguration,
    #[error("invalidYAML: {0}")]
    InvalidYaml(String),
    #[error("topLevelMustBeMapping")]
    TopLevelMustBeMapping,
    #[error("unsupportedProfileExtension: {0}")]
    UnsupportedProfileExtension(String),
}

impl ProjectError {
    pub fn contract_code(&self) -> &'static str {
        match self {
            Self::SelectedNodeMustBeIPv6 => "selectedNodeMustBeIPv6",
            Self::Ipv6ManagedProfileRequired => "ipv6ManagedProfileRequired",
            Self::MissingTunConfiguration => "missingTunConfiguration",
            Self::InvalidYaml(_) => "invalidYAML",
            Self::TopLevelMustBeMapping => "topLevelMustBeMapping",
            Self::UnsupportedProfileExtension(_) => "unsupportedProfileExtension",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TunOptions {
    pub stack: String,
    pub strict_route: bool,
    pub mtu: u16,
}

impl Default for TunOptions {
    fn default() -> Self {
        Self {
            stack: "mixed".into(),
            strict_route: true,
            mtu: 1_500,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProjectOptions {
    pub routing_mode: RoutingMode,
    pub projection: ProjectionKind,
    pub selected_address: Option<String>,
    pub listen_address: String,
    pub mixed_port: u16,
    pub controller_port: u16,
    pub controller_secret: Option<String>,
    pub log_level: String,
    pub ipv6_enabled: bool,
    pub udp_enabled: bool,
    pub sniffing_enabled: bool,
    /// When set, runtime enables Mihomo TUN (Windows: requires wintun.dll + elevation).
    pub tun: Option<TunOptions>,
}

impl Default for ProjectOptions {
    fn default() -> Self {
        Self {
            routing_mode: RoutingMode::Rule,
            projection: ProjectionKind::User,
            selected_address: None,
            listen_address: "127.0.0.1".into(),
            mixed_port: 11_451,
            controller_port: 9_090,
            controller_secret: None,
            log_level: "info".into(),
            ipv6_enabled: true,
            udp_enabled: true,
            sniffing_enabled: true,
            tun: None,
        }
    }
}

/// Project a user profile into a Mihomo runtime configuration mapping.
pub fn project_runtime(
    profile_yaml: Option<&str>,
    options: &ProjectOptions,
) -> Result<Mapping, ProjectError> {
    if options.projection == ProjectionKind::PrivilegedTun && options.tun.is_none() {
        return Err(ProjectError::MissingTunConfiguration);
    }

    let mut runtime = base_runtime(options);

    if options.routing_mode == RoutingMode::Direct {
        runtime.insert(Value::from("rules"), Value::Sequence(vec![Value::from("MATCH,DIRECT")]));
        apply_tun_or_disable(&mut runtime, options);
        return Ok(runtime);
    }

    let profile_yaml = profile_yaml
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or(ProjectError::Ipv6ManagedProfileRequired)?;

    let root = parse_mapping(profile_yaml)?;
    validate_viasix_extension(&root)?;
    let selected = resolve_selected_address(options.selected_address.as_deref())?;
    let mut proxy = extract_primary_proxy(&root, &selected)?;
    let allows_udp = proxy
        .get(Value::from("udp"))
        .and_then(Value::as_bool)
        .unwrap_or(true);
    proxy.insert(
        Value::from("udp"),
        Value::Bool(options.udp_enabled && allows_udp),
    );

    runtime.insert(
        Value::from("proxies"),
        Value::Sequence(vec![Value::Mapping(proxy.clone())]),
    );

    if options.sniffing_enabled {
        runtime.insert(Value::from("sniffer"), sniffer_mapping());
    }

    install_routing_policy(&mut runtime, options.routing_mode, &proxy)?;
    apply_tun_or_disable(&mut runtime, options);

    // Explicitly ensure stripped keys are absent even if somehow present.
    for key in [
        "proxy-providers",
        "proxy-groups",
        "rule-providers",
        "sub-rules",
        "x-viasix",
    ] {
        runtime.remove(Value::from(key));
    }

    Ok(runtime)
}

fn apply_tun_or_disable(runtime: &mut Mapping, options: &ProjectOptions) {
    if let Some(tun) = &options.tun {
        let tun_map = mapping([
            ("enable", Value::Bool(true)),
            ("stack", Value::from(tun.stack.as_str())),
            ("auto-route", Value::Bool(true)),
            ("strict-route", Value::Bool(tun.strict_route)),
            ("auto-detect-interface", Value::Bool(true)),
            ("mtu", Value::from(i64::from(tun.mtu))),
            (
                "dns-hijack",
                Value::Sequence(vec![Value::from("any:53"), Value::from("tcp://any:53")]),
            ),
        ]);
        // Windows Mihomo uses Wintun when available; device name left to core.
        runtime.insert(Value::from("tun"), Value::Mapping(tun_map));
        runtime.insert(Value::from("dns"), dns_mapping(options.ipv6_enabled));
        if let Some(Value::Mapping(profile)) = runtime.get_mut(Value::from("profile")) {
            profile.insert(Value::from("store-fake-ip"), Value::Bool(true));
        }
    } else {
        runtime.insert(
            Value::from("tun"),
            Value::Mapping(mapping([("enable", Value::Bool(false))])),
        );
    }
}

fn dns_mapping(ipv6: bool) -> Value {
    Value::Mapping(mapping([
        ("enable", Value::Bool(true)),
        ("ipv6", Value::Bool(ipv6)),
        ("enhanced-mode", Value::from("fake-ip")),
        ("fake-ip-range", Value::from("198.18.0.1/16")),
        ("fake-ip-range6", Value::from("fdfe:dcba:9876::1/64")),
        ("respect-rules", Value::Bool(true)),
        (
            "default-nameserver",
            Value::Sequence(vec![Value::from("1.1.1.1"), Value::from("8.8.8.8")]),
        ),
        (
            "nameserver",
            Value::Sequence(vec![
                Value::from("https://1.1.1.1/dns-query"),
                Value::from("https://8.8.8.8/dns-query"),
            ]),
        ),
        (
            "proxy-server-nameserver",
            Value::Sequence(vec![
                Value::from("https://1.1.1.1/dns-query"),
                Value::from("https://8.8.8.8/dns-query"),
            ]),
        ),
    ]))
}

pub fn project_runtime_yaml(
    profile_yaml: Option<&str>,
    options: &ProjectOptions,
) -> Result<String, ProjectError> {
    let mapping = project_runtime(profile_yaml, options)?;
    let mut out = String::from("# Generated by ViaSix for Mihomo\n");
    let body = serde_yaml::to_string(&Value::Mapping(mapping))
        .map_err(|e| ProjectError::InvalidYaml(e.to_string()))?;
    out.push_str(&body);
    if !out.ends_with('\n') {
        out.push('\n');
    }
    Ok(out)
}

fn base_runtime(options: &ProjectOptions) -> Mapping {
    let mut profile = Mapping::new();
    profile.insert(Value::from("store-selected"), Value::Bool(false));
    profile.insert(Value::from("store-fake-ip"), Value::Bool(false));

    let mut runtime = mapping([
        ("mixed-port", Value::from(options.mixed_port as i64)),
        ("allow-lan", Value::Bool(false)),
        ("bind-address", Value::from(options.listen_address.as_str())),
        ("mode", Value::from(options.routing_mode.as_str())),
        ("log-level", Value::from(options.log_level.as_str())),
        ("ipv6", Value::Bool(options.ipv6_enabled)),
        ("unified-delay", Value::Bool(true)),
        ("tcp-concurrent", Value::Bool(true)),
        ("profile", Value::Mapping(profile)),
    ]);

    if let Some(secret) = options
        .controller_secret
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        if (1..=65_535).contains(&options.controller_port)
            && options.controller_port != options.mixed_port
        {
            runtime.insert(
                Value::from("external-controller"),
                Value::from(format!("127.0.0.1:{}", options.controller_port)),
            );
            runtime.insert(Value::from("secret"), Value::from(secret));
        }
    }

    runtime
}

fn parse_mapping(yaml: &str) -> Result<Mapping, ProjectError> {
    let value: Value =
        serde_yaml::from_str(yaml).map_err(|e| ProjectError::InvalidYaml(e.to_string()))?;
    match value {
        Value::Mapping(m) => Ok(m),
        Value::Null => Ok(Mapping::new()),
        _ => Err(ProjectError::TopLevelMustBeMapping),
    }
}

/// Enforce the `x-viasix` contract schema (`contracts/schemas/x-viasix.schema.json`):
/// only `version: 1` and `primary-server: selected-ip` are supported.
fn validate_viasix_extension(root: &Mapping) -> Result<(), ProjectError> {
    let Some(raw) = root.get(Value::from("x-viasix")) else {
        return Ok(());
    };
    let Some(extension) = raw.as_mapping() else {
        return Err(ProjectError::UnsupportedProfileExtension(
            "x-viasix must be a mapping".into(),
        ));
    };

    for key in extension.keys() {
        let name = key.as_str().unwrap_or_default();
        if !matches!(name, "version" | "primary-server") {
            return Err(ProjectError::UnsupportedProfileExtension(format!(
                "unknown key x-viasix.{name}"
            )));
        }
    }

    if extension.get(Value::from("version")).and_then(Value::as_i64) != Some(1) {
        return Err(ProjectError::UnsupportedProfileExtension(
            "x-viasix.version must be 1".into(),
        ));
    }

    if let Some(primary) = extension.get(Value::from("primary-server")) {
        if primary.as_str() != Some("selected-ip") {
            return Err(ProjectError::UnsupportedProfileExtension(
                "x-viasix.primary-server only supports selected-ip".into(),
            ));
        }
    }

    Ok(())
}

fn resolve_selected_address(selected: Option<&str>) -> Result<String, ProjectError> {
    let Some(raw) = selected.map(str::trim).filter(|s| !s.is_empty()) else {
        return Err(ProjectError::SelectedNodeMustBeIPv6);
    };
    let Ok(addr) = Ipv6Addr::from_str(raw) else {
        return Err(ProjectError::SelectedNodeMustBeIPv6);
    };
    // Reject IPv4-mapped IPv6 (::ffff:a.b.c.d): these embed an IPv4 endpoint and
    // are not a real IPv6 exit. Contract requires a genuine global IPv6 address,
    // matching Android where Java collapses such literals to Inet4Address.
    if addr.to_ipv4_mapped().is_some() {
        return Err(ProjectError::SelectedNodeMustBeIPv6);
    }
    Ok(raw.to_string())
}

fn extract_primary_proxy(root: &Mapping, selected: &str) -> Result<Mapping, ProjectError> {
    let proxies = root
        .get(Value::from("proxies"))
        .and_then(Value::as_sequence)
        .ok_or(ProjectError::Ipv6ManagedProfileRequired)?;

    let index = primary_server_index(root, proxies)
        .ok_or(ProjectError::Ipv6ManagedProfileRequired)?;

    let Value::Mapping(mut proxy) = proxies[index].clone() else {
        return Err(ProjectError::Ipv6ManagedProfileRequired);
    };

    let name = proxy
        .get(Value::from("name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let ty = proxy
        .get(Value::from("type"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    if name.is_none() || ty.is_none() {
        return Err(ProjectError::Ipv6ManagedProfileRequired);
    }

    proxy.insert(Value::from("server"), Value::from(selected));
    Ok(proxy)
}

fn primary_server_index(root: &Mapping, proxies: &[Value]) -> Option<usize> {
    if let Some(idx) = proxies.iter().position(|proxy| {
        proxy
            .as_mapping()
            .and_then(|m| m.get(Value::from("server")))
            .and_then(Value::as_str)
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
    }) {
        return Some(idx);
    }

    let selected_ip = root
        .get(Value::from("x-viasix"))
        .and_then(Value::as_mapping)
        .and_then(|m| m.get(Value::from("primary-server")))
        .and_then(Value::as_str)
        == Some("selected-ip");

    if !selected_ip {
        return None;
    }

    proxies.iter().position(|proxy| {
        let ty = proxy
            .as_mapping()
            .and_then(|m| m.get(Value::from("type")))
            .and_then(Value::as_str)
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        !matches!(ty.as_str(), "direct" | "reject" | "dns")
    })
}

fn install_routing_policy(
    runtime: &mut Mapping,
    mode: RoutingMode,
    primary: &Mapping,
) -> Result<(), ProjectError> {
    match mode {
        RoutingMode::Direct => {
            runtime.remove(Value::from("proxies"));
            runtime.insert(
                Value::from("rules"),
                Value::Sequence(vec![Value::from("MATCH,DIRECT")]),
            );
        }
        RoutingMode::Global => {
            runtime.remove(Value::from("rules"));
        }
        RoutingMode::Rule => {
            let target = primary
                .get(Value::from("name"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or(ProjectError::Ipv6ManagedProfileRequired)?;
            let rules = vec![
                "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
                "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
                "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
                "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
                "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
                "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
                "IP-CIDR6,::1/128,DIRECT,no-resolve",
                "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
                "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
            ]
            .into_iter()
            .map(Value::from)
            .chain(std::iter::once(Value::from(format!("MATCH,{target}"))))
            .collect::<Vec<_>>();
            runtime.insert(Value::from("rules"), Value::Sequence(rules));
        }
    }
    Ok(())
}

fn sniffer_mapping() -> Value {
    Value::Mapping(mapping([
        ("enable", Value::Bool(true)),
        ("force-dns-mapping", Value::Bool(true)),
        ("parse-pure-ip", Value::Bool(true)),
        ("override-destination", Value::Bool(true)),
        (
            "sniff",
            Value::Mapping(mapping([
                (
                    "HTTP",
                    Value::Mapping(mapping([
                        (
                            "ports",
                            Value::Sequence(vec![Value::from("80"), Value::from("8080-8880")]),
                        ),
                        ("override-destination", Value::Bool(true)),
                    ])),
                ),
                (
                    "TLS",
                    Value::Mapping(mapping([(
                        "ports",
                        Value::Sequence(vec![Value::from("443"), Value::from("8443")]),
                    )])),
                ),
                (
                    "QUIC",
                    Value::Mapping(mapping([(
                        "ports",
                        Value::Sequence(vec![Value::from("443"), Value::from("8443")]),
                    )])),
                ),
            ])),
        ),
    ]))
}

fn mapping<const N: usize>(entries: [(&str, Value); N]) -> Mapping {
    let mut map = Mapping::new();
    for (k, v) in entries {
        map.insert(Value::from(k), v);
    }
    map
}

#[cfg(test)]
mod extension_tests {
    use super::*;

    const INLINE_PROFILE: &str = "proxies:\n  - name: edge\n    type: vless\n    server: origin.example.com\n    port: 443\n    uuid: 11111111-1111-4111-8111-111111111111\n";

    fn options() -> ProjectOptions {
        ProjectOptions {
            selected_address: Some("2606:4700::8".into()),
            ..ProjectOptions::default()
        }
    }

    fn project(extension_yaml: &str) -> Result<Mapping, ProjectError> {
        let profile = format!("{INLINE_PROFILE}{extension_yaml}");
        project_runtime(Some(&profile), &options())
    }

    #[test]
    fn rejects_unsupported_x_viasix_version() {
        let err = project("x-viasix:\n  version: 2\n  primary-server: selected-ip\n")
            .expect_err("version 2 must be rejected");
        assert!(matches!(err, ProjectError::UnsupportedProfileExtension(_)));
        assert_eq!(err.contract_code(), "unsupportedProfileExtension");
    }

    #[test]
    fn rejects_unknown_x_viasix_key() {
        let err = project("x-viasix:\n  version: 1\n  listen-port: 1080\n")
            .expect_err("unknown key must be rejected");
        assert!(matches!(err, ProjectError::UnsupportedProfileExtension(_)));
    }

    #[test]
    fn rejects_unsupported_primary_server_value() {
        let err = project("x-viasix:\n  version: 1\n  primary-server: first-proxy\n")
            .expect_err("unsupported primary-server must be rejected");
        assert!(matches!(err, ProjectError::UnsupportedProfileExtension(_)));
    }

    #[test]
    fn accepts_supported_x_viasix_extension() {
        let root = project("x-viasix:\n  version: 1\n  primary-server: selected-ip\n")
            .expect("supported extension must project");
        assert!(root.contains_key(Value::from("proxies")));
    }

    #[test]
    fn rejects_ipv4_mapped_selected_address() {
        let opts = ProjectOptions {
            selected_address: Some("::ffff:203.0.113.8".into()),
            ..ProjectOptions::default()
        };
        let err = project_runtime(Some(INLINE_PROFILE), &opts)
            .expect_err("IPv4-mapped IPv6 must be rejected");
        assert_eq!(err, ProjectError::SelectedNodeMustBeIPv6);
    }

    #[test]
    fn accepts_genuine_ipv6_selected_address() {
        let opts = ProjectOptions {
            selected_address: Some("2606:4700::8".into()),
            ..ProjectOptions::default()
        };
        assert!(project_runtime(Some(INLINE_PROFILE), &opts).is_ok());
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde::Deserialize;
    use serde_yaml::Value;
    use std::fs;
    use std::path::{Path, PathBuf};

    #[derive(Debug, Deserialize)]
    struct CaseFile {
        id: String,
        #[serde(rename = "selectedAddress")]
        selected_address: Option<String>,
        #[serde(rename = "routingMode")]
        routing_mode: String,
        projection: String,
        #[serde(rename = "requireProfile")]
        require_profile: Option<bool>,
        expect: Expect,
    }

    #[derive(Debug, Deserialize)]
    struct Expect {
        success: bool,
        #[serde(rename = "errorCode")]
        error_code: Option<String>,
        mode: Option<String>,
        #[serde(rename = "proxyCount")]
        proxy_count: Option<usize>,
        #[serde(rename = "primaryProxyName")]
        primary_proxy_name: Option<String>,
        #[serde(rename = "primaryProxyServer")]
        primary_proxy_server: Option<String>,
        #[serde(rename = "absentKeys")]
        absent_keys: Option<Vec<String>>,
        #[serde(rename = "lastRule")]
        last_rule: Option<String>,
        #[serde(rename = "rulesMustContain")]
        rules_must_contain: Option<Vec<String>>,
        #[serde(rename = "rulesExact")]
        rules_exact: Option<Vec<String>>,
        #[serde(rename = "tunEnable")]
        tun_enable: Option<bool>,
    }

    fn monorepo_root() -> PathBuf {
        let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        for _ in 0..8 {
            if dir.join("contracts/VERSION").is_file() {
                return dir;
            }
            if !dir.pop() {
                break;
            }
        }
        panic!("contracts/VERSION not found from {}", env!("CARGO_MANIFEST_DIR"));
    }

    #[test]
    fn all_contract_projection_cases() {
        let cases_dir = monorepo_root().join("contracts/fixtures/mihomo-config/cases");
        let mut names: Vec<_> = fs::read_dir(&cases_dir)
            .expect("cases dir")
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert!(!names.is_empty(), "no contract cases");

        for name in names {
            let case_dir = cases_dir.join(&name);
            run_case(&case_dir);
        }
    }

    fn run_case(case_dir: &Path) {
        let case: CaseFile = serde_json::from_str(
            &fs::read_to_string(case_dir.join("case.json")).expect("case.json"),
        )
        .expect("decode case.json");
        let input = fs::read_to_string(case_dir.join("input.yaml")).expect("input.yaml");

        let mut options = ProjectOptions::default();
        options.routing_mode =
            RoutingMode::parse(&case.routing_mode).expect("routingMode");
        options.projection = ProjectionKind::parse(&case.projection).expect("projection");
        options.selected_address = case.selected_address.clone();

        let profile = if case.require_profile == Some(false) {
            None
        } else {
            Some(input.as_str())
        };

        match project_runtime(profile, &options) {
            Ok(root) => {
                assert!(
                    case.expect.success,
                    "case {} expected failure but succeeded",
                    case.id
                );
                assert_success(&case.id, &root, &case.expect);
            }
            Err(err) => {
                assert!(
                    !case.expect.success,
                    "case {} unexpected error: {}",
                    case.id,
                    err
                );
                assert_eq!(
                    Some(err.contract_code().to_string()),
                    case.expect.error_code,
                    "case {} error code",
                    case.id
                );
            }
        }
    }

    fn assert_success(id: &str, root: &Mapping, expect: &Expect) {
        if let Some(mode) = &expect.mode {
            assert_eq!(
                root.get(Value::from("mode")).and_then(Value::as_str),
                Some(mode.as_str()),
                "{id}: mode"
            );
        }

        let proxies = root
            .get(Value::from("proxies"))
            .and_then(Value::as_sequence)
            .cloned()
            .unwrap_or_default();
        if let Some(count) = expect.proxy_count {
            assert_eq!(proxies.len(), count, "{id}: proxyCount");
        }
        let primary = proxies.first().and_then(Value::as_mapping);
        if let Some(name) = &expect.primary_proxy_name {
            assert_eq!(
                primary
                    .and_then(|m| m.get(Value::from("name")))
                    .and_then(Value::as_str),
                Some(name.as_str()),
                "{id}: primaryProxyName"
            );
        }
        if let Some(server) = &expect.primary_proxy_server {
            assert_eq!(
                primary
                    .and_then(|m| m.get(Value::from("server")))
                    .and_then(Value::as_str),
                Some(server.as_str()),
                "{id}: primaryProxyServer"
            );
        }

        for key in expect.absent_keys.iter().flatten() {
            assert!(
                !root.contains_key(Value::from(key.as_str())),
                "{id}: expected absent {key}"
            );
        }

        let rules: Vec<String> = root
            .get(Value::from("rules"))
            .and_then(Value::as_sequence)
            .map(|seq| {
                seq.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();

        if let Some(last) = &expect.last_rule {
            assert_eq!(rules.last().map(String::as_str), Some(last.as_str()), "{id}: lastRule");
        }
        for rule in expect.rules_must_contain.iter().flatten() {
            assert!(rules.contains(rule), "{id}: missing rule {rule} in {rules:?}");
        }
        if let Some(exact) = &expect.rules_exact {
            assert_eq!(&rules, exact, "{id}: rulesExact");
        }

        if let Some(tun_enable) = expect.tun_enable {
            let actual = root
                .get(Value::from("tun"))
                .and_then(Value::as_mapping)
                .and_then(|m| m.get(Value::from("enable")))
                .and_then(Value::as_bool);
            assert_eq!(actual, Some(tun_enable), "{id}: tunEnable");
        }
    }
}
