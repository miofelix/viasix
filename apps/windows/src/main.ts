import "./styles.css";
import { listen } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
import { open as shellOpen } from "@tauri-apps/plugin-shell";
import * as api from "./api";
import { copyText, isLikelyIPv6 } from "./format";
import {
  canStartProxy,
  clearNotice,
  clearTrafficHistory,
  createInitialModel,
  exitIpEndpoints,
  filteredLogs,
  mergeBackendLog,
  profileSummaryFromBackend,
  pushLog,
  pushTrafficSample,
  readinessIssues,
  sessionPrefsFromModel,
  showNotice,
  sortedSpeedResults,
  type AppModel,
} from "./state";
import type {
  ActivityEntry,
  AppSection,
  CoreStatus,
  ExitIpMode,
  IpSourceMode,
  NodeSortKey,
  RoutingMode,
} from "./types";
import { DEFAULT_SPEED_PARAMS, SECTIONS } from "./types";
import { patchTrafficWidgets, renderSection, renderShell, syncChrome } from "./views";

const rootEl = document.querySelector<HTMLDivElement>("#app");
if (!rootEl) {
  throw new Error("#app missing");
}
const root: HTMLDivElement = rootEl;

const model: AppModel = createInitialModel();
let saveTimer: ReturnType<typeof setTimeout> | null = null;
let trafficTimer: ReturnType<typeof setInterval> | null = null;
let noticeTimer: ReturnType<typeof setTimeout> | null = null;

root.innerHTML = renderShell();
const detail = document.querySelector<HTMLDivElement>("#detail-content")!;

function scheduleSavePrefs(): void {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    void api.saveSessionPrefs(sessionPrefsFromModel(model)).catch(() => {
      // ignore when not running inside Tauri
    });
  }, 400);
}

function toast(
  message: string,
  style: "info" | "success" | "error" = "info",
  action?: "openSettings" | "gotoNodes" | "gotoProfiles",
): void {
  showNotice(model, message, style, action);
  if (noticeTimer) clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => {
    clearNotice(model);
    syncChrome(model);
  }, 5600);
  syncChrome(model);
}

function paint(options?: { preserveFocus?: boolean }): void {
  const active = document.activeElement as HTMLElement | null;
  const focusId = options?.preserveFocus && active?.id ? active.id : null;
  const selection =
    focusId && (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement)
      ? { start: active.selectionStart, end: active.selectionEnd }
      : null;

  detail.innerHTML = renderSection(model);
  syncChrome(model);
  bindSectionControls();

  if (focusId) {
    const el = document.getElementById(focusId) as HTMLInputElement | HTMLTextAreaElement | null;
    if (el) {
      el.focus();
      if (selection && "setSelectionRange" in el && selection.start != null && selection.end != null) {
        try {
          el.setSelectionRange(selection.start, selection.end);
        } catch {
          // ignore
        }
      }
    }
  }
}

function navigate(section: AppSection): void {
  if (model.section === section) return;
  model.section = section;
  scheduleSavePrefs();
  paint();
}

function isTypingTarget(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false;
  const tag = el.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable;
}

function bindShell(): void {
  document.querySelectorAll<HTMLButtonElement>(".nav-item").forEach((btn) => {
    btn.addEventListener("click", () => {
      navigate(btn.dataset.section as AppSection);
    });
  });

  root.addEventListener("click", (event) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>(
      "[data-action], [data-select-ip], [data-sort], [data-exit-mode], [data-focus-ip], [data-routing], [data-ip-source]",
    );
    if (!target) return;

    if (target.dataset.ipSource) {
      model.ipSourceMode = target.dataset.ipSource as IpSourceMode;
      scheduleSavePrefs();
      if (model.ipSourceMode === "bundled") {
        void ensureIpv6ListPath();
      }
      paint();
      return;
    }

    if (target.dataset.routing) {
      if (model.core?.running) {
        toast("请先断开连接再切换代理模式", "error");
        return;
      }
      model.routingMode = target.dataset.routing as RoutingMode;
      scheduleSavePrefs();
      pushLog(model, "info", "config", `代理模式切换为 ${model.routingMode}`);
      paint();
      return;
    }

    if (target.dataset.exitMode) {
      model.exitIpMode = target.dataset.exitMode as ExitIpMode;
      scheduleSavePrefs();
      paint({ preserveFocus: true });
      return;
    }

    if (target.dataset.sort) {
      const key = target.dataset.sort as NodeSortKey;
      if (model.nodeSortKey === key) {
        model.nodeSortAsc = !model.nodeSortAsc;
      } else {
        model.nodeSortKey = key;
        model.nodeSortAsc = key === "speed" ? false : true;
      }
      paint();
      return;
    }

    if (target.dataset.focusIp) {
      model.selectedResultIp = target.dataset.focusIp;
      paint();
      return;
    }

    if (target.dataset.selectIp) {
      void selectNode(target.dataset.selectIp);
      return;
    }

    const action = target.dataset.action;
    if (action) {
      void handleAction(action, target);
    }
  });

  window.addEventListener("keydown", (event) => {
    if (isTypingTarget(event.target)) return;
    if (event.key >= "1" && event.key <= "5" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      const index = Number(event.key) - 1;
      const section = SECTIONS[index]?.id;
      if (section) {
        event.preventDefault();
        navigate(section);
      }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      if (model.core?.running) {
        void stopCore();
      } else {
        void startCore();
      }
    }
  });
}

