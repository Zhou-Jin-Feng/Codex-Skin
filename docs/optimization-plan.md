# 稳定性与性能优化执行计划

编写日期：2026-10-04。基线版本：`2.0.1`（`68cbd51`）。范围以 Windows 为主，macOS 在第 6 阶段跟进。

本文档的结论来自静态阅读代码，未在本机复现或实测。标注“待取证”的条目须先完成第 0 阶段再动手。

## 执行约定

- 遵守 `AGENTS.md`：各阶段只写实现，不新增测试、不跑测试、不做可视化验证；测试统一放在第 7 阶段，得到明确指示后执行。
- 每个提交点是一个可独立回退的最小单元，提交信息沿用仓库的 Conventional Commits 风格。
- 修改 `runtime/` 后运行 `node tools/sync-runtime-assets.mjs`，同步产物与源码放在同一个提交里。
- 不修改 WindowsApps、官方 Codex profile 或官方二进制文件；不新增管理员权限需求。
- 提交、推送、发布都要等用户明确同意。

## 问题清单

### A. 皮肤容易掉

| 编号 | 现象/根因 | 位置 |
| --- | --- | --- |
| A1 | 目标页注入成功后进入 `sessions`，watcher 不再核验皮肤是否仍在；之后任何一次丢失都不会自动修复 | `windows/scripts/injector.mjs:2158` |
| A2 | 页面重载后的补注入失败只记日志，不重试，也不把会话移出 `sessions` | `injector.mjs:1964-1978` |
| A3 | 提前注入脚本每 250ms 轮询一次、10 秒后放弃；Codex 冷启动慢时错过时机。随后的加载回退只做“绑定媒体文件”，它要求皮肤已安装，于是超时，落入 A2 | `injector.mjs:1265-1266`、`1971` |
| A4 | 视频主题完全不做提前注入，每次重载都要等 load 事件、再等 250ms、再做一次解码校验，空白期长且容易失败 | `injector.mjs:1221`、`1215` |
| A5 | CDP 浏览器身份变化（Codex 自更新重启、`app.relaunch()`）时 watcher 以退出码 3 退出，没有任何组件把它拉起来 | `injector.mjs:2016-2020`、`2048-2051` |
| A6 | 页面内只有 30 秒一次的兜底检查会补回被覆盖的 `adoptedStyleSheets`；部件监听只挂在安装时的那个 `body` 上 | `runtime/renderer-inject.js:1314`、`1299-1313` |
| A7 | 点击 Windows 右下角“Codex 已完成”通知，会新开一个没有皮肤的 Codex 窗口（见下节） | `start-dream-skin.ps1:84-90`、`259` |

### A7 根因：通知激活绕开了皮肤 profile

Chromium 136 及以上版本对默认数据目录会忽略 `--remote-debugging-port`（CHANGELOG #235、#363 已实测）。所以皮肤版 Codex 是用独立 profile 启动的：

```text
ChatGPT.exe --remote-debugging-address=127.0.0.1 --remote-debugging-port=<port>
            --user-data-dir=%LOCALAPPDATA%\CodexDreamSkin\cdp-profile
```

Electron 的单实例锁（`requestSingleInstanceLock`，底层是 Chromium ProcessSingleton）**按 user-data-dir 区分**。点击通知时，Windows 按包的 AppUserModelId 激活应用，启动的是不带任何参数的 `ChatGPT.exe`：

1. 新进程使用默认数据目录，找不到皮肤实例持有的锁；
2. 于是它自己成为另一个主实例，用官方 profile 打开新窗口；
3. 这个实例没有 CDP 端口，watcher 无法连接，所以窗口没有皮肤。

用户从开始菜单或任务栏点 Codex 也走同一条路径，属于同一类问题（A5 之外的另一种“Codex 在管理器外启动”）。

待取证：通知激活时的完整命令行（是否带 `codex://` 深链或 launch 参数），以及皮肤实例收到 `second-instance` 转发后能否跳转到对应对话。

### B. 速度慢

