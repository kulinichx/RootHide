# RC9 第二批：SpringBoard 快照写入

日期：2026-11-04（Asia/Shanghai）。

## 为什么单独处理

第一批提交为 `603738a37d59c25c26f2e3bf02f7f7e03bff24ee`。
快照写入原先按交接要求单独评估，不是遗忘或已证实 RC9 所有设备都存在故障。
这项修改涉及 SpringBoard 私有方法、RootHide 随机根目录、普通 Apple 应用例外
和写入失败语义；第一批的 UI 与 spawn 测试不能代替它的专项验证。
用户现已明确要求开始第二批，并对照官方 / zqbb 源码检查其他适用增量。

## 固定的对照来源

2026-11-04 通过 GitHub API 重新核对：

- 官方 `opa334/Dopamine` 的 `3.0.12`：
  `13b26789842922cd4bd9fb5f30b3878d7e67ff0b`。
- 官方 `3.0.13`：`5b1d2c1c3bf54dd8e3641d29c60cd3a0c13cde88`。
- 快照原始补丁：`26d95449d25d176a31ae7bc475fd85ee3403498c`，
  `BaseBin/rootlesshooks/SpringBoard.x`。
- spawn 恢复原始补丁：`f3cd2b82af8d5fa3baea193384ac61b50d2e44bb`。
- `w2599/Dopamine` 公开 `3.x_roothide` 分支仍为
  `18049d5a81b294d3387b3af30c54558d04b8b5f5`。
- 用户提供的 iOS 16 RootHide 适配对照：
  `be6cb36ab93767d67fcb7857b33376832bdd50b8`，
  `BaseBin/roothidehooks/src/springboard.x`。

补丁正文和提交图从本地对照仓库的固定 Git 对象读取。
该仓库同名 `3.0.12` 标签实际指向
`e6810c1ddf668cd931522c0203b50487a828551c`，不是官方 3.0.12。
不能将它与官方 3.0.13 的整树差异误认为官方增量；
本次正式比较使用上述两个经官方 API 核验的完整 SHA。
公开 RootHide 源码分支与较新发布包的版本号不是同一个证据，
不声称已经取得所有发布二进制的对应源码或完成可复现构建。

## 近期增量逐项分类

官方两个固定提交之间只有五个提交，涉及六个文件：

| 提交 / 项目 | RC9 处理 |
| --- | --- |
| `f3cd2b82`：spawn 属性恢复 | 第一批已覆盖 iOS 16 适用的 Jetsam 恢复；保留 RC9 MB 加法、失败保护与双目标 C harness，不重复移植 |
| 同补丁 persona / UID / GID / suspended flags | 原补丁明确针对 iOS 17.6+；不引回当前 iOS 16 范围 |
| `26d95449`：快照写入方法 | 本批适配到实际构建的 `roothidehooks/springboard.x`，不是复制 rootless 文件 |
| `cc59b25c`：TXM 的 iOS 26 beta 检测 | 改动仅影响非 iOS 16 分支，不移植 |
| `b189bea5`：SPTM frame level 8-bit 写入 | 非当前 iOS 16 路径；RC9 `util.c` 没有该 `pagetable_set_level` 实现，不凭同名版本引入 SPTM |
| `5b1d2c1c`：版本与工程版本字段 | 不修改 RC9 的 `3.0.7` 身份、Bundle ID 或现有工具链 |

更早的 RootHide 路径、RunningBoard、UTType、权限、XPF、名单与引导加固
沿用已有分类记录 `rc9-ios16-backport-ledger-20261102.md`，
相关现有回归本次一并复跑；不将复跑契约测试描述为重新完成全仓库审计。
目前这组近期增量中，除快照外没有确认新的 iOS 16 漏移植项。
trustcache 读者生命周期、断电 / 中断恢复等仍为独立专项，未据此宣称解决。

## 实现边界