function bindSectionControls(): void {
  const speedIp = document.querySelector<HTMLInputElement>("#speed-ip");
  const speedDd = document.querySelector<HTMLInputElement>("#speed-dd");
  if (speedIp) {
    speedIp.addEventListener("input", () => {
      model.speedIpRange = speedIp.value;
      scheduleSavePrefs();
    });
  }
  if (speedDd) {
    speedDd.addEventListener("change", () => {
      model.speedDisableDownload = speedDd.checked;
      scheduleSavePrefs();
    });
  }

  const bindNum = (id: string, key: keyof typeof model.speedParams) => {
    const el = document.querySelector<HTMLInputElement>(id);
    if (!el) return;
    el.addEventListener("change", () => {
      const n = Number(el.value);
      if (!Number.isFinite(n)) return;
      if (key === "httping") return;
      (model.speedParams[key] as number) = Math.max(1, Math.floor(n));
      scheduleSavePrefs();
    });
  };
  bindNum("#sp-threads", "threads");
  bindNum("#sp-ping", "pingCount");
  bindNum("#sp-dn", "downloadCount");
  bindNum("#sp-dt", "downloadTime");
  bindNum("#sp-port", "port");
  const httping = document.querySelector<HTMLInputElement>("#sp-httping");
  if (httping) {
    httping.addEventListener("change", () => {
      model.speedParams.httping = httping.checked;
      scheduleSavePrefs();
    });
  }

  const profileYaml = document.querySelector<HTMLTextAreaElement>("#profile-yaml");
  const profileIp = document.querySelector<HTMLInputElement>("#profile-selected-ip");
  const profileMode = document.querySelector<HTMLSelectElement>("#profile-mode");
  if (profileYaml) {
    profileYaml.addEventListener("input", () => {
      model.profileYaml = profileYaml.value;
      scheduleSavePrefs();
      scheduleProfileSummary();
    });
  }

  const mixedPortEl = document.querySelector<HTMLInputElement>("#settings-mixed-port");
  const controllerPortEl = document.querySelector<HTMLInputElement>("#settings-controller-port");
  const closeTrayEl = document.querySelector<HTMLInputElement>("#settings-close-tray");
  const tunStackEl = document.querySelector<HTMLSelectElement>("#settings-tun-stack");
  const tunMtuEl = document.querySelector<HTMLInputElement>("#settings-tun-mtu");
  const udpEl = document.querySelector<HTMLInputElement>("#settings-udp");
  const sniffEl = document.querySelector<HTMLInputElement>("#settings-sniff");
  if (mixedPortEl) {
    mixedPortEl.addEventListener("change", () => {
      const n = Number(mixedPortEl.value);
      if (Number.isFinite(n) && n > 0 && n <= 65535) {
        model.mixedPort = Math.floor(n);
        scheduleSavePrefs();
        syncChrome(model);
      }
    });
  }
  if (controllerPortEl) {
    controllerPortEl.addEventListener("change", () => {
      const n = Number(controllerPortEl.value);
      if (Number.isFinite(n) && n > 0 && n <= 65535) {
        model.controllerPort = Math.floor(n);
        scheduleSavePrefs();
      }
    });
  }
  if (closeTrayEl) {
    closeTrayEl.addEventListener("change", () => {
      model.closeToTray = closeTrayEl.checked;
      scheduleSavePrefs();
    });
  }
  if (tunStackEl) {
    tunStackEl.addEventListener("change", () => {
      model.tunStack = tunStackEl.value || "mixed";
      scheduleSavePrefs();
    });
  }
  if (tunMtuEl) {
    tunMtuEl.addEventListener("change", () => {
      const n = Number(tunMtuEl.value);
      if (Number.isFinite(n) && n >= 1280 && n <= 9000) {
        model.tunMtu = Math.floor(n);
        scheduleSavePrefs();
      }
    });
  }
  if (udpEl) {
    udpEl.addEventListener("change", () => {
      model.udpEnabled = udpEl.checked;
      scheduleSavePrefs();
    });
  }
  if (sniffEl) {
    sniffEl.addEventListener("change", () => {
      model.sniffingEnabled = sniffEl.checked;
      scheduleSavePrefs();
    });
  }
  if (profileIp) {
    profileIp.addEventListener("input", () => {
      model.selectedAddress = profileIp.value.trim();
      scheduleSavePrefs();
      syncChrome(model);
    });
  }
  if (profileMode) {
    profileMode.addEventListener("change", () => {
      model.routingMode = profileMode.value as RoutingMode;
      scheduleSavePrefs();
      paint({ preserveFocus: true });
    });
  }

  const sysProxy = document.querySelector<HTMLInputElement>("#toggle-sys-proxy");
  if (sysProxy) {
    sysProxy.addEventListener("change", () => {
      void onSystemProxyToggle(sysProxy.checked);
    });
  }

  for (const id of ["#toggle-virt-net", "#settings-virt-net"] as const) {
    const el = document.querySelector<HTMLInputElement>(id);
    if (!el) continue;
    el.addEventListener("change", () => {
      void setVirtualNetwork(el.checked);
    });
  }

  const logQuery = document.querySelector<HTMLInputElement>("#log-query");
  const logSource = document.querySelector<HTMLSelectElement>("#log-source");
  const logLevel = document.querySelector<HTMLSelectElement>("#log-level");
  if (logQuery) {
    logQuery.addEventListener("input", () => {
      model.logFilter.query = logQuery.value;
      paint({ preserveFocus: true });
    });
  }
  if (logSource) {
    logSource.addEventListener("change", () => {
      model.logFilter.source = logSource.value as AppModel["logFilter"]["source"];
      paint();
    });
  }
  if (logLevel) {
    logLevel.addEventListener("change", () => {
      model.logFilter.level = logLevel.value as AppModel["logFilter"]["level"];
      paint();
    });
  }
}

