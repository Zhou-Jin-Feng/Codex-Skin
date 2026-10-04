# 稳定性与性能优化执行计划

编写日期：2026-10-04，同日按用户反馈调整优先级。基线版本：`2.0.1`（`68cbd51`），目标版本：`2.1.0`。范围以 Windows 为主，macOS 在第 6 阶段跟进。

根因分析来自静态阅读代码，配合第 0 阶段的现场取证。标注“待计时确认”的条目，要等 C0.2 的分阶段计时数据。

## 目标

1. **应用皮肤要快**：皮肤连接正常时，点击后 3 秒内看到新皮肤；需要重启 Codex 时 1 分钟内完成，通常 30 秒左右。现状是 3–5 分钟。
2. **动态换肤**：切换主题不重启 Codex。
3. **托盘常驻**：关闭管理器窗口时缩到托盘，像 QQ 那样在后台挂着；托盘里可以快速切换主题、暂停/继续。
4. **皮肤不掉**：点通知、从开始菜单打开 Codex、Codex 自更新重启之后，皮肤要么保持，要么自动恢复。

## 进度

| 提交点 | 内容 | 状态 |
| --- | --- | --- |
| C0.1 | 取证脚本 | 已提交（`a6c2413`） |
| C0.2 | 分阶段计时日志 | 已提交，真机已产出计时数据 |
| C1.1–C1.3 | 托盘常驻、托盘快速切换与暂停、开机自启 | 已提交（三项合为一个提交），真机体验中 |
| C2.1 | 连接正常时跳过应用前的完整状态查询 | 已提交，真机确认热切换 3 秒内生效 |
| C2.2 | Node 运行时校验缓存、存档去重预筛 | 已提交 |
| C2.5 | 打开管理器时先显示缓存的主题列表和已验证的状态 | 已提交，现有测试通过，待真机体验 |
| C4.1 | 确定需要重启时，跳过单独的启动检查和注定失败的直接换肤 | 已提交；首版端口判断有误未生效，已改为读取监听表，待真机复测 |
| C4.5 | 已同意强制重启时快速关闭 Codex | 已提交，同上 |
| C4.6 | 启动脚本内只解析一次已注册的 Codex 安装 | 已提交，同上 |
| C4.7 | 脚本已完成但 PowerShell 进程不退出时，不再等到 5 分钟超时 | 已提交，真机确认进程确实滞留（`host lingered`），宽限缩短为 1.5 秒 |
| C2.3、C2.4 | 跳过重复媒体校验、常驻 PowerShell | 视后续计时再定 |
| C4.2–C4.4 | 校验前激活窗口、视频解码缓存、条件等待 | 未开始 |
| C3.3 | 点通知、从开始菜单打开的 Codex 并入皮肤窗口 | 已实现，现有测试通过，待真机点通知验证 |
| 第 3 阶段其余 | 连接保持健康（C3.1、C3.2、C3.4、C3.5） | 用户要求暂缓 |

C2.1 的快速预检与脚本侧一样核对运行时指纹：正在运行的注入器必须来自与当前管理器相同的运行时，否则走原来的完整状态查询。

构建时发现仓库原有的偶发测试失败：`tests/StatusReadTests.cs` 中“一边读取被阻塞时另一边先显示”的测试，只给 8 秒等待，在本机测试进程冷启动时偶尔超时（未改动的 `a6c2413` 同样复现）。已在跑这组测试前预热 PowerShell，并把等待上限放宽到 14 秒（低于 15 秒的读取超时），被测行为不变。

## 执行约定

- 遵守 `AGENTS.md`：各阶段只写实现，不新增测试、不跑测试、不做可视化验证；测试统一放在第 7 阶段，得到明确指示后执行。允许做不运行程序的静态检查（脚本语法解析、C# 编译到临时目录）。
- 每个提交点是一个可独立回退的最小单元，提交信息沿用仓库的 Conventional Commits 风格。
- 修改 `runtime/` 后运行 `node tools/sync-runtime-assets.mjs`，同步产物与源码放在同一个提交里。
- 不修改 WindowsApps、官方 Codex profile 或官方二进制文件；不新增管理员权限需求。
- 提交、推送、发布都要等用户明确同意；用户已同意每完成一个提交点就直接提交（推送和发布仍需另行确认）。
- 本机构建：系统 PATH 里的 Node 24 旁边缺少 `LICENSE`，构建改用保存在 `build\node-runtime\` 的 Node 22（原取自已删除的 `D:\CodexDreamSkinManager`，签名有效）：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -SkillRoot .\windows -NodeExecutable .\build\node-runtime\node.exe
  ```

