# RC9 选择性维护修复记录

日期：2026-11-04（Asia/Shanghai）。

## 范围与基线

- 依据用户提供的《RC9-修复交接说明-2026-11-04.txt》及后续实施请求。
- RC9 工作区：`G:\RootHide\runtime-rc9-audit`。
- 开始时 HEAD：`9b8b7bae28d31b589e3689e228050978d46e4f54`。
- 分支：`codex/health-audit-20261027`，跟踪 `dev/codex/health-audit-20261027`，开始时 ahead 1。
- RC9 开发 remote `dev`：`https://github.com/kulinichx/RootHide-Dev.git`；`ci` / `public` 指向 `https://github.com/kulinichx/RootHide.git`。
- 对照目录：`G:\RootHide\ZQBB IOS16\Dopamine-roothide-ios16`，HEAD 已核对为 `be6cb36ab93767d67fcb7857b33376832bdd50b8`。
- 对照目录的首页、玻璃测试等已有未提交内容；计时器方案另从上述固定提交读取核对，不移植其中未完成的首页改造。
- 保留 `3.0.7` 基线、RootHide、授权、玻璃主题、Bundle ID、挂载及用户配置；不整体合并 3.0.12 / 3.0.13。

## 已核验基线与 GitHub 较新制品的区别

2026-11-04 补核：

- 本地现有 `DopamineRC9_3.0.7-b8358b5_roothide.tipa` 身份再次核验通过。
  版本为 `3.0.7`，`BaseBinBuildID` 为 `b8358b5544e00450bdcc4234e7fe9e955806ea7e`，
  SHA-256 为 `d223b09879e0926e35cf91a415e0e7b5da871978358931b8e02991c21077492c`。
- 新的只读包身份报告位于 `artifacts/release-readiness-20261104/baseline-package-identity.json`。
  报告明确列出当前工作区相对旧包已有的源码改动，不将旧包当成本轮新候选。
- 使用 GitHub API 只读查询 `RootHide-Dev` 与 `RootHide` 的最近构建制品后发现，
  `RootHide` 还有较新的 `Dopamine_3.0.7-9b8b7ba_roothide.tipa`，
  创建时间为 2026-10-30 13:09:29（Asia/Shanghai）。
  因此不能把 `b8358b5` 直接称为 GitHub 时间上最新的整包。
- 本地完整提交比较显示，`b8358b5544e00450bdcc4234e7fe9e955806ea7e`
  到 `9b8b7bae28d31b589e3689e228050978d46e4f54` 的 `Application` / `BaseBin` 无源码差异；
  仅新增独立管理器工作流、工具、测试和说明。最初仅核对源码，随后按用户要求
  下载并完成历史包静态对照，结果与处置见下一节；不将源码相同解释为构建产物相同。
- 用户提到的早前图片不在本轮可见对话内容中。本轮实施范围依据交接文本；
  不将图片中可能存在、但未写入交接文本的要求擅自标为已完成。

## 9b8b7ba 历史包核验与处置

用户表示不记得该包，并委托处理。本轮只下载、读取和归档，没有安装、推送或触发构建。

- GitHub 来源：`kulinichx/RootHide`，workflow run `41006173702`，
  对应分支 `codex/health-audit-20261027`，HEAD 为
  `9b8b7bae28d31b589e3689e228050978d46e4f54`，任务状态 `completed / success`。
- 制品 ID：`12955861829`。ZIP 内 `artifacts/source-provenance.txt` 的仓库、
  分支、HEAD 和 `3.0.7` 版本与查询结果一致。
- 下载后的 TIPA 位于
  `artifacts/package-audit-20261104/9b8b7ba-proxy/Application/Dopamine_3.0.7-9b8b7ba_roothide.tipa`。
- TIPA 大小：28,888,760 字节；SHA-256：
  `797bc35d73086ec98fb39a5a8f380719bd986ee0443f8e071a19b33ae1323a17`。
  此值是 TIPA 本身的哈希，不是 GitHub 外层 Actions ZIP 的哈希。
- 静态身份检查通过：Bundle ID 为 `com.opa334.Dopamine-roothide`，
  App / BaseBin 版本均为 `3.0.7`，最低系统字段为 `16.0`，
  包内构建 ID 与完整 `9b8b7ba` 提交一致。
- 同时重新核验 `b8358b5` 的固定哈希及身份，原可用包未被改写。
- 内容对比：App 下 76 个文件无增删，其中 66 个完全一致、10 个内容或权限记录不同；
  BaseBin 归档内 24 个非目录成员无增删，其中 17 个一致、7 个不同。
  `Info.plist` 字段完全一致，但 App 主程序、若干框架、运行时组件、trustcache
  和部分内置 deb 的字节并不全相同，不能声称两个安装包可互换或差异仅为文件名。