async function handleAction(action: string, el: HTMLElement): Promise<void> {
  switch (action) {
    case "goto-nodes":
      navigate("nodes");
      return;
    case "goto-profiles":
      navigate("profiles");
      return;
    case "goto-settings":
      navigate("settings");
      return;
    case "goto-logs":
      navigate("logs");
      return;
    case "dismiss-notice":
      clearNotice(model);
      syncChrome(model);
      return;
    case "start-core":
      await startCore();
      return;
    case "stop-core":
      await stopCore();
      return;
    case "project-config":
      await projectConfig();
      return;
    case "run-speed":
      await runSpeed();
      return;
    case "stop-speed":
      await stopSpeed();
      return;
    case "test-current-node":
      await testCurrentNode();
      return;
    case "probe-connectivity":
      await probeConnectivity();
      return;
    case "refresh-core-log":
      await refreshCoreLog();
      paint();
      return;
    case "import-kernel-logs":
      await importKernelLogs();
      return;
    case "export-profile-file":
      await exportProfileFile();
      return;
    case "refresh-tun-preflight":
      await refreshTunPreflight();
      paint();
      toast(model.tunPreflight?.message || "已刷新 TUN 预检", "info");
      return;
    case "apply-preset": {
      const id = el.dataset.preset;
      const preset = model.ipPresets.find((p) => p.id === id);
      if (preset) {
        model.speedIpRange = preset.ipRange;
        scheduleSavePrefs();
        toast(`已应用预设：${preset.title}`, "info");
        paint();
      }
      return;
    }
    case "apply-best":
      await applyBest();
      return;
    case "apply-selected": {
      const ip = model.selectedResultIp || model.selectedAddress;
      if (ip) await selectNode(ip);
      return;
    }
    case "copy-selected-node": {
      const ip = model.selectedResultIp || model.selectedAddress;
      if (ip) await copyAndToast(ip);
      return;
    }
    case "copy-text": {
      const text = el.dataset.copy ?? "";
      if (text) await copyAndToast(text);
      return;
    }
    case "copy-profile-yaml":
      await copyAndToast(model.profileYaml);
      return;
    case "copy-runtime-yaml":
      await copyAndToast(model.runtimeYaml);
      return;
    case "detect-exit":
      await detectExit();
      return;
    case "probe-controller":
      await probeController();
      return;
    case "refresh-status":
      await refreshAllStatus();
      paint();
      toast("状态已刷新", "info");
      return;
    case "apply-sys-proxy":
      await applySystemProxy(true);
      return;
    case "clear-sys-proxy":
      await applySystemProxy(false);
      return;
    case "clear-logs":
      model.logs = [];
      void api.clearActivityLogs().catch(() => {
        // ignore offline
      });
      paint();
      return;
    case "import-profile":
      await importProfile();
      return;
    case "save-profile-file":
      await saveProfileToDisk();
      return;
    case "reload-profile-file":
      await reloadProfileFromDisk();
      return;
    case "reset-ipv6-list":
      await resetIpv6List();
      return;
    case "open-data-dir":
      await openDataDir();
      return;
    case "toggle-log-order":
      model.logNewestFirst = !model.logNewestFirst;
      paint();
      return;
    case "export-logs":
      await exportLogs();
      return;
    case "toggle-speed-params":
      model.showSpeedParams = !model.showSpeedParams;
      paint();
      return;
    case "cancel-confirm":
      model.confirm = null;
      syncChrome(model);
      return;
    case "confirm-dialog":
      await acceptConfirm();
      return;
    case "retry-bootstrap":
      model.bootstrapError = null;
      await bootstrap();
      return;
    default:
      return;
  }
}

async function copyAndToast(text: string): Promise<void> {
  const ok = await copyText(text);
  toast(ok ? "已复制到剪贴板" : "复制失败", ok ? "success" : "error");
}

async function selectNode(ip: string): Promise<void> {
  if (!ip) return;
  if (model.core?.running && ip !== model.selectedAddress) {
    model.confirm = {
      title: "应用节点并重新连接？",
      message: `本地代理会短暂中断，并使用 ${ip} 重新连接。`,
      confirmLabel: "应用并重新连接",
      selectIp: ip,
      reconnect: true,
    };
    syncChrome(model);
    return;
  }
  applyNode(ip);
}