## 已确定的决策

| 事项 | 决定 | 日期 |
| --- | --- | --- |
| 外部打开的 Codex 是否自动接管 | 做成开关，默认关闭 | 2026-10-04 |
| 守护功能放在哪里 | 放进常驻托盘的管理器：托盘开着就生效，退出托盘就停止（取代“只跟随皮肤会话”的旧决定） | 2026-10-04 |
| 管理器调用脚本提速 | 优先让热切换只剩一次脚本调用；常驻 PowerShell 子进程视计时结果再做 | 2026-10-04 |
| 开机自启 | 默认关闭，在托盘菜单里给开关；开启后启动时直接进托盘 | 2026-10-04 |
| 先计时再优化 | 是，先加分阶段计时日志（C0.2） | 2026-10-04 |
| 版本号 | `2.1.0` | 2026-10-04 |
| 页面内渲染性能 | 用户反馈换肤对 Codex 本身速度没有明显影响，降为可选 | 2026-10-04 |

## 现状与根因

### C. 应用皮肤慢（本轮首要问题）

点“应用皮肤”有两条路线：

**热路线**（皮肤连接正常）：查状态 → 写入主题 → 通过调试端口把新皮肤推进 Codex 窗口，不重启。代码已支持，问题是额外开销多：

| 编号 | 开销 | 位置 |
| --- | --- | --- |
| C1 | 每次应用前先跑一次完整的状态查询（新起 PowerShell，约 1.5 秒） | `src/MainWindow.cs:1203` |
| C2 | `Get-DreamSkinNodeRuntime` 每次调用都做 Authenticode 签名校验和两次 node 探测，没有缓存；一次应用里会被调用多次 | `windows/scripts/common-windows.ps1:702` |
| C3 | 每次应用都给全部存档图片计算 SHA256，只为去重 | `windows/scripts/manager-actions.ps1:870` |
| C4 | 内置主题和“我的”主题在导入时已经校验过，应用时又对复制出的文件重复做元数据校验（node 子进程），视频还要再做一次解码校验 | `windows/scripts/theme-windows.ps1:652` |

**重启路线**（连接不正常）：查状态 → 检查能否启动 → 弹窗确认 → 关闭 Codex → 带调试端口重新打开（最多等 45 秒）→ 启动注入器 → 校验皮肤（最多重试 90 秒）。外层超时 5 分钟。

| 编号 | 问题 | 位置 |
| --- | --- | --- |
| C5 | 校验要求 Codex 窗口真的显示在屏幕上；被管理器窗口挡住或最小化时会一直重试到 90 秒超时，再回滚重来。这很可能是 3–5 分钟的主因（待计时确认） | `start-dream-skin.ps1:537-583` |
| C6 | 视频主题在未连接时要“先连接、校验视频、再重启”，重启两次 | `src/MainWindow.cs:1217-1227` |
| C7 | 查状态、检查启动、启动各是一个 PowerShell 进程，每个都要重新加载几千行脚本 | `src/DreamSkinService.cs:509-527` |
| C8 | 启动流程里有固定等待和 200ms 粒度的轮询 | `start-dream-skin.ps1:288`、`502`、`582` |

**为什么经常走重启路线**：只要 Codex 不是由管理器打开的，连接就不正常。例如从任务栏或开始菜单打开 Codex、点通知开出的窗口（A7）、Codex 自更新重启（A5）、注入器进程退出、管理器更新后运行时指纹变化。

### A. 皮肤容易掉