- 没有仅凭哈希差异判断出现功能回归，也没有将静态身份通过扩大为 Apple 签名、
  iOS 加载或真机运行通过。

机器可读结果：`artifacts/package-audit-20261104/comparison.json`。
比较脚本只读 ZIP / TAR，不执行包内代码、解包脚本或安装操作。
下载首次连接停滞后已停止本轮启动的下载进程，再使用项目已有本地代理完成重试。

**处置决定：**
保留用户已知可用的 `b8358b5` 作为本轮设备回归和问题对照基线；
`9b8b7ba` 仅作历史 CI 构建归档，不升级为默认推荐包，也不要求用户重复安装。
当前源码 HEAD 可以保持不变，因为两个历史提交的 App / BaseBin 没有源码差异，
无需回退、清空工作区或丢弃现有修复。新候选应在现有源码上叠加本轮修复后独立构建，
使用自己的提交与包哈希；两个历史包都不冒充已包含本轮尚未提交的改动。

## 用户补充确认的既有功能基线

用户随后补充了 RC9 之前的更新说明。以下作为必须保留的既有功能，
不重新计入本轮移植成果，也不据此将版本改称完整的 Dopamine 3.0.12：

| 既有内容 | 保留边界与现有检查 |
| --- | --- |
| 官方 RootHide 底层、zqbb 注入策略与 RC9 异常处理补强 | 延续现有 RootHide 架构和 iOS 16 范围，不整体替换核心；既有选择性移植分类见 `rc9-ios16-backport-ledger-20261102.md` |
| 可选 zqbb 白名单 | 不强制启用，不取代现有黑名单、安全模式和 tweak 开关；`test_dual_manager_contract_is_preserved`、`test_whitelist_is_independent_of_tweak_toggle` 与名单边界检查继续通过 |
| 独立黑白名单管理器的挂载 / VPN 信任版 | 保留用户选择的挂载信任及 VPN / 代理提示偏好；VPN 信任不修改网络状态，也不隐藏 VPN。管理器独立发布、白名单管理器通过 Sileo 安装，不与 RC9 运行时版本混记，不擅自更换包或清理偏好 |
| 进程权限、注入策略及底层偏移修复 | 保留 setid check-in 的 task audit token 同步、RootHide XPC 黑名单分发边界及 XPF offset 注册 / 追加；对应既有源码契约继续通过 |
| 引导、更新与解包加固 | 保留暂存、校验、备份与恢复、解包路径和写入错误检查；`test_bootstrap_basebin_publication_is_recoverable` 及 update 回归继续通过，不扩大为已证明断电事务安全的承诺 |

“同步发布管理器”不表示 RC9 TIPA 自动升级所有独立管理器。
用户实际安装的管理器版本和对应包身份仍须独立记录；不将历史候选的全部设备行为标成已验收。
本轮只继续处理 Jetsam 恢复验证、运行时间定时器及关于页名单滚动，
不重复移植上述基线、不修改原授权 / 主题 / 挂载功能。

## 工作区保护

开始时已经修改的文件：

- `.github/workflows/roothide.yml`
- `BaseBin/systemhook/src/common/common.c`
- `tools/manager-trust/README.md`
- `tools/manager-trust/build.py`

另有未跟踪文档、发布工具、安装包、缓存和备份。本轮未清理或覆盖这些内容；
提交阶段仅按下节明确范围暂存，不包含独立管理器改动、历史安装包、缓存或备份。
`common.c` 的 Jetsam 恢复实现是开始时已有的改动，本轮保留并补测试，不将其冒充本轮新写的生产修复。
没有修改 Git 全局信任设置；读取对照仓库仅使用命令级、精确路径的 `safe.directory`。

## 本轮改动

### Jetsam 测试与现有实现复核

文件：`tests/test_rc9_common.py`。

- 修正旧 C harness 中“返回后调用方仍为 140 / INT_MAX”的断言。
- 在 mock original spawn 内复制生效额度，返回后分别验证调用方原值，保留对子进程输入额度的检查。
- 补充同一属性连续三次使用、成功及失败恢复、失败时 PID / debug 边界、返回值及 errno 检查。
- 补充无限额、零额度、异常负数、配置回退、饱和、非有限倍率、关闭注入、SafeMode 和 DriverKit 边界。
- 分配失败注入现在携带实际属性，验证没有调用 original 时属性也不改变。
- 新增源码契约，约束环境准备、保存、original 调用、恢复和资源释放的先后关系。
- 原生 harness 仍提取真实 C 实现并分别编译 systemhook / launchdhook 两种模式；本轮没有在本机执行这两种原生模式。
- exec 只检查可返回的失败路径；不声称成功 exec 后执行了恢复代码。

### 运行时间定时器生命周期