function applyNode(ip: string): void {
  model.selectedAddress = ip;
  model.selectedResultIp = ip;
  scheduleSavePrefs();
  pushLog(model, "success", "speed", `已选择节点 ${ip}`);
  toast(`已选择节点 ${ip}`, "success");
  paint();
}

async function acceptConfirm(): Promise<void> {
  const dialog = model.confirm;
  model.confirm = null;
  if (!dialog?.selectIp) {
    syncChrome(model);
    return;
  }
  applyNode(dialog.selectIp);
  if (dialog.reconnect && model.core?.running) {
    await stopCore();
    await startCore();
  }
}

async function onSystemProxyToggle(enabled: boolean): Promise<void> {
  model.systemProxyEnabled = enabled;
  scheduleSavePrefs();
  // Independent of routingMode / TUN — apply immediately when user toggles.
  // Toggle-off always clears: the registry may still point at a dead port
  // (backend disable is snapshot-guarded, so user-owned proxies survive).
  if (enabled && !model.core?.running) {
    pushLog(model, "info", "proxy", "已更新系统代理偏好（启动连接时生效）");
    toast("启动连接时将启用系统代理", "info");
    paint();
    return;
  }
  await applySystemProxy(enabled);
}

async function setVirtualNetwork(enabled: boolean): Promise<void> {
  try {
    const status = await api.setVirtualNetwork(enabled);
    model.virtualNetwork = status;
    model.virtualNetworkEnabled = status.enabled;
    await refreshTunPreflight();
    pushLog(model, "info", "network", status.message);
    if (status.enabled) {
      if (model.tunPreflight && !model.tunPreflight.ready) {
        toast(model.tunPreflight.message, "error", "openSettings");
      } else {
        toast("已请求 TUN：请重新启动 Mihomo 以应用（通常需管理员）", "info", "openSettings");
      }
    } else {
      toast("已关闭虚拟网卡请求", "info");
    }
    paint();
  } catch (error) {
    model.virtualNetworkEnabled = false;
    await refreshTunPreflight();
    pushLog(model, "error", "network", `虚拟网卡切换失败：${error}`);
    toast(`虚拟网卡切换失败：${error}`, "error", "openSettings");
    paint();
  }
}

async function projectConfig(): Promise<void> {
  model.busy.project = true;
  paint();
  try {
    const mode = model.routingMode;
    const yaml = await api.projectRuntimeConfig({
      profileYaml: model.profileYaml,
      selectedAddress: mode === "direct" ? null : model.selectedAddress || null,
      routingMode: mode,
      mixedPort: model.mixedPort,
      controllerPort: model.controllerPort,
      udpEnabled: model.udpEnabled,
      sniffingEnabled: model.sniffingEnabled,
    });
    model.runtimeYaml = yaml;
    pushLog(model, "success", "config", "运行配置投影成功");
    toast("投影成功", "success");
    scheduleSavePrefs();
  } catch (error) {
    model.runtimeYaml = String(error);
    pushLog(model, "error", "config", `投影失败：${error}`);
    toast(`投影失败：${error}`, "error");
  } finally {
    model.busy.project = false;
    paint();
  }
}

let profileSummaryTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleProfileSummary(): void {
  if (profileSummaryTimer) clearTimeout(profileSummaryTimer);
  profileSummaryTimer = setTimeout(() => {
    void refreshProfileSummary();
  }, 350);
}

async function refreshProfileSummary(): Promise<void> {
  try {
    const summary = await api.summarizeProfile(model.profileYaml);
    model.profileSummary = profileSummaryFromBackend(summary);
    if (model.section === "profiles" || model.section === "overview") {
      paint({ preserveFocus: true });
    } else {
      syncChrome(model);
    }
  } catch {
    model.profileSummary = null;
  }
}

async function importProfile(): Promise<void> {
  try {
    const selected = await open({
      multiple: false,
      filters: [
        { name: "YAML", extensions: ["yaml", "yml"] },
        { name: "All", extensions: ["*"] },
      ],
    });
    if (!selected || Array.isArray(selected)) return;
    const path = typeof selected === "string" ? selected : String(selected);
    const text = await api.readTextFile(path);
    model.profileYaml = text;
    scheduleSavePrefs();
    await refreshProfileSummary();
    pushLog(model, "success", "config", `已导入配置：${path}`);
    toast("已导入连接配置", "success");
    if (model.section !== "profiles") navigate("profiles");
    else paint();
  } catch (error) {
    // dialog cancel throws or returns null depending on platform
    const msg = String(error);
    if (/cancel/i.test(msg)) return;
    pushLog(model, "error", "config", `导入失败：${error}`);
    toast(`导入失败：${error}`, "error");
  }
}

async function saveProfileToDisk(): Promise<void> {
  try {
    const path = await api.saveProfileFile(model.profileYaml);
    scheduleSavePrefs();
    toast(`已保存 ${path}`, "success");
  } catch (error) {
    toast(`保存失败：${error}`, "error");
  }
}