| 编号 | 现象/根因 | 位置 |
| --- | --- | --- |
| A1 | 目标页注入成功后进入 `sessions`，watcher 不再核验皮肤是否仍在；之后任何一次丢失都不会自动修复 | `windows/scripts/injector.mjs:2158` |
| A2 | 页面重载后的补注入失败只记日志，不重试，也不把会话移出 `sessions` | `injector.mjs:1964-1978` |
| A3 | 提前注入脚本每 250ms 轮询一次、10 秒后放弃；Codex 冷启动慢时错过时机，随后的加载回退又只做“绑定媒体文件”，于是落入 A2 | `injector.mjs:1265-1266`、`1971` |
| A4 | 视频主题完全不做提前注入，每次重载都要等 load 事件、再等 250ms、再做一次解码校验 | `injector.mjs:1221`、`1215` |
| A5 | CDP 浏览器身份变化（Codex 自更新重启、`app.relaunch()`）时 watcher 以退出码 3 退出，没有任何组件把它拉起来 | `injector.mjs:2016-2020`、`2048-2051` |
| A6 | 页面内只有 30 秒一次的兜底检查会补回被覆盖的 `adoptedStyleSheets`；部件监听只挂在安装时的那个 `body` 上 | `runtime/renderer-inject.js:1314`、`1299-1313` |
| A7 | 点击右下角“Codex 已完成”通知，会新开一个没有皮肤的 Codex 窗口（已取证确认，见下节） | `start-dream-skin.ps1:84-90`、`259` |

### A7 根因：通知激活绕开了皮肤 profile

Chromium 136 及以上版本对默认数据目录会忽略 `--remote-debugging-port`（CHANGELOG #235、#363 已实测），所以皮肤版 Codex 用独立 profile 启动：

```text
ChatGPT.exe --remote-debugging-address=127.0.0.1 --remote-debugging-port=<port>
            --user-data-dir=%LOCALAPPDATA%\CodexDreamSkin\cdp-profile
```

Electron 的单实例锁按 user-data-dir 区分。点击通知时，Windows 推送通知服务（`WpnUserService`）直接启动 `ChatGPT.exe type=click&tag=<id>`，不带 `--user-data-dir`：新进程找不到皮肤实例持有的锁，于是用默认 profile 自己成为主实例。它没有调试端口，注入器连不上，所以窗口没有皮肤。从开始菜单或任务栏打开 Codex 也是同一个原因。

### B. 其他性能项

| 编号 | 现象/根因 | 位置 |
| --- | --- | --- |
| B1 | Codex 输出回答时，部件监听最多约每 80ms 触发一次完整刷新（实测单次约 11ms）。用户反馈无明显影响，降为可选 | `renderer-inject.js:1214`、`986-1065` |
| B2 | watcher 每 30 秒整读一次背景文件并计算 SHA256（视频最大 128MB） | `injector.mjs:77`、`839`、`2068` |
| B3 | 视频主题每次页面重载都重做一遍解码校验 | `injector.mjs:1215` |

## 阶段总览

| 阶段 | 目标 | 解决 | 提交点 |
| --- | --- | --- | --- |
| 0 | 取证与计时 | 为 C 类问题提供数据 | C0.1（已完成）、C0.2 |
| 1 | 托盘常驻 | 目标 3 | C1.1–C1.3 |
| 2 | 热切换提速 | C1–C4 | C2.1–C2.4 |
| 3 | 连接保持健康 | A1–A5、A7，减少走重启路线的次数 | C3.1–C3.5 |
| 4 | 重启路线提速 | C5–C8 | C4.1–C4.4 |
| 5 | 页面内渲染（可选） | A6、B1 | C5.1–C5.2 |
| 6 | macOS 对齐 | 共享部分 | C6.1 |
| 7 | 测试、验收与发版（需明确指示后执行） | — | C7.1–C7.3 |

第 1、2 阶段先做；第 3 阶段的守护功能依赖第 1 阶段的托盘常驻。

---

## 第 0 阶段：取证与计时

### C0.1 `chore(tools): add runtime diagnostics capture`（已完成）

