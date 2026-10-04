# 项目说明

## 测试与操作锁

- `build.ps1`（含 `-TestsOnly`）会跑 `tests/manager-actions.integration.ps1`，里面真实执行 `manager-actions.ps1 -Action ApplyTheme`，要拿操作锁 `Local\CodexDreamSkin.<用户SID>.Operation`（`windows/scripts/common-windows.ps1` 的 `Enter-DreamSkinOperationLock`）。测试用的是独立的临时目录，但锁名只按用户区分，照样会和正在运行的管理器抢同一把锁。
- 跑完整测试前先确认管理器空闲：没有在换肤、启动或恢复 Codex。撞锁时拿不到锁的一方会等待或直接失败，报 `Another Codex Dream Skin ... is already running.` 或 `... did not finish within ... ms.`；遇到这类报错，等管理器空闲后重跑确认，不要当成代码问题去改。