async function reloadProfileFromDisk(): Promise<void> {
  try {
    const yaml = await api.loadProfileFile();
    if (!yaml?.trim()) {
      toast("数据目录中没有 profile.yaml", "info");
      return;
    }
    model.profileYaml = yaml;
    scheduleSavePrefs();
    await refreshProfileSummary();
    toast("已从数据目录加载 profile.yaml", "success");
    paint();
  } catch (error) {
    toast(`加载失败：${error}`, "error");
  }
}

async function ensureIpv6ListPath(): Promise<void> {
  try {
    model.ipv6ListPath = await api.ensureIpv6List();
  } catch {
    model.ipv6ListPath = "";
  }
}

async function resetIpv6List(): Promise<void> {
  try {
    model.ipv6ListPath = await api.resetIpv6List();
    toast("已重置内置 IPv6 列表", "success");
    paint();
  } catch (error) {
    toast(`重置失败：${error}`, "error");
  }
}

async function openDataDir(): Promise<void> {
  try {
    const path = model.dataDir || (await api.openDataDir());
    model.dataDir = path;
    await shellOpen(path);
  } catch (error) {
    toast(`无法打开数据目录：${error}`, "error");
  }
}

async function startCore(): Promise<void> {
  const issues = readinessIssues(model);
  if (issues.length > 0) {
    toast(issues[0].message, "error", issues[0].action);
    paint();
    return;
  }
  if (!canStartProxy(model)) return;

  // Backend-aligned preflight (ports distinct + IPv6-first selection).
  try {
    await api.validateStartConfig({
      routingMode: model.routingMode,
      selectedAddress:
        model.routingMode === "direct" ? null : model.selectedAddress || null,
      mixedPort: model.mixedPort,
      controllerPort: model.controllerPort,
    });
  } catch (error) {
    toast(`配置校验失败：${error}`, "error");
    pushLog(model, "error", "config", `配置校验失败：${error}`);
    paint();
    return;
  }

  model.busy.start = true;
  paint();
  try {
    const mode = model.routingMode;
    const status = await api.startCore({
      profileYaml: model.profileYaml,
      selectedAddress: mode === "direct" ? null : model.selectedAddress || null,
      routingMode: mode,
      enableSystemProxy: model.systemProxyEnabled,
      mixedPort: model.mixedPort,
      controllerPort: model.controllerPort,
      tunStack: model.tunStack,
      tunMtu: model.tunMtu,
      udpEnabled: model.udpEnabled,
      sniffingEnabled: model.sniffingEnabled,
    });
    model.core = status;
    pushLog(model, status.running ? "success" : "warn", "core", status.message);
    toast(status.message, status.running ? "success" : "error");
    await refreshProxyStatus();
    if (status.running) {
      clearTrafficHistory(model);
      startTrafficPolling();
      void refreshCoreLog();
      // Post-start controller health (macOS probes when running).
      try {
        const health = await api.probeController();
        model.controller = health;
        pushLog(
          model,
          health.ok ? "success" : "warn",
          "core",
          `启动后探测：${health.message}`,
        );
      } catch (error) {
        pushLog(model, "warn", "core", `启动后探测失败：${error}`);
      }
    }
  } catch (error) {
    pushLog(model, "error", "core", `启动失败：${error}`);
    toast(`启动失败：${error}`, "error");
    void refreshCoreLog();
  } finally {
    model.busy.start = false;
    paint();
  }
}

async function stopCore(): Promise<void> {
  model.busy.stop = true;
  paint();
  try {
    const status = await api.stopCore();
    model.core = status;
    stopTrafficPolling();
    pushLog(model, "info", "core", status.message);
    toast(status.message, "info");
    await refreshProxyStatus();
  } catch (error) {
    pushLog(model, "error", "core", `停止失败：${error}`);
    toast(`停止失败：${error}`, "error");
  } finally {
    model.busy.stop = false;
    paint();
  }
}

async function applySystemProxy(enabled: boolean): Promise<void> {
  model.busy.sysProxy = true;
  syncChrome(model);
  try {
    const status = await api.setSystemProxy({
      enabled,
      host: "127.0.0.1",
      port: model.mixedPort,
    });
    model.proxy = status;
    model.systemProxyEnabled = enabled ? status.enabled : false;
    scheduleSavePrefs();
    pushLog(model, "info", "proxy", status.message);
    toast(status.message, "success");
  } catch (error) {
    pushLog(model, "error", "proxy", `系统代理操作失败：${error}`);
    toast(`系统代理操作失败：${error}`, "error");
  } finally {
    model.busy.sysProxy = false;
    paint();
  }
}

async function detectExit(): Promise<void> {
  model.busy.exitIp = true;
  paint();
  try {
    const endpoints = exitIpEndpoints(model.exitIpMode);
    const result = await api.detectExitIp(endpoints);
    model.exitIp = result;
    pushLog(model, "success", "network", `${result.message}（来源 ${result.source}）`);
    toast(`出口 ${result.ip}`, "success");
  } catch (error) {
    pushLog(model, "error", "network", `出口检测失败：${error}`);
    toast(`出口检测失败：${error}`, "error");
  } finally {
    model.busy.exitIp = false;
    paint();
  }
}