- `tools/diag-runtime.ps1`：四种模式（`Snapshot`、`Processes`、`Renderer`、`Manager`），每次运行把 JSON 报告存到 `%TEMP%\codex-dream-skin-diag-<模式>-<时间>.json`，可用 `-OutFile` 指定。
- `tools/diag-renderer.mjs`：由主脚本调用，经 `state.json` 记录的 port/browserId 只读连接页面；browserId 不一致时不连接页面，不读取页面文本。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Processes -Seconds 60
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Renderer -Seconds 20 -Label idle
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\diag-runtime.ps1 -Mode Manager
```

### C0.2 `feat(windows): log per-stage timings for skin operations`

- 统一写入 `%LOCALAPPDATA%\CodexDreamSkin\timing.log`，超过 512KB 时轮换为 `timing.log.1`。写日志失败不影响任何操作。
- 管理器（C#）：
  - 每次脚本调用记录脚本名、动作、耗时、退出码或超时；
  - 每个界面操作记录开始、各阶段提示文字出现的时间点、总耗时和结果（成功、失败、取消）。
- 脚本（PowerShell）：新增 `Write-DreamSkinTimingMark`，在 `start-dream-skin.ps1` 和 `manager-actions.ps1 -Action ApplyTheme` 的关键节点打点：拿到操作锁、解析 Codex 安装、核验 CDP、关闭 Codex、启动 Codex、CDP 就绪、启动注入器、每次校验的结果、写入主题、实时应用结果。
- 用法：下次应用慢的时候，把 `timing.log` 发过来即可定位卡在哪一步。

---

## 第 1 阶段：托盘常驻

### C1.1 `feat(manager): minimize to tray on close`

- 点窗口的关闭按钮时隐藏到托盘，不退出；第一次隐藏时弹一次气泡提示“管理器仍在后台运行”，之后不再提示。
- 托盘图标左键单击或双击打开窗口；右键菜单里的“退出”才真正退出。注入器是独立进程，退出管理器不影响已显示的皮肤。
- 单实例唤醒：再次启动管理器时，通过命名事件通知已运行的实例显示窗口（窗口隐藏时旧的按标题查找方式不可靠），旧方式保留为兜底。
- 新增启动参数 `--tray`：启动时不显示窗口，只进托盘，但照常在后台读取状态和主题列表。
- Windows 注销或关机时直接退出，不拦截。
- 托盘由独立的 `TrayHost` 类负责，`MainWindow` 只暴露“关闭时隐藏”的开关和几个供托盘调用的方法；测试里直接创建 `MainWindow` 时不会生成托盘图标。

### C1.2 `feat(manager): quick theme switch and pause from tray`

- 托盘右键菜单：
  - 第一行显示状态和当前主题（不可点击）；
  - “快速切换”：最近使用的主题（最多 5 个）、“我的主题”、“内置主题”三组；
  - “暂停皮肤”/“继续皮肤”；
  - “打开管理器”、“开机自启”、“退出”。
- 托盘里的切换和暂停走窗口里同一套操作逻辑；需要重启 Codex 等需要确认的情况，先把窗口显示出来再弹确认框。
- 窗口隐藏时操作完成，用托盘气泡显示结果。
- 菜单打开时在后台刷新一次状态，避免显示过期的“暂停/继续”。
- 最近使用的主题记录在 `%LOCALAPPDATA%\CodexDreamSkin\manager-settings.json`。

### C1.3 `feat(manager): optional start with Windows`

- 开关写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值为 `"<管理器路径>" --tray`；读取时以注册表为准，路径不是当前程序时视为未开启。
- 开启时如果发现旧版 PowerShell 托盘的开机启动快捷方式（`启动\Codex Dream Skin.lnk`），询问后一并移除，避免出现两个托盘图标。

---

## 第 2 阶段：热切换提速

目标：连接正常时，点击后 3 秒内看到新皮肤。

### C2.1 `perf(manager): skip the full status read before a healthy live apply`

- 管理器用 C# 直接做一次快速预检（约几十毫秒），全部满足才跳过应用前的完整状态查询：
  - `state.json` 可读，有 port、browserId 和注入器 PID；
  - 注入器进程存在，启动时间与记录一致；
  - `127.0.0.1:<port>/json/version` 返回的 browserId 与记录一致。
- 任一项不满足就走原来的完整状态查询。即使预检通过，`ApplyTheme` 脚本内部仍会完整核验注入器身份；实时应用失败时，按原逻辑转入启动恢复流程，安全边界不变。

### C2.2 `perf(windows): cache node runtime validation and prefilter archive dedupe`

- `Get-DreamSkinNodeRuntime` 在同一个脚本进程内缓存校验结果，以文件路径、大小、修改时间为键，任一变化就重新校验。
- 存档去重先按文件大小分组，只给大小相同的文件计算哈希。

### C2.3 `perf(windows): skip redundant media validation for validated themes`（视 C0.2 计时结果）

- 应用内置主题或“我的”主题时，如果源文件的哈希命中“已校验媒体”缓存，就跳过复制后的元数据重复校验和视频解码重复校验。
- 缓存键包含文件哈希和运行时指纹；运行时更新后缓存自动失效。

### C2.4 `perf(manager): reuse a resident PowerShell worker`（视 C0.2 计时结果）

- 常驻一个 `powershell.exe` 子进程，预先加载公共脚本，通过 stdin/stdout 按行收发 JSON 请求；工作进程随管理器退出而结束。
- 先只迁移只读操作；工作进程异常时自动退回“每次新起进程”。

### C2.5 `perf(manager): start from the cached catalog and a verified status`

- 实测：管理器冷启动时，状态查询和主题列表两次 PowerShell 调用各约 8.4 秒，期间所有按钮不可用。
- 每次成功读取后，把状态和主题列表的结果缓存到状态目录（`manager-status-cache.json`、`manager-catalog-cache.json`）。
- 启动时先显示缓存的主题列表；快速预检确认会话健康时，用缓存的静态信息（支持的操作、版本号）加上从磁盘新读的运行、暂停、当前主题和取景参数组成状态，界面立刻可以操作；最新主题列表在后台刷新，不占用忙碌标记。
- 预检不通过就走原来的完整读取。缓存只在安装了完整运行时的布局里读写，测试夹具不受影响。

---

## 第 3 阶段：连接保持健康

托盘常驻后，管理器负责在后台看住皮肤连接，让换肤尽量都走热路线。

### C3.1 `fix(injector): self-heal live sessions`

- 每 5 秒对已连接页面做一次轻量检查（版本号、样式挂载、图片或视频就绪、根节点标记），不符就重新注入；连续 3 次失败则断开该页面，下一轮自动重连。
- 页面重载后的补注入失败时，同样把会话标为不健康。
- 提前注入改为一直等到识别出 Codex 界面为止（保留 120 秒防泄漏上限）；加载回退在页面里没有皮肤时走完整注入。
- 去掉每 30 秒一次的媒体全量哈希，只在文件大小、修改时间或文件标识变化时重新校验。

### C3.2 `feat(manager): restart the injector without restarting Codex`

- 管理器每 10 秒做一次 C2.1 的快速预检。发现注入器退出、但 Codex 调试端口仍在且身份一致时，在后台以“只连接”方式重新启动注入器，不重启 Codex，也不弹窗。
- 运行时指纹变化（管理器更新后）也走这条路，替换掉旧的注入器。
- 连续失败时退避重试，并在托盘气泡里提示一次。

### C3.3 `feat(manager): fold new default-profile Codex launches into the skinned instance`

- 管理器内用 WMI 内部事件（`__InstanceCreationEvent WITHIN 1`，无需管理员权限）监听新启动的 `ChatGPT.exe`，只处理满足以下全部条件的进程：
  - 可执行文件位于 `WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe`；
  - 命令行没有任何开关（排除 `--type=` 子进程、带 `--user-data-dir` 的进程、更新器等），参数只能是空、通知激活串 `type=click&tag=<id>` 或单个 `codex://` 链接；
  - 创建时间在 15 秒以内（含事件延迟）。