- 新增独立 `SnapshotWriteHooks` 组；启动时检查三个私有类和六个 selector
  的存在、返回类型、参数数量及参数 ABI。不匹配时不安装新组，保留旧路径。
- 不声称源码声明证明了每个 iOS 16 小版本的实际私有 ABI；运行时门控是保护，
  真机是否启用及实际写入行为仍需验收。
- 使用 `jbclient_get_jbroot()` 的当前随机根目录；缺失、空或非绝对根目录回退。
- 保留 `snapshotContainerPath` 重定向、0755 目录创建、创建失败回退，
  并处理无有效路径 / bundle ID 的输入。
- 普通 `com.apple.*` 应用走原方法；保留 Apple-internal 标识的既有例外。
- 同时核对容器与生成目标的规范化路径，带末尾分隔符匹配 RootHide 快照目录，
  避免相似前缀和词法 `..` 越界；不要求尚未创建的目标通过 `realpath`。
- 路径生成失败返回 NO；目录创建失败回原方法；实际写入结果直接返回。
  使用上游的 `NSData` options 0 写入，不执行默认的文件保护属性操作。
- 既有修正过的 `fcntl` 转发保留作为兼容路径，不重新引入十个多余可变参数读取。
- 不改应用隐藏、黑名单查询与 open-request 的调用范围标签清理逻辑。
- 加载链已定位：
  `systemhook/src/main.c` 的 SpringBoard 分派加载 `roothidehooks.dylib`，
  `roothidehooks/main.x` 调用 `sbInit()`；Makefile 为 arm64 / arm64e 编译该文件。

这不是壁纸 / 玻璃改造，不承诺提高越狱成功率、速度或长期稳定性。

## 测试与交付门槛

- 新增 `tests/test_rc9_snapshots.py` 的五项源码契约。
- 新增 macOS Foundation 原生 harness：提取生产路径转换、重定向、
  selector / ABI 门控和实际保存方法；只替换 OS 查询及 original 边界。
- 原生用例覆盖随机根切换、新文件、重复写入、普通 Apple 应用与 internal 例外、
  无效数据 / 对象 / 标识、丢失 root、相似前缀与词法越界、目录和写入失败、
  原返回值传播、缺失类及不兼容方法 ABI。
- 原生测试启用 ASan / UBSan，加入现有 CI，不更换 runner、Xcode 或 Theos。
- 本机 75 项回归及 `git diff --check` 通过；本机没有 Apple SDK / clang，
  原生结果必须以本批独立 CI 为准，不能沿用第一批的通过状态。
- 本次提交只含快照源码、测试、工作流中的一行 native 调用和本记录。
  不混入独立管理器改动、旧包、备份、未跟踪历史资料或授权材料。
- 依次核验私有开发分支、独立提交 / 构建、新包版本 / build ID / SHA-256。
  构建和静态身份通过后仍只称候选。

### 首轮原生回归记录

提交 `577f2d2fa9fa1782f50de99b3c26dd0e2b393133` 的 run `41847985634`
在新快照测试的空 root 用例中失败，未进入完整构建。
原因是测试桩对 `@""` 调用了 Foundation 的 `fileSystemRepresentation`，
该调用会抛异常，未能模拟真实 C API 返回空字符串的情形。
已将空值测试桩改为直接返回 `""`，保留原有空 root 断言和全部生产检查，
未放宽通过条件，也未为测试修改生产代码；修正后的结果须由新 CI 确认。

## 真机专项验收

1. 安装与越狱，原插件和黑白名单行为保持。
2. 打开并切换 Sileo 等越狱应用，在应用切换器观察快照生成与更新。
3. 对普通 Apple 应用进行相同步骤，确认未被错误重定向。
4. 原授权、玻璃主题、头像、壁纸和第一批计时 / 名单修复保持。

不要求卸载越狱、清空插件数据库或删除用户配置。
已有对照包成功越狱的反馈不当作本批 RC9 快照专项已通过。