async function probeController(): Promise<void> {
  model.busy.health = true;
  paint();
  try {
    const health = await api.probeController();
    model.controller = health;
    pushLog(model, health.ok ? "success" : "warn", "core", health.message);
    toast(health.message, health.ok ? "success" : "error");
  } catch (error) {
    pushLog(model, "error", "core", `探测失败：${error}`);
    toast(`探测失败：${error}`, "error");
  } finally {
    model.busy.health = false;
    paint();
  }
}

async function runSpeed(): Promise<void> {
  const useBundled = model.ipSourceMode === "bundled";
  if (!useBundled && !model.speedIpRange.trim()) {
    toast("请填写 IP / CIDR", "error");
    return;
  }
  model.busy.speed = true;
  model.speedMessage = useBundled
    ? "测速进行中（内置 IPv6 列表）…"
    : "测速进行中，请稍候…";
  paint();
  try {
    if (useBundled) await ensureIpv6ListPath();
    const response = await api.runSpeedTest(
      {
        ipRange: useBundled ? null : model.speedIpRange.trim() || null,
        disableDownload: model.speedDisableDownload,
        httping: model.speedParams.httping,
        threads: model.speedParams.threads,
        pingCount: model.speedParams.pingCount,
        downloadCount: model.speedParams.downloadCount,
        downloadTime: model.speedParams.downloadTime,
        port: model.speedParams.port,
      },
      useBundled,
    );
    model.speedResults = response.results;
    model.speedResultsAt = response.cancelled ? model.speedResultsAt : Date.now();
    model.speedMessage = response.message;
    model.nodeSortKey = "latency";
    model.nodeSortAsc = true;
    if (!response.cancelled && response.results[0]) {
      model.selectedResultIp = response.results[0].ip;
    }
    pushLog(
      model,
      response.cancelled ? "warn" : "success",
      "speed",
      response.message,
    );
    scheduleSavePrefs();
    toast(response.message, response.cancelled ? "info" : "success");
  } catch (error) {
    model.speedMessage = `测速失败：${error}`;
    pushLog(model, "error", "speed", model.speedMessage);
    toast(model.speedMessage, "error");
  } finally {
    model.busy.speed = false;
    paint();
  }
}

async function stopSpeed(): Promise<void> {
  try {
    const ok = await api.stopSpeedTest();
    if (ok) {
      model.speedMessage = "正在停止测速…";
      toast("已请求停止测速", "info");
      paint({ preserveFocus: true });
    } else {
      toast("当前没有进行中的测速", "info");
    }
  } catch (error) {
    toast(`停止测速失败：${error}`, "error");
  }
}

async function testCurrentNode(): Promise<void> {
  if (!isLikelyIPv6(model.selectedAddress)) {
    toast("请先选择有效 IPv6 入口", "error", "gotoNodes");
    return;
  }
  model.busy.nodeTest = true;
  model.nodeTestMessage = `正在测试 ${model.selectedAddress}…`;
  paint();
  try {
    const response = await api.testCurrentNode({
      selectedAddress: model.selectedAddress,
      disableDownload: true,
      threads: Math.min(model.speedParams.threads, 80),
      pingCount: model.speedParams.pingCount,
      port: model.speedParams.port,
    });
    const row = response.results[0];
    model.nodeTestMessage = row
      ? `${response.message} · ${row.latency} / 丢包 ${row.loss}`
      : response.message;
    toast(model.nodeTestMessage, response.cancelled ? "info" : "success");
  } catch (error) {
    model.nodeTestMessage = `当前节点测速失败：${error}`;
    toast(model.nodeTestMessage, "error");
  } finally {
    model.busy.nodeTest = false;
    paint();
  }
}

async function probeConnectivity(): Promise<void> {
  model.busy.connectivity = true;
  model.connectivityMessage = "正在通过本地混合端口探测…";
  paint();
  try {
    const result = await api.probeConnectivity({ mixedPort: model.mixedPort });
    model.connectivityMessage = result.message;
    toast(result.message, result.ok ? "success" : "error");
  } catch (error) {
    model.connectivityMessage = `代理连通性失败：${error}`;
    toast(model.connectivityMessage, "error");
  } finally {
    model.busy.connectivity = false;
    paint();
  }
}

async function refreshCoreLog(): Promise<void> {
  try {
    model.coreLog = await api.tailCoreLog(240);
  } catch (error) {
    model.coreLog = `读取内核日志失败：${error}`;
  }
}

async function importKernelLogs(): Promise<void> {
  try {
    // Prefer first-class backend ingest (shared shaping with start_core failure path).
    const added = await api.ingestCoreLog(80);
    try {
      model.coreLog = await api.tailCoreLog(240);
    } catch {
      // ignore tail failure if ingest worked
    }
    // Reload activity so UI matches backend stream (events may have been missed offline).
    try {
      const entries = await api.listActivityLogs();
      for (const entry of entries) {
        mergeBackendLog(model, entry);
      }
    } catch {
      // browser preview
    }
    if (added === 0) {
      toast("内核日志为空（启动 Mihomo 后才会写入）", "info");
    } else {
      toast(`已并入 ${added} 行内核日志`, "success");
    }
    paint();
  } catch (error) {
    toast(`并入内核日志失败：${error}`, "error");
  }
}