- 皮肤实例（命令行带 `state.json` 记录的皮肤 profile 的主进程）存活时：
  1. 先读出新进程的包身份（AUMID），再结束它和它刚派生的子进程；结束前核对启动时间和映像路径，不会误杀复用的 PID。
  2. 以皮肤 profile 加原参数通过包激活重新启动一次，交给皮肤实例的单实例锁转发后自行退出；包激活不可用时改为直接启动。
  3. 把皮肤窗口切到前台。
- 安全约束：30 秒内最多处理 3 次，超过暂停 5 分钟；如果转发启动的进程丢了皮肤 profile（某些 Codex 版本会改写激活参数），本次会话改为只切换窗口，避免循环；皮肤实例不在时不处理（留给 C3.4）；暂停皮肤不影响合并，因为另开一个窗口在任何情况下都不是想要的结果。
- 托盘菜单开关“新开的 Codex 并入皮肤窗口”，默认开启，保存在 `manager-settings.json`。
- 每次决定写入状态目录的 `sentinel.log`（超过 256KB 轮换）。
- 已知限制：WMI 事件最多约 1 秒延迟，可能短暂闪出一个窗口；能否按 tag 跳到通知对应的对话取决于 Codex 对转发参数的处理，需真机确认；只在管理器运行（含缩在托盘）时生效。