| 编号 | 现象/根因 | 位置 |
| --- | --- | --- |
| B1 | Codex 流式输出时，`body` 子树监听大约每 80ms 触发一次完整的 `refreshParts`：十几次全文档 `querySelectorAll`，外加对每个候选节点逐层上溯父节点。这很可能就是生成回答时卡顿的原因 | `renderer-inject.js:1214`、`986-1065` |
| B2 | watcher 每 30 秒整读一次背景文件并计算 SHA256（视频最大 128MB）；其实已有按大小和修改时间的变更检测 | `injector.mjs:77`、`839`、`2068` |
| B3 | 视频主题每次页面重载都重做一遍解码校验 | `injector.mjs:1215` |
| B4 | 管理器每个操作都新起一个 `powershell.exe` 并加载几千行脚本，PowerShell 5.1 冷启动约 1–3 秒 | `src/PowerShellRunner.cs:70` |
| B5 | 一次操作内反复调用 `Get-CimInstance Win32_Process`、`Get-AppxPackage`、`Get-AppxPackageManifest`，每次几百毫秒 | `common-windows.ps1:784`、`747`、`1412` |
| B6 | 启动流程里有固定等待，以及 200ms 粒度的轮询 | `start-dream-skin.ps1:288`、`502`、`582` |

## 阶段总览

| 阶段 | 目标 | 解决 | 提交点 |
| --- | --- | --- | --- |
| 0 | 基线与现场取证 | 为 A7、B1、B4 提供数据 | C0.1 |
| 1 | watcher 自愈 | A1 A2 A3 B2 | C1.1–C1.3 |
| 2 | 页面内渲染性能与自愈 | B1 A6 | C2.1–C2.2 |
| 3 | 守护进程（通知点击、Codex 自重启） | A7 A5 | C3.1、C3.3（C3.2 延后） |
| 4 | 视频主题 | A4 B3 | C4.1–C4.2 |
| 5 | 管理器响应速度 | B4 B5 B6 | C5.1–C5.3 |
| 6 | macOS 对齐 | 把第 1、4 阶段移植过去 | C6.1 |
| 7 | 测试、验收与发版（需明确指示） | — | C7.1–C7.3 |

第 1、2 阶段互不依赖，可以并行；第 3 阶段依赖第 0 阶段的取证结果。

---

## 第 0 阶段：基线与现场取证

需要用户在本机配合，不改产品逻辑。

### C0.1 `chore(tools): add runtime diagnostics capture`

已完成，新增两个只读工具：

- `tools/diag-runtime.ps1`：主脚本，四种模式，每次运行都把 JSON 报告存到 `%TEMP%\codex-dream-skin-diag-<模式>-<时间>.json`（可用 `-OutFile` 指定）。
  - `Snapshot`（默认）：列出所有 `ChatGPT.exe`，标出主进程、所用 profile（`dream-skin` / `default` / `other`）、调试端口、父进程和完整命令行；汇总 `state.json`、注入器进程是否存活；读取页面内皮肤状态；统计注入器日志里的关键事件。
  - `Processes`：每 300ms 轮询一次，打印新启动或退出的 Codex 进程，用来抓通知点击时的启动参数。
  - `Renderer`：在页面内采样 N 秒，统计每秒部件刷新次数和长任务。
  - `Manager`：计时 PowerShell 空启动、只加载公共脚本、`Status -Quick -SkipThemes`、`ListThemes`。
- `tools/diag-renderer.mjs`：由主脚本调用，经 state.json 记录的 port/browserId 连接页面。只连 127.0.0.1，browserId 不一致时不连接页面，不读取页面文本。快照模式会调用 5 次皮肤自己的部件刷新来测耗时，这个刷新与页面每次 DOM 变化时执行的是同一个幂等过程。

由用户执行的取证步骤：

```powershell
# 1. 皮肤正常显示时先拍一次快照
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1

# 2. 启动后去点右下角的“已完成”通知
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Processes -Seconds 60

# 3. 空闲时采样一次，再在 Codex 生成长回答时采样一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Renderer -Seconds 20 -Label idle
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Renderer -Seconds 20 -Label streaming

# 4. 管理器只读操作计时
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Manager
```

产出：把结果补进本文档的“取证记录”一节，据此确认第 3 阶段的转发方式和第 2、5 阶段的优化收益。

---

## 第 1 阶段：watcher 自愈（`windows/scripts/injector.mjs`）

