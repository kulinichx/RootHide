# RC9 对照 RootHide / ZQBB 3.0.13 健康审计

日期：2026-11-06（Asia/Shanghai）。

## 范围与身份

- RC9 起点：`368ed07451162d9c717b3cf1e801b610670e7233`。
- 保留 RC9 / Dopamine `3.0.7`、iOS 16 范围、RootHide 路径与注入、
  两个管理器、授权、Glass / Issuer / Supporter、用户配置及挂载设置。
- 用户已确认设置页基本正常；本轮不改设置页、滚动、玻璃、时间选择器。
- 不做 3.0.13 整树合并，不把 rootless 源码当成 RootHide 整树替代品。
- 起点已有的管理器工具改动、未跟踪资料、备份与制品不属于本轮修改。

## 固定的 3.0.13 参考

2026-11-06 通过 GitHub API 查询分支，读取本地固定 Git 对象比较：

| 参考 | 固定提交 | 用途 |
| --- | --- | --- |
| 官方 `roothide/Dopamine-roothide`，`3.x` | `185a8514e76270e46fb94603f2cc8b0618e38ad6` | 官方 RootHide 3.0.13 主参考；源码 `.version` 为 `3.0.13` |
| 用户截图中的官方包 | `9202f7a9ef69ce9eba08a74a4a0e60747b35f013` | 截图标识 `3.0.13-29`，是较早的官方提交，不是当前分支 HEAD |
| ZQBB `w2599/Dopamine`，`3.x_roothide_AI_review_fix` | `7e14aa6155ce867e9052a88a8c17c632f4c30d77` | ZQBB RootHide 3.0.13 审查修复分支，源码 `.version` 为 `3.0.13` |
| ZQBB `3.x_roothide` | `18049d5a81b294d3387b3af30c54558d04b8b5f5` | 作为 ZQBB 修复前的差异起点，不冒充最新 3.0.13 整树 |

官方较新的死锁补丁是 2026-11-05 的
`473d52e44d14e3ccc7cf4e86d1095d26be2e6987`，位于截图提交之后。
ZQBB 修复分支的提交时间采用 committer 时间；部分 author 时间仍为十月，
不能只按作者日期判断补丁先后。

W2599 发布标签 `3.0.13` 指向 `6522285754fd9c4574e9afc352dc31fe548567fc`
的 `3.x_modify_` 树。与发布页面附带的 RootHide IPA 的准确对应关系，
仍应以各包构建信息为准。本轮没有验证那些 IPA 的源码对应或可复现构建。
本地 `be6cb36` 的 3.0.12 适配版不再充当最新上游基准。

## 本轮确认并修复

### 1. logd_helper 插件加载死锁规避

来源：官方 `473d52e4`。

RC9 原先只在 iOS 16 的 tweak 禁用表中列出 `logd`、`notifyd`、
`usermanagerd`，缺少 `logd_helper`。按官方记录，该进程可能形成
`logd -> logd_helper -> TweakLoader -> CFBundle -> logd` 的依赖环。

修改 `BaseBin/systemhook/src/main.c`，仅阻止该精确路径加载插件。
不把它加入 spawn 的 systemhook 禁用表，不关闭其 RootHide 基础注入。
这是预防性死锁修复，不是此前 iPad 重启或 PPL 等待的已证实根因。

### 2. 进程虚拟地址写入误调用自身

来源：ZQBB `7cb89f6c9e60cbf90f39dedd084e45146444c296`。

`proc_vwritebuf` 已取得 `ttep`，却把它再当作 `proc` 调用自身。
改为调用 `vwritebuf(ttep, ...)`，保留四级空值检查及底层返回值。
当前 RC9 源码搜索未找到库内部的外部调用点；它仍是导出的库接口缺陷，
不能用它解释当前设备的重启现象。

### 3. killall 参数缓冲区容量错误

来源：ZQBB `302f485de96611efbb135078810b96efb4d5fa82`。

旧代码分配的是进程列表字节数，却向 `KERN_PROCARGS2` 声明 ARGMAX 容量。
改为按 ARGMAX 分配并复用缓冲区，处理空参数、无效 ARGMAX、
分配/查询失败、短结果、异常长度、缺失 NUL 和非正 PID。
保留精确完整路径匹配及调用方指定的信号。

实际调用点包括 `jbctl` / launchdhook 终止 `backboardd`，
以及 systemwide check-in 中终止 `kbd`；不是只修改不可达的示例函数。

### 4. 旧 arm64e ABI 的库/主程序判定写反

来源：ZQBB `15a075427c758eadd366260360c529a7762af4db` 中的适用子项。