### C3.4 `feat(manager): optionally take over externally launched Codex`

- 托盘菜单增加开关“外部打开的 Codex 自动接管”，默认关闭。
- 开启后，皮肤实例不存在时外部打开的 Codex 会被关闭，改走标准启动流程，用皮肤 profile 重新打开。
- 关闭时只在管理器状态里提示“当前 Codex 未带皮肤”，并提供“重新应用皮肤”。

### C3.5 `fix(manager): recover after Codex restarts itself`

- Codex 自更新或 `app.relaunch()` 会沿用原命令行重启，新进程仍带皮肤 profile 和调试端口，只是浏览器身份变了，注入器因此退出（A5）。
- 管理器确认新端点的监听进程属于已验证包、且命令行带皮肤 profile 后，以“只连接”方式换上新注入器。身份核验仍在 PowerShell 侧完成，注入器不自行采纳新身份。

---

## 第 4 阶段：重启路线提速

目标：需要重启 Codex 时 1 分钟内完成，通常 30 秒左右。

实测（2026-10-04 12:35，Codex 从外部重开、注入器成了孤儿）：从点击到生效约 75 秒，其中等用户确认 6.6 秒。主要耗时：

| 步骤 | 耗时 | 原因 |
| --- | --- | --- |
| 尝试直接换肤 | 8.5 秒 | 快速状态只看注入器进程，报“运行中”，实际 Codex 已无调试端口 |
| 单独的启动检查 | 5.4 秒 | 随后的启动脚本又把同样的检查做了一遍 |
| 关闭 Codex | 17.7 秒 | 关窗口后仍有无窗口的进程（后台实例、点通知开出的隐藏实例），固定等满 15 秒才强制结束 |
| 启动脚本里的检查 | 5.4 秒 | 已注册 Codex 安装信息被解析三次，每次约 1 秒 |
| 启动 Codex 到调试端口就绪 | 13.2 秒 | Codex 冷启动 |
| 首次校验通过 | 9.1 秒 | 等 Codex 界面加载 |

### C4.1 `perf(manager): skip the futile live apply and startup check when a restart is certain`

- 快速预检除“健康”外，还能确定“记录的调试端口上没有任何监听”，并检测 Codex Store 包进程是否在运行；两者同时成立时必须重启。
- 这时应用流程不再尝试直接换肤，确认重启前也不再单独跑启动检查；端口上只要有监听（哪怕身份未验证），仍交给启动脚本判断。
- 预检只在安装了完整运行时的布局里给出结论；启动脚本带授权参数运行时仍会重新核验是否真的需要重启。

### C4.5 `perf(windows): close Codex quickly once a restart is authorized`

- 已获得强制授权时：有窗口的进程发关闭请求后最多等 3 秒；全部进程都没有可关的窗口时直接强制结束。未授权时保持 15 秒。

### C4.6 `perf(windows): resolve registered Codex packages once per startup`

- 启动脚本内缓存 `Get-DreamSkinRegisteredCodexInstalls` 的结果（60 秒有效），只在 `start-dream-skin.ps1` 中开启，其他脚本和测试仍每次重新查询。

### C4.7 `fix(manager): stop waiting once a script finished but its host lingers`