async function exportProfileFile(): Promise<void> {
  try {
    const path = await save({
      defaultPath: "profile.yaml",
      filters: [{ name: "YAML", extensions: ["yaml", "yml"] }],
    });
    if (!path) return;
    await api.writeTextFile(path, model.profileYaml);
    pushLog(model, "success", "config", `已导出 profile → ${path}`);
    toast(`已导出 ${path}`, "success");
  } catch (error) {
    const msg = String(error);
    if (/cancel/i.test(msg)) return;
    toast(`导出失败：${error}`, "error");
  }
}

async function refreshTunPreflight(): Promise<void> {
  try {
    model.tunPreflight = await api.tunPreflight();
  } catch {
    model.tunPreflight = null;
  }
}

async function applyBest(): Promise<void> {
  const sorted = sortedSpeedResults(model);
  if (sorted.length === 0) {
    toast("没有可应用的测速结果", "error");
    return;
  }
  // Prefer lowest latency when sorted that way; otherwise first visible row.
  const best =
    model.nodeSortKey === "latency" && model.nodeSortAsc
      ? sorted[0]
      : [...model.speedResults].sort((a, b) => {
          const an = Number(a.latency.replace(/[^\d.]/g, "")) || 1e9;
          const bn = Number(b.latency.replace(/[^\d.]/g, "")) || 1e9;
          return an - bn;
        })[0];
  await selectNode(best.ip);
}

async function exportLogs(): Promise<void> {
  try {
    // Prefer backend TSV export (stable columns; full activity store).
    let text = "";
    try {
      text = await api.exportActivityLogText();
    } catch {
      const lines = filteredLogs(model).map(
        (e) =>
          `${e.at}\t${e.level}\t${e.source}\t${e.message.replace(/\t/g, " ").replace(/\n/g, " ")}`,
      );
      text = `at_ms\tlevel\tsource\tmessage\n${lines.join("\n")}\n`;
    }
    if (!text.trim() || text.trim().split("\n").length <= 1) {
      toast("没有可导出的日志", "error");
      return;
    }
    try {
      const path = await save({
        defaultPath: "viasix-activity.tsv",
        filters: [
          { name: "TSV", extensions: ["tsv", "txt"] },
          { name: "All", extensions: ["*"] },
        ],
      });
      if (path) {
        await api.writeTextFile(path, text);
        toast(`已导出日志到 ${path}`, "success");
        pushLog(model, "info", "app", `已导出活动日志 → ${path}`);
        return;
      }
    } catch (error) {
      const msg = String(error);
      if (!/cancel/i.test(msg)) {
        // fall through to clipboard
      } else {
        return;
      }
    }
    const ok = await copyText(text);
    if (ok) {
      toast("已复制活动日志到剪贴板", "success");
    } else {
      toast("导出失败", "error");
    }
  } catch (error) {
    toast(`导出失败：${error}`, "error");
  }
}

async function refreshCoreStatus(): Promise<void> {
  try {
    model.core = await api.coreStatus();
  } catch {
    // browser preview
  }
}

async function refreshProxyStatus(): Promise<void> {
  try {
    model.proxy = await api.systemProxyStatus();
    if (model.proxy.managedByViasix) {
      model.systemProxyEnabled = model.proxy.enabled;
    }
  } catch (error) {
    pushLog(model, "warn", "proxy", `系统代理状态不可用：${error}`);
  }
}

async function refreshVirtualNetwork(): Promise<void> {
  try {
    model.virtualNetwork = await api.virtualNetworkStatus();
    model.virtualNetworkEnabled = model.virtualNetwork.enabled;
    await refreshTunPreflight();
  } catch (error) {
    pushLog(model, "warn", "network", `虚拟网卡状态不可用：${error}`);
  }
}

async function refreshTraffic(): Promise<void> {
  try {
    model.traffic = await api.sampleTraffic();
    if (model.traffic.live) {
      pushTrafficSample(model, model.traffic);
    }
    if (model.section === "overview") {
      patchTrafficWidgets(model, detail);
      syncChrome(model);
    }
  } catch {
    model.traffic = null;
  }
}

function startTrafficPolling(): void {
  if (trafficTimer) return;
  void refreshTraffic();
  trafficTimer = setInterval(() => {
    void refreshTraffic();
  }, 1200);
}

function stopTrafficPolling(): void {
  if (trafficTimer) {
    clearInterval(trafficTimer);
    trafficTimer = null;
  }
  model.traffic = null;
  clearTrafficHistory(model);
}

async function refreshAllStatus(): Promise<void> {
  await Promise.all([refreshCoreStatus(), refreshProxyStatus(), refreshVirtualNetwork()]);
  if (model.core?.running) {
    startTrafficPolling();
  }
}