`macho_is_mappable` 的 `isLibrary` 原来等于 `filetype == MH_EXECUTE`。
改为 `!= MH_EXECUTE`，使旧 arm64e ABI 按现有规则只允许非主程序，
不颠倒库与主程序。arm64 ALL/V8、新 arm64e ABI 和主机分支保持原逻辑。
本轮没有整套引入该上游提交中改变收集接口返回类型的其他部分。

### 5. JBServer DATA 与后续参数错位

来源：ZQBB `8bceb694` 的 dispatcher 子项，适配现有 RC9 布局。

旧循环把 descriptor 索引和 ABI 参数位置混用，DATA 占两个位置后，
会跳过后面的 descriptor。当前 `systemwide_trust_file` 的
`caller-token / fd / siginfo(DATA) / attach` 就会经过这一路径。

修改 `BaseBin/libjailbreak/src/jbserver.c`：

- 先计算 descriptor 对应的 ABI 位置，限制最多 8 个位置；
  DATA 同时传递指针与长度，后续输入/输出不丢失。
- 回复对象必须在参数 FD 复制及 handler 执行前成功创建。
- 输出 FD 初值为 -1，未设置 FD 时不错误关闭 stdin；
  输入/输出无效 FD 不执行 close。
- 保留 RootHide 黑名单早退、permission handler、domain/action 号码、
  结果值、XPC 所有权与已有 handler 签名。
- domain/action 遍历使用 uint64_t，与消息类型一致。
- 只新增 8 参数的宏；保留 `jbserver_arg *args` 和 flexible actions 布局，
  不移植 ZQBB 的固定数组结构，不改变其他域表初始化形式。

## 已有逻辑、不适用项与未关闭风险

| 模块 | 本轮核对与处理 |
| --- | --- |
| spawn / Jetsam | 3.0.13 的 iOS 16 属性恢复已存在；保留 MB 加法、饱和、SafeMode、DriverKit 和调用后恢复，不重复覆盖 |
| SpringBoard 快照 | 已有 RootHide 适配及私有 ABI 门控，保留；原生专项仍由现有 CI 执行 |
| 低电量计划 | 检查 SpringBoard 端单次持久定时器、关闭时懒加载边界、有限重试、respring/重启区分；没有新增轮询或应用后台进程，没有修改设置菜单 |
| RunningBoard、UTType、XPF、名单、授权与主题 | 沿用既有有证据的适配，现有测试一并复跑；这不是逐文件重新证明所有私有 ABI |
| SPTM / TXM、iOS 17.6 persona | 不属于 RC9 iOS 16 目标，不引入相关新分支 |
| ZQBB hookd Mach 转发 | RC9 当前 Mach server 没有 hookd 转发分支，不复制只有另一套调用链才需要的结构 |
| 解包 / bootstrap / 更新 | 保留 RC9 已有路径约束、别名解析、错误传播、stage/ready/backup，不被较弱的整文件覆盖 |
| trustcache 内核读者生命周期 | 仍未关闭；不能以用户态互斥锁或任意延时证明内核读者已退出 |
| generated-dyld / live basebin 中断恢复 | 仍未关闭；需要文件、symlink、vnode 与 trustcache 代际的一致恢复协议 |
| forkfix 握手、fork 后配置锁、签名收集剩余差异 | 记录为后续专项；本轮未证明其完整等价，不整批照抄 ZQBB 的并发/协议重构 |

这些保留项与待核项不能写成“全面健康审计全部通过”或“所有重启问题已修复”。
本轮完成的是固定版本差异审查与上述五项最小修复。

## 测试与构建

- 起点已有 94 项源码/包测试通过；前一包公共 CI
  `42140766570`（`368ed074`）已成功，但不验证本轮新代码。
- 新增 `tests/test_rc9_upstream_313.py`：
  提取真实生产 C 函数，覆盖四项最小修复及边界。
  CPU 查询/dispatch_once 和 iOS availability 是 mock，不验证这些系统机制本身。
- 新增 `tests/test_rc9_ipc_dispatch.py`：
  提取真实 dispatcher 和头文件类型，覆盖 DATA、8 参数边界、FD、
  无回复、权限/名单及异常索引；检查现有域表不超过 8 个 ABI 位置。
- 两个原生脚本均使用 ASan/UBSan，并接入既有 macOS CI。
- 本机 Windows 没有可用 clang / Xcode；源码契约通过不替代原生执行、
  Apple 编译、候选包身份校验和 iOS 16 真机验收。
- 新候选构建结果与包身份待 CI 完成后记录；不拿旧包充当本轮候选。