文件：

- `Application/Dopamine/UI/DOHeaderView.h`
- `Application/Dopamine/UI/DOHeaderView.m`
- `Application/Dopamine/UI/DOMainViewController.m`

处理：

- Header 持有 timer，回调弱引用 Header，停用时 invalidate 并清空，释放时移除通知观察。
- 首页控制器显式管理可见性，原版与玻璃版首页共用此机制；替换 Header 时先停旧实例。
- 只有页面启用、窗口可见、所在 scene 活跃且应用活跃时启动。
- 离开页面、应用失活、所在 scene 失活、窗口隐藏或脱离窗口时停止。
- scene / window 通知按对象过滤；恢复时立即读取系统时钟刷新，避免重复创建 timer。
- 首次触发对齐下一分钟边界，后续每分钟刷新，使用主线程 common run-loop modes。
- 保留 `CLOCK_MONOTONIC_RAW`，不改成应用启动时长或擅自更换包含休眠时间的计时定义。
- 保留天 / 小时 / 分钟文案、语言回退、字体、布局、头像及授权处理。

### 关于页名单

文件：`Application/Dopamine/UI/Settings/Specifiers/DOCreditsCell.m`。

- 设置 `collectionView.scrollEnabled = NO`，交由外层列表滚动。
- 只有有效宽度发生变化时使 collection layout 失效，先记录新宽度，避免同宽度重复失效。
- 保留两列、35 点行高、零间距以及 `ceil(names.count / 2.0)` 的完整行数高度。
- 保留姓名、链接、点击、delegate / dataSource 和原有外观。

### 新增 UI 源码契约

文件：`tests/test_rc9_ui_lifecycle.py`，12 项。

检查通知注册、弱引用、可见性和活跃状态门控、分钟对齐、停止与释放、
两个首页分支、Header 替换、名单滚动与宽度失效边界。
这些是源码结构检查，不是 UIKit 执行、内存泄漏实测或截图验收。

## 验证结果与限制

- 本机使用已安装的 Python 3.14.7 绝对路径运行，避免 PATH 中不可用的 WindowsApps alias。
- `python -B -m unittest discover -s tests -v`：70 项通过，无跳过。
- 用户补充既有功能说明后重新运行上述 70 项，全部通过；另运行
  `python -B tools/manager-trust/test_build.py`，7 项全部通过。
  这 7 项验证管理器打包完整性及资源 / 设置保留，不等于真机提示偏好或网络行为验证。
- `python -B tests/test_rc9_common.py`：5 项源码契约通过，包含于上述 70 项。
- `python -B tests/test_rc9_common.py --native`：5 项源码契约通过后，明确退出并报告 `--native requires clang; no native tests were run`。
- 本机 PATH 中没有 clang / xcodebuild，未运行 C harness、ASan / UBSan、Apple 原生编译或 UIKit 真机验证。
- `git diff --check`：通过。
- 未生成新 TIPA，未复用旧包充当本轮候选，也没有新的包哈希或构建 ID。
- 本轮未提交、push、触发 GitHub 构建或发布。

## 本次提交与构建范围

用户已要求开始实施。2026-11-04 提交前再次运行 70 项回归及 7 项
管理器打包测试，全部通过，`git diff --check` 通过。
再次查询私有 `kulinichx/RootHide-Dev`，目标分支
`codex/health-audit-20261027` 仍为 `0efb332bcfd540bf8c73b0a32abb6c78054b0d39`。

本次选择性纳入：

- 已有 `common.c` Jetsam 恢复实现及本轮修正的 C harness。
- 四个首页 / 关于页源码文件与 UI 源码契约。
- 已有工作流中的完整回归与包身份校验步骤，以及配套的发布检查工具、
  合成包测试和授权 / 主题持久化契约；不改变既有工具链。
- 本记录。不包含开始时已有的独立管理器工具改动。

当前准备提交、推送到 `dev`，由 push 触发原有完整构建，不重复手动派发。
提交成功、原生测试及候选包身份结果须另行记录；本段不表示构建或真机验收已通过。

## 后续验收

1. 提交前逐项确认范围，尤其区分开始时已有的 `common.c`、工作流和管理器工具改动；不使用 `git add -A`。
2. 仅推送到已核验的私有 `dev` 分支，在既有 GitHub macOS 工作流先验证两种 C harness 模式，再完整构建。
3. 对新包核对源码提交、版本、Bundle ID、BaseBinBuildID 和 SHA-256，保留旧可用包。
4. 真机验证页面进出、前后台、窗口重建后的计时，名单完整展示及点击，原授权、主题、头像、壁纸和名单行为。
5. SpringBoard 快照写入 hook 仍是独立的第二批候选，本轮未修改 `BaseBin/roothidehooks/springboard.x`。