### C1.1 `fix(injector): verify live sessions and reinject lost skins`

- 新增 `SESSION_HEALTH_MS`（建议 5000）。主循环里对每个已连接会话做一次很轻的 `Runtime.evaluate`，返回：
  - 未暂停时：`state.revision === loadedPayload.revision`、`!window[DISABLED_KEY]`、样式仍挂载、`imageReady` 或视频已就绪、根节点 `data-dream-skin="active"`；
  - 暂停时：上述标记都已清除。
- 结果不符就调用 `applyLoadedToSession` 或 `removeFromSession` 修复；连续失败 3 次后关闭会话、移出 `sessions`，并调用 `rejectTarget`，下一轮自动重连。
- `attachLoadFallback` 里的补注入失败后，同样把会话标记为不健康，不再只记日志。
- 记录 `repairs` 计数，写进日志（每 30 秒最多一条）。

### C1.2 `fix(injector): keep early payload armed until the shell appears`

- `earlyPayloadFor` 改为：先尝试安装一次；失败则用 `MutationObserver` 监听 `document` 子树，直到识别出 Codex 界面或 `generation` 变化为止。保留一个宽松上限（建议 120 秒），作为防泄漏兜底。
- 加载回退中，如果页面里没有匹配 revision 的 state，就走完整的 `applyLoadedToSession`，不再只调 `bindMediaFileToSession`。

### C1.3 `perf(injector): drop periodic full-media hashing`

- 去掉 `STRONG_THEME_AUDIT_MS` 的周期性全量读取和哈希；只在 `readThemeSourceStamp` 变化时调用 `loadTheme`。
- 时间戳里加入文件标识（`fs.stat(..., { bigint: true })` 的 `ino`），防止原子替换后大小和修改时间恰好不变的情况。
- 如果仍需兜底，可改为 10 分钟一次低频审计，并且只哈希 `theme.json` 和 `theme.css`，不哈希媒体文件。

**风险与回退**：C1.1 的修复路径如果和管理器的实时应用（`begin-operation` / 单次运行）同时操作同一页面，可能重复注入。实现时以 `revision` 作幂等判断：已匹配就不重复注入。

---

## 第 2 阶段：页面内渲染（`runtime/renderer-inject.js`，改完同步）

### C2.1 `perf(renderer): throttle part refresh and skip message-stream mutations`

- `partObserver` 回调先检查变更记录：如果所有记录都发生在已标记的 `message` 部件内部，或在 `thread` 内容的文本区里，并且没有新增或删除会改变部件结构的节点，就直接跳过。
- 调度改为“尾部防抖 200ms + 最长等待 800ms”，执行时优先用 `requestIdleCallback`（设 `timeout`）。
- `refreshSurfaces` 中逐层上溯父节点的循环，改成每轮先给候选节点打临时标记，再用 `closest` 一次查到底，避免候选数 × 深度的开销。
- `detectScope` 和 `refreshParts` 共用同一轮的查询结果，不重复 `querySelector`。
- 用 `metrics.partPasses` 对比改动前后（取证数据见第 0 阶段）。

### C2.2 `fix(renderer): repair adopted stylesheet and re-observe replaced body`

- 每次部件刷新时顺带做一次 `ensureStyle()`；检查 `includes`，开销很小。这样样式表被覆盖后，最迟在下一次 DOM 变化时就能补回。
- `rootObserver` 额外监听 `documentElement` 的直接子节点（`childList`，不含 subtree）；发现 `body` 被替换时，重新挂上 `partObserver` 并安排一次完整刷新。
- 30 秒兜底定时器保留。

---

## 第 3 阶段：外部实例守护（解决 A7、A5）

新增一个“守护进程”，由 `start-dream-skin.ps1` 在启动 watcher 时一并拉起，PID 和启动时间写进 `state.json`。

生命周期只跟随皮肤会话，不随登录自启：

- 与 watcher 同时启动；
- watcher 因身份变化退出时，守护进程继续存活，负责 C3.3 的恢复；
- 皮肤 profile 的 Codex 主进程消失超过 60 秒，且 watcher 已不在运行时，守护进程自行退出；
- 恢复原始外观、暂停后停止 watcher 时，一并停止守护进程。