- 现象（同一次实测）：启动脚本 12:37:12 写下最后一个计时点“done”，皮肤已校验通过，但管理器之后再没有记录这次脚本调用结束，也没做操作完成后的状态刷新，界面一直停在“正在连接皮肤服务并确认显示…”，直到 5 分钟超时。这与用户最初反馈的“应用要等 3–5 分钟”吻合：皮肤早已生效，管理器在空等。
- 已排除：注入器作为子进程继承管道（同样方式复现，管理器 5 秒内正常返回）。疑似根因：只有重启路线会经 COM（`ApplicationActivationManager`）拉起 Codex，PowerShell 进程可能在退出时清理 COM 对象卡住。尚未在真机上确认。
- 修复：脚本包装层在最外层 `finally` 中写出完成标记，因此两路输出都收到标记即说明脚本已结束。此后最多再等 5 秒让进程正常退出；仍不退出就按输出里是否有错误标记判定结果，结束滞留的进程，并在 `timing.log` 记下“host lingered”。
- 验证：用写出完成标记后睡眠 30 秒的模拟脚本，管理器 5.6 秒返回，结果判定正确，进程已被结束；现有 90 个 C# 单元测试通过。
- 真机复测（13:08）：启动脚本 13:09:28 完成，`timing.log` 记下 `exit 0 inferred; host lingered after completion and was stopped`，管理器 13:09:36 显示“已应用”，证实进程滞留确实存在。之后把宽限从 5 秒缩短为 1.5 秒（正常进程写完标记后几毫秒内就会退出）。

### 2026-10-04 13:08 重启路线复测

从点击到“已应用”共 91 秒，其中用户确认重启约 14 秒；对比此前 75 秒外加最长 5 分钟空等。

| 步骤 | 耗时 | 说明 |
| --- | --- | --- |
| 读取状态 + 直接换肤失败 + 单独检查 | 约 24 秒 | C4.1 未生效：探测端口时 Windows 对本机被拒连接会重试约 2 秒，400 毫秒超时把“无人监听”误判为“可能在监听”。已改为读取 TCP 监听表（毫秒级），下次应省掉约 16 秒 |
| 启动脚本内的检查 | 7.4 秒 | |
| 关闭 Codex | 6.5 秒 | 此前 17.7 秒 |
| 启动 Codex 到调试端口就绪 | 15.5 秒 | Codex 冷启动 |
| 首次校验通过 | 13.6 秒 | 等 Codex 界面加载 |
| 进程滞留后收尾 | 5 秒 | 已缩短为 1.5 秒 |

### C4.2 `fix(windows): bring Codex to front before renderer verification`

- 启动注入器后、第一次校验前，先把 Codex 窗口切到前台，并把管理器窗口移到后面或最小化，避免校验因窗口不可见而空等。
- 校验时窗口仍不可见，就按“皮肤已推送、等窗口可见时再确认”处理，不再回滚重启。

### C4.3 `perf(windows): cache video decode capability`

- 按 Codex 版本和视频编码缓存解码校验结果，避免视频主题为了校验而多重启一次。

### C4.4 `perf(windows): replace fixed sleeps with condition waits`

- 把固定等待改成条件等待（注入器写出就绪标记、端点可连接）；CDP 轮询从 200ms 改为先快后慢。

---

## 第 5 阶段：页面内渲染（`runtime/renderer-inject.js`，改完同步）

### C5.1 `fix(renderer): repair adopted stylesheet and re-observe replaced body`

- 每次部件刷新时顺带检查样式表是否还挂着，被覆盖就补回；`body` 被替换时重新挂监听。

### C5.2 `perf(renderer): throttle part refresh during message streaming`（可选）

- 跳过只发生在消息内容区内部的 DOM 变化；调度改为“尾部防抖 200ms + 最长等待 800ms”。

---

## 第 6 阶段：macOS 对齐

### C6.1 `fix(macos): port watcher self-healing`

- 渲染脚本经 `sync-runtime-assets` 共享，第 5 阶段的改动自动带过去。
- `macos/scripts/injector.mjs` 是独立实现，需要移植 C3.1。托盘、守护和热切换提速只涉及 Windows 管理器，不移植。

---

## 第 7 阶段：测试、验收与发版（需明确指示后执行）

### C7.1 `test: cover tray, fast apply and self-healing`

- `tests/ManagerTests.cs`：关闭时隐藏与真正退出、`--tray` 启动、快速预检的各个失败分支、设置文件读写、开机自启开关。
- `windows/tests/injector-watch-lifecycle.test.mjs`、`injector-bootstrap.test.mjs`：会话自愈、提前注入超过 10 秒仍能完成。
- 新增守护功能的命令行判定、频率限制、皮肤实例不存在时不动作的测试。

### C7.2 验收清单（真机）

