# Mihomo config projection fixtures

跨端黄金用例：任意平台实现配置投影后，必须满足同目录 `case.json` 中的语义期望。

## 布局

```text
cases/<id>/
  input.yaml     # 用户导入的 profile（或最小子集）
  case.json      # 投影参数 + 期望
```

## case.json 字段

| 字段 | 说明 |
| --- | --- |
| `selectedAddress` | 注入的节点地址；`null` 表示不注入（直连） |
| `routingMode` | `rule` / `global` / `direct` |
| `projection` | `user`（用户态）或 `privilegedTun` |
| `requireProfile` | 默认 `true`；直连可为 `false` |
| `expect.success` | 是否应成功 |
| `expect.errorCode` | 失败时的稳定错误码（见下） |
| `expect.mode` | 运行配置 `mode` |
| `expect.proxyCount` | `proxies` 数组长度；0 表示应无 proxies 键或空 |
| `expect.primaryProxyName` / `primaryProxyServer` | 主代理 |
| `expect.absentKeys` | 不得出现的顶层键 |
| `expect.lastRule` / `rulesMustContain` / `rulesExact` | 规则断言 |
| `expect.tunEnable` | `tun.enable` |

## 稳定错误码

| errorCode | 含义 |
| --- | --- |
| `selectedNodeMustBeIPv6` | 选择了非 IPv6 |
| `ipv6ManagedProfileRequired` | 无可替换内联主代理（含 Provider-only） |
| `missingTunConfiguration` | 特权 TUN 投影缺少 TUN 配置 |
| `unsupportedProfileExtension` | `x-viasix` 扩展版本或键不受支持 |

完整 YAML 逐字节对比不作为契约（各端序列化顺序可不同）；**语义期望**才是跨端真相。