async function restorePrefs(): Promise<void> {
  try {
    const prefs = await api.loadSessionPrefs();
    if (prefs.profileYaml?.trim()) model.profileYaml = prefs.profileYaml;
    if (prefs.selectedAddress?.trim()) model.selectedAddress = prefs.selectedAddress;
    if (
      prefs.routingMode === "rule" ||
      prefs.routingMode === "global" ||
      prefs.routingMode === "direct"
    ) {
      model.routingMode = prefs.routingMode;
    }
    model.systemProxyEnabled = !!prefs.systemProxyEnabled;
    if (prefs.lastSpeedIpRange?.trim()) model.speedIpRange = prefs.lastSpeedIpRange;
    model.speedDisableDownload = prefs.disableDownload !== false;

    model.speedParams = {
      threads: prefs.speedThreads ?? DEFAULT_SPEED_PARAMS.threads,
      pingCount: prefs.speedPingCount ?? DEFAULT_SPEED_PARAMS.pingCount,
      downloadCount: prefs.speedDownloadCount ?? DEFAULT_SPEED_PARAMS.downloadCount,
      downloadTime: prefs.speedDownloadTime ?? DEFAULT_SPEED_PARAMS.downloadTime,
      httping: prefs.speedHttping ?? DEFAULT_SPEED_PARAMS.httping,
      port: prefs.speedPort ?? DEFAULT_SPEED_PARAMS.port,
    };
    if (prefs.exitIpMode === "auto" || prefs.exitIpMode === "ipv4" || prefs.exitIpMode === "ipv6") {
      model.exitIpMode = prefs.exitIpMode;
    }
    if (
      prefs.lastSection === "overview" ||
      prefs.lastSection === "nodes" ||
      prefs.lastSection === "profiles" ||
      prefs.lastSection === "logs" ||
      prefs.lastSection === "settings"
    ) {
      model.section = prefs.lastSection;
    }
    if (prefs.mixedPort && prefs.mixedPort > 0) model.mixedPort = prefs.mixedPort;
    if (prefs.controllerPort && prefs.controllerPort > 0) {
      model.controllerPort = prefs.controllerPort;
    }
    if (typeof prefs.closeToTray === "boolean") model.closeToTray = prefs.closeToTray;
    if (prefs.tunStack?.trim()) model.tunStack = prefs.tunStack.trim();
    if (prefs.tunMtu && prefs.tunMtu >= 1280 && prefs.tunMtu <= 9000) {
      model.tunMtu = prefs.tunMtu;
    }
    if (typeof prefs.udpEnabled === "boolean") model.udpEnabled = prefs.udpEnabled;
    if (typeof prefs.sniffingEnabled === "boolean") {
      model.sniffingEnabled = prefs.sniffingEnabled;
    }
    if (prefs.ipSourceMode === "custom" || prefs.ipSourceMode === "bundled") {
      model.ipSourceMode = prefs.ipSourceMode;
    }
  } catch {
    // browser preview keeps defaults
  }
}

async function hydrateBackendLogs(): Promise<void> {
  try {
    const entries = await api.listActivityLogs();
    for (const entry of entries) {
      mergeBackendLog(model, entry);
    }
  } catch {
    // offline preview
  }
}

async function bindBackendEvents(): Promise<void> {
  try {
    await listen<ActivityEntry>("activity-log", (event) => {
      mergeBackendLog(model, event.payload);
      if (model.section === "logs") {
        paint({ preserveFocus: true });
      }
    });
    await listen<string>("tray-action", (event) => {
      if (event.payload === "start") {
        void startCore();
      }
    });
    await listen<CoreStatus>("core-stopped", (event) => {
      model.core = event.payload;
      stopTrafficPolling();
      paint();
      toast(event.payload.message || "已从托盘停止代理", "info");
    });
    await listen<CoreStatus>("core-exited", (event) => {
      model.core = event.payload;
      stopTrafficPolling();
      void refreshProxyStatus().finally(() => paint());
      pushLog(model, "error", "core", event.payload.message || "内核已意外退出");
      toast(event.payload.message || "内核已意外退出", "error");
    });
  } catch {
    // not in tauri
  }
}

async function bootstrap(): Promise<void> {
  bindShell();
  paint();
  pushLog(model, "info", "app", "正在准备 ViaSix…");

  try {
    try {
      model.version = await api.appVersion();
    } catch {
      model.version = "dev";
    }
    try {
      model.dataDir = await api.dataDirPath();
    } catch {
      model.dataDir = "";
    }
    await restorePrefs();
    // Prefer on-disk profile.yaml when session prefs still hold the example stub.
    try {
      const disk = await api.loadProfileFile();
      if (disk?.trim() && model.profileYaml.includes("origin.example.com")) {
        model.profileYaml = disk;
      }
    } catch {
      // ignore
    }
    await hydrateBackendLogs();
    await bindBackendEvents();
    try {
      model.ipPresets = await api.listIpPresets();
    } catch {
      model.ipPresets = [];
    }
    await ensureIpv6ListPath();
    await refreshProfileSummary();
    await refreshAllStatus();
    await refreshCoreLog();
    model.bootstrapped = true;
    model.bootstrapError = null;
    pushLog(model, "success", "app", "初始化完成");
    if (!isLikelyIPv6(model.selectedAddress) && model.routingMode !== "direct") {
      pushLog(model, "warn", "app", "当前未选择有效 IPv6 入口");
    }
    paint();
    scheduleSavePrefs();
  } catch (error) {
    model.bootstrapError = String(error);
    pushLog(model, "error", "app", `初始化失败：${error}`);
    toast(`初始化失败：${error}`, "error");
    paint();
  }
}

void bootstrap();
