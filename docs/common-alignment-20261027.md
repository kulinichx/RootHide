# RC9 与本地 zqbb 参照版：common.c 对齐复核

日期：2026-10-27（Asia/Shanghai）。RC9 基线：1067408e18459f0ed72e37e611fb2d24850f7fff。
对照目录：参照官方dopamine/Dopamine-3.x_roothide。这里只核对用户提供的本地快照，未确认远端最新状态。

## 纠正之前的解释

RC9 与 zqbb 参照版属于同一 Dopamine/RootHide 技术谱系。两个 common.c 在修复前分别编入 launchdhook 与 systemhook，是构建事实，不足以证明维护两份实现是必要设计，更不能把所有差异解释成 RC9 定制。

对齐原则：以本地 zqbb 参照版的 RootHide 行为及共享代码结构为主要对照依据。每个保留差异都应有明确目标、适用系统范围或测试证据。AI 生成、旧注释、能编译、旧源码检查通过都不是正确性的独立证明。

## 修改前的文件和构建事实

| 文件 | RC9 构建用途 | 本地 zqbb 参照版 |
|---|---|---|
| BaseBin/systemhook/src/common.c | launchdhook/Makefile 第 10 行明确编译 | 无此独立文件 |
| BaseBin/systemhook/src/common/common.c | systemhook/Makefile 第 12 行通过 src/common/*.c 编译 | launchdhook 与 systemhook 均编译此公共目录 |
| BaseBin/systemhook/src/roothider_common.c | 两个 dylib 均使用的 RootHide 辅助实现 | 存在同名文件，仍有具体实现差异 |

因此不能直接删掉旧文件，也不能把“当前分别使用”当作拒绝收敛的理由。收敛时需同步 Makefile、头文件、符号依赖及 launchd 中的服务调用边界。

## 历史证据

- d25433c（2026-07-24）：上游将 src/common.c 移到 src/common/common.c，两个 Makefile 转向公共目录。Git 作者记录为 opa334；不能把所有差异归因于 AI。
- 1afe12d（2026-08-09）：当前历史中的 RootHide 布局修复，仅把 launchdhook 的 envbuf 路径改成 common/envbuf.c，仍编译 src/common.c。这说明分叉涉及历史集成，不是两个不同越狱产品的必然差别。
- c33f420（2026-10-26）：两份共同加入分配失败、环境拼接等防护。
- af6153c（2026-10-27）：两份共同改用 rc9_zqbb_jetsam_addend / rc9_zqbb_jetsam_limit。
- c252f6a 已包含 af6153c；本轮修复前（1067408）的两个 common.c 与 c252f6a 对应文件完全一致。不能因此声称全面完成 zqbb 对齐。

## 修改前发现的未完成对齐项

### 安全模式与 RootHide 判断

zqbb 的公共实现遇到 _SafeMode=1 或 _MSSafeMode=1 时调用 allowInjectWithSafeMode(path)。RC9 旧 src/common.c 同样调用此函数，但 src/common/common.c 直接设 shouldInsertJBEnv=false。

RC9 自身 roothider_common.c 已实现 allowInjectWithSafeMode：非 launchd 调用返回 true；launchd 对普通容器应用、TrollStore 标记应用、根挂载系统进程分别处理。zqbb 的调用使该 RootHide 语义作用于公共 spawn 路径。

RC9 公共目录版本的无条件拒绝可追溯到 d25433c 中普通 Dopamine 的实现。本次未找到它作为 RC9 专门定制的独立依据。因此列为 RootHide 适配遗漏候选，应恢复/验证对应行为，而非以“RC9 策略不同”为由默认保留。仍需验证真实调用链，以及 systemhook 基础注入和 main.c 中 tweak 加载门控之间的配合。

### 配置与清理行为发生分叉

- ProcessBlacklist 配置读取在 RC9 common/common.c 中存在，在旧 common.c 中没有；zqbb 用共享实现覆盖两个构建目标。需要核对 launchd 路径的相同配置是否实际生效。
- DriverKit 类型查询的 attr 空值防护仅在 common/common.c 中存在。
- DYLD_INSERT_LIBRARIES 过滤后没有剩余条目时，common/common.c 删除变量，旧 common.c 写入空字符串。
- 动态 RootHide 黑名单在 systemhook 路径通过 jbclient_blacklist_check_path 查询；launchd 另在 roothider.m prehook 中调用 isBlacklistedPath。共享重构时必须保留正确的服务调用边界，不应把客户端查询直接搬进 launchd。

这些差异需逐项决定、验证，不是已确认无害的差异清单。

## 有明确历史原因的系统范围差异

2ea51f3、7bd6435（均为 2026-08-21）明确移除 iOS 17/17.6 persona 接口、服务端逻辑和 spawn 集成。仓库 RootHide_iOS16_Core_Final_Audit_Build_Plan.md 第 20 行声明不面向 iOS17+，第 47 行起记录 Persona systemwide fix 裁剪。

该文档是历史证据，不替代用户当前意图；用户后续改变目标系统时应重新评估。当前不能把未加入 persona 简单判定为遗漏，也不能只复制其调用而缺少已删除的客户端、服务端和协议实现。

## 本轮变更和验证边界

已实施本地修复：两个目标共同编译 common/common.c，删除旧 src/common.c；src/common.h 转为兼容转发头。systemhook 独有 VM/hookd 代码原样移入 common/systemhook_memory.c，不带入 launchdhook。

- 共享实现调用 allowInjectWithSafeMode，main.c 的 tweak 禁用门控不变。
- SafeMode 允许基础注入后仍检查 DriverKit 和 dylib 存在性；避免参照实现提前 break 跳过保护。
- 共享 attr 空值防护；posix_spawn 成功后的 getflags 同样检查 attr。
- 共享环境清理，去掉全部 hook 条目后删除 DYLD_INSERT_LIBRARIES，保留其他库。
- launchd 也采用 ProcessBlacklist 配置；posthook 按共享 Inject 标志决定暂停/补丁，覆盖 trust-only APT、白名单拒绝、固定进程排除。
- RC9_LAUNCHD 编译边界仅排除客户端动态黑名单 IPC；launchd prehook 的 isBlacklistedPath/黑名单 PID 管理未改。
- 保留既有缓存、防溢出、Jetsam 加法、APT transport trust-only 和 iOS16 范围；未移植 iOS17 persona 子系统。

本地 8 项既有源码契约 + 4 项新增共享契约已通过。私密 CI run 40493314095 在 macOS 上运行了原有 native 回归，以及 tests/test_rc9_common.py --native 的 systemhook/launchd 两种编译模式；ASan/UBSan 检查均通过。完整 Apple SDK 构建及 TIPA 上传成功，结束于 2026-10-27 19:06:13 +08:00。

源码提交：b8800ef6974961aea7f173763d6f7329f47dd57f（bd755f9 产品修复 + b8800ef 测试夹具宏修正）。私密分支 codex/common-alignment-20261027；未合入长期 runtime/rc9-audit，未推公开仓库。
安装包：Dopamine_3.0.7-b8800ef_roothide.tipa，28,890,920 bytes。
TIPA SHA256：e1b3ce6e7128d21520d9779bcdbc7c0ee0c6945a6d4c36d375d8e2b684490763。
外层 Actions ZIP SHA256：2406a389f0ede347dde94cdf9cd7a333d0aecc39adb235025c0b60f406b11558。二者不可混用。
包内 BaseBinBuildID 与提交一致；两组件的 arm64/arm64e slice、共享符号唯一性、launchd 无客户端 blacklist/hookd 依赖已核验。见 artifacts/2026-10-27-common-alignment/package-verification.json。

这些是专项测试与构建/静态包验证，不是全面健康审计已完成。b8800ef 尚无真机验收；双管理器 trust1 闪退根因及 trust2 修复未得到设备确认；lsd/UTType 初始化保护、RunningBoard iOS16 路径及其余核心调用链仍待审。2026-10-27 已将当前状态就地同步到用户指定的新版工作手册，原文已备份。详见 artifacts/2026-10-27-health-status/。