### C3.1 `feat(windows): add Codex instance sentinel`

- 新增 `windows/scripts/instance-sentinel.ps1`：
  - 用 `Register-CimIndicationEvent` 订阅 `__InstanceCreationEvent WITHIN 1`，过滤 `Win32_Process` 中的 `ChatGPT.exe`。这种方式不需要管理员权限；`Win32_ProcessStartTrace` 需要管理员，所以不用。
  - 只处理同时满足以下条件的进程：
    - 可执行文件是已验证的 Store 包里的 `app\ChatGPT.exe`；
    - 是主进程（命令行不含 `--type=`）；
    - 命令行里没有指向 `cdp-profile` 的 `--user-data-dir`；
    - 创建时间在 5 秒以内。
- 处理流程（仅当皮肤实例仍存活，且已核验 CDP 身份时）：
  1. 记录该进程命令行里除可执行文件以外的参数；
  2. 结束这个刚启动的进程（此时它还没有用户输入）；
  3. 以 `--user-data-dir=<cdp-profile>` 加上原参数再启动一次。皮肤实例持有锁，所以这次启动会触发 `second-instance` 转发后自行退出；
  4. 调用 `Invoke-DreamSkinCodexWindowActivation`，把皮肤窗口带到前台。
- 安全约束：
  - 同一时间窗口内最多处理 3 次，防止出现循环；
  - 皮肤实例不存在时不做任何处理（交给 C3.2）；
  - 暂停状态或用户关闭该功能时不处理；
  - 所有动作写入 `sentinel.log`。
- 已知限制：WMI 轮询有最多 1 秒延迟，可能短暂闪出一个窗口。

### C3.2 外部启动接管：本轮不做，列入后续

- 原设想：皮肤实例不存在时，外部启动的 Codex（开始菜单、任务栏、通知）按开关决定是否改用皮肤 profile 重启，默认关闭。
- 已确定守护进程只在皮肤会话期间运行，皮肤实例不在时守护进程通常也不在，这个开关几乎没有生效的时机，所以本轮不实现。
- 本轮的替代做法：管理器状态检测到“Codex 在运行，但不是皮肤 profile”时，显示“当前 Codex 未带皮肤”，并提供“重新应用皮肤”。
- 以后如果改为随登录常驻，再恢复这个提交点。

### C3.3 `fix(windows): recover watcher after Codex self-restart`

- Codex 自更新或 `app.relaunch()` 会沿用原命令行重启，因此新进程仍带着皮肤 profile 和调试端口，只是浏览器身份变了。
- watcher 因身份变化退出（退出码 3）后，由守护进程负责恢复：确认新端点的监听进程属于已验证包，且命令行带着皮肤 profile，然后以 `-ConnectOnly` 方式重新执行一次启动协调，换上新 watcher。
- 新进程如果不带皮肤 profile（例如用户手动关掉后从开始菜单重开），不做恢复，按 C3.2 的替代做法在管理器里提示。
- 身份的核验仍然放在 PowerShell 侧完成，watcher 不自行采纳新身份，保持现有的安全边界。

**待取证项（第 0 阶段）**：如果通知激活使用 COM 激活器，命令行里只有 `-Embedding` 之类的参数，原参数就无法转发。那时退而求其次：结束新进程并激活皮肤窗口，不跳转到对应对话。

---

## 第 4 阶段：视频主题

### C4.1 `perf(injector): cache video decode probe per browser session`

- 以 `artKey + browserId` 为键缓存解码校验结果，同一个浏览器会话里每个文件只校验一次；主题文件变化或浏览器身份变化时清空缓存。

### C4.2 `fix(injector): early-install styles for video themes`

- 视频主题也注册提前注入：先装好样式和根状态（背景暂用主题主色或封面帧），等加载完成后再绑定视频文件。这样可以去掉重载时的空白期。
- 需要先确认 renderer 允许“没有媒体的视频主题”这个中间状态；必要时在 `renderer-inject.js` 里补一个占位分支，并同步到各平台。

---

## 第 5 阶段：管理器响应速度

### C5.1 `perf(windows): memoize package and process queries per action`