1. 连接正常时，从点击“应用皮肤”到 Codex 显示新皮肤不超过 3 秒；`timing.log` 记录各阶段耗时。
2. 需要重启 Codex 时，从确认重启到皮肤显示不超过 1 分钟。
3. 关闭管理器窗口后缩到托盘；托盘里快速切换主题、暂停/继续正常；“退出”后进程结束，皮肤仍在。
4. 开机自启开启后，重启电脑直接进托盘。
5. 点击“已完成”通知，不再出现无皮肤窗口。
6. 结束注入器进程，10 秒内自动恢复，Codex 不重启。
7. Codex 自更新重启后皮肤自动恢复。

### C7.3 `chore: release v2.1.0`

- 更新 `windows/VERSION`、`macos/VERSION`、`runtime-version.ps1`、两个平台 `injector.mjs` 中的 `SKIN_VERSION`、`src/AssemblyInfo.cs`、README 的版本号和安装包名、两个平台的 CHANGELOG，并新增 `.github/release-notes/v2.1.0.md`。
- 改完后全仓搜索 `2.0.1`，确认没有漏改的版本常量（参考 `f172ede` 的改动范围）。

---

## 取证记录

### 2026-10-04 第一轮（Codex `26.930.3930.0`，Chromium `154.0.8037.98`）

**通知点击（A7）——根因已确认**

快照里同时存在两个 Codex 主进程：

| PID | profile | 调试端口 | 父进程 | 命令行参数 |
| --- | --- | --- | --- | --- |
| 50752 | dream-skin | 9335 | 已退出的启动进程 | `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9335 --user-data-dir=...\cdp-profile` |
| 24172 | default | 无 | `svchost.exe`（服务 `WpnUserService`，即 Windows 推送通知用户服务） | `type=click&tag=15679622562172555424` |

- 通知点击由 Windows 通知服务直接启动 `ChatGPT.exe`，参数只有 Electron 的 toast 激活串 `type=click&tag=<id>`，不带 `--user-data-dir`，因此落到默认 profile、没有调试端口。
- 参数在命令行里，可以转发。C3.3 采用“结束新进程，以皮肤 profile 加原参数重新启动”的方案；皮肤实例能否响应这个 tag，要在原型里实测。
- 这个默认 profile 的进程在用户关掉窗口后仍在后台运行（无可见窗口）。

**应用皮肤（C 类）**

- 最近一次重启式应用：写入主题（23:58:59）到 Codex 带调试端口启动（23:59:29）约 30 秒，再到注入器启动（23:59:37）和校验通过（23:59:48），合计约 50 秒；之前还有查状态和用户确认的时间。
- 校验日志显示 `nativeWindow` 探测不可用（`browser-window-not-found`），通过依赖 `documentVisibility` 为 `visible`，即 Codex 窗口必须可见。

**页面内渲染（B1）**

- 主页面 DOM 3941 个节点，部件节点 15 个，面板节点 10 个。单次部件刷新平均 11.06ms，最长 13ms。
- 页面存活约 70 分钟，累计部件刷新 2058 次，平均每秒约 0.5 次；`styleRepairs` 为 0。
- 空闲采样（页面隐藏）：部件刷新 0 次。生成回答时采样到页面同样处于隐藏状态，计时器被系统限速，每秒 0.59 次，不具代表性；用户反馈无明显影响，不再补测。
- 同一浏览器里还有一个 148 个节点的小页面，皮肤已禁用（被排除的界面，属预期）。

**注入器（A1–A5）**

- watcher（PID 12376）存活，启动时间与 `state.json` 记录一致；`injector.log` 只有一次 `injected target`，`injector-error.log` 为空。

**管理器只读操作**，每项 3 次，取中位数：

| 操作 | 仓库脚本 | 已安装管理器（`D:\CodexDreamSkinManager`） |
| --- | --- | --- |
| PowerShell 空启动 | 343ms | 464ms |
| 仅加载公共脚本 | 542ms | 792ms |
| `Status -Quick -SkipThemes` | 1482ms | 1669ms |
| `ListThemes` | 1965ms | 1827ms |

- 打开管理器时要跑 `Status` 和 `ListThemes` 两次调用，合计约 3.3–3.5 秒；其中进程启动加脚本加载约 0.55–0.8 秒。