- 在单次脚本运行内缓存 `Get-DreamSkinCodexInstall` 的结果，以及 `Win32_Process` 的查询快照；同一操作里需要“最新状态”的地方，显式传参刷新。
- `Status -Quick` 走最短路径：只读状态文件、只查一次进程、只做一次渲染探测。

### C5.2 `perf(manager): reuse a resident PowerShell worker`

- 采用常驻 `powershell.exe` 子进程方案（不在管理器进程内跑 Runspace）。
- `PowerShellRunner` 增加常驻工作进程模式：启动一次 `powershell.exe`，预先加载公共脚本，之后通过 stdin/stdout 按行收发 JSON 请求。保留现有的超时、结束进程和错误编码语义。
- 工作进程随管理器退出而结束，不在后台残留。
- 工作进程异常或超时时，结束它并退回到现在的“每次新起进程”模式。
- 先只把 `Status`、`ListThemes` 这类只读操作迁过去；写操作在验证后再迁。

### C5.3 `perf(windows): replace fixed sleeps with condition waits`

- 把 `start-dream-skin.ps1` 中的固定等待改成条件等待，例如等 watcher 写出就绪标记、等端点可连接。

---

## 第 6 阶段：macOS 对齐

### C6.1 `fix(macos): port watcher self-healing and video early install`

- 渲染脚本已通过 `sync-runtime-assets` 共享，第 2 阶段的改动自动带过去。
- `macos/scripts/injector.mjs` 是独立实现，需要移植 C1.1–C1.3 和 C4.1–C4.2。
- macOS 没有通知激活绕开 profile 的问题（需取证确认），第 3 阶段不移植。

---

## 第 7 阶段：测试、验收与发版（需明确指示后执行）

### C7.1 `test: cover watcher self-healing and renderer throttling`

可扩展的现有测试入口：

- `windows/tests/injector-watch-lifecycle.test.mjs`：模拟会话丢失皮肤和补注入失败，断言能修复、会被移出并重连；
- `windows/tests/injector-bootstrap.test.mjs`：提前注入超过 10 秒后仍能完成安装；
- `windows/tests/renderer-inject.test.mjs`、`tools/renderer-runtime.test.mjs`：消息流变化不触发部件刷新，`body` 被替换后能重新监听，样式表被覆盖后能修复；
- 新增 `windows/tests/instance-sentinel.tests.ps1`：命令行判定、频率限制、皮肤实例不存在时不动作。

### C7.2 验收清单（真机）

1. 点击“已完成”通知后，不再出现无皮肤的窗口；皮肤窗口被激活（取证允许的话，还会跳转到对应对话）。
2. 生成长回答期间，`partPasses` 每秒次数相比基线明显下降，输入无卡顿感。
3. 手动执行 `location.reload()` 20 次，皮肤每次都在；冷启动时 Codex 加载超过 10 秒，皮肤仍能自动出现。
4. 用 DevTools 清空 `adoptedStyleSheets` 后，皮肤在 1 秒内恢复。
5. Codex 自更新重启后，皮肤自动恢复，不需要打开管理器。
6. 视频主题重载后无明显空白，日志中解码校验每个会话只出现一次。
7. 管理器打开到状态显示、应用主题，耗时相比基线下降（记录前后数值）。

### C7.3 `chore: release v2.1.0`

- 版本号定为 `2.1.0`（新增守护进程，属于功能版本）。
- 更新 `windows/VERSION`、`macos/VERSION`、`runtime-version.ps1`、两个平台 `injector.mjs` 中的 `SKIN_VERSION`、README 的版本号和安装包名、两个平台的 CHANGELOG，并新增 `.github/release-notes/v2.1.0.md`。
- 改完后全仓搜索 `2.0.1`，确认没有漏改的版本常量（参考 `f172ede` 的改动范围）。

---

## 已确定的决策（2026-10-04）

1. **外部启动接管**：默认关闭。由于第 2 条，本轮不实现（见 C3.2），改为在管理器里提示。
2. **守护进程生命周期**：只跟随皮肤会话运行，不随登录自启。它负责通知点击的转发和 Codex 自重启后的恢复。
3. **管理器工作进程**：常驻 `powershell.exe` 子进程。
4. **版本号**：`2.1.0`。

## 取证记录

（第 0 阶段完成后填写）
