# RC9 更新错误处理复核（2026-10-27）

基线：f71e060c1bc61f7c8273068867d5f465334868b2。对照仅为用户提供的本地 `参照官方dopamine/Dopamine-3.x_roothide` 快照。用户要求先不处理未越狱重启按钮；此次不修改 Application 源码。用户已反馈越狱后重启设备正常、管理器闪退已解决。

## 已确认链路

`DOEnvironmentManager updateEnvironment` → `jbclient_platform_stage_jailbreak_update` → `platform_stage_jailbreak_update` 设置 STAGED_JAILBREAK_UPDATE → 用户空间重启时 `spawn_hook.c` 调用 `jbupdate_basebin`。后者返回非零时，调用方原有 `abort_with_reason` 分支停止该流程。不能把它称作温和返回 App 或自动恢复旧环境。

RC9 与 zqbb 的更新循环均忽略 remove/copy 返回值；两边 libarchive_unarchive 在 archive_write_header 返回 ARCHIVE_FAILED/FATAL 时只打印错误，后续 finish_entry 返回成功便可能继续并最终报告成功。两边解包函数的多条提前返回也未释放 archive 对象。以上是源码确认的共同失败路径，不是声称设备已发生更新损坏。

## 本次最小修复

- `BaseBin/launchdhook/src/update.m`：检查空路径、暂存版本和 LaunchDaemons plist；在临时目录完成参数替换并检查写入，随后保留既有 RootHide 随机化与 trustcache 加载。
- 检查临时目录枚举、basebin.tc 删除、逐项旧文件删除和新文件复制；遇失败返回明确错误，不再发布更新成功标记。检查 setenv 结果，第二个标记设置失败时清除第一个。
- 用 @finally 统一尝试清理临时解包目录。清理失败不会掩盖主要错误，也不把“尝试清理”说成绝对成功。
- `BaseBin/libjailbreak/src/util.c`：解包对象分配与空输入检查、路径截断检查、严重 header 写入错误传播；成功/失败均关闭并释放对象，关闭/释放严重错误也反映在结果中。保留既有 ARCHIVE_WARN 容忍策略。
- 不移动整个 live basebin，不改 `gen`/`.fakelib` 生命周期，不改内核 trustcache 语义，不引入 iOS16 以外的系统分支。

错误码：1 输入／访问，2 解包，3 缺少 trustcache，5 随机化／加载，6 版本，7 内容枚举，8 删除旧项，9 复制新项，10 LaunchDaemons 枚举，11 plist 内容／参数类型，12 plist 写入，13 暂存 trustcache 删除，14 更新标记。

## 验证与限制

- Windows 本地 23 项源码契约通过，git diff --check 通过。
- 新增 tests/test_rc9_update.py --native：抽取实际更新函数，真实临时文件配合文件系统失败注入；覆盖校验、plist 写入、随机化、删除、复制及标记失败，确认失败不生成成功标记，正常 payload 不触碰既有 gen/dyld 与 .fakelib。
- 同脚本抽取实际解包函数，模拟分配、open、header、数据、finish、close/free 失败；另链接真实 libarchive 验证正常文件/符号链接、目标阻塞及截断 tar。
- 0478d481f0234144d9adca14d372c922e7e84504 的 full run 40504724306 已成功：全部原生测试、真实 libarchive 集成测试、完整 iPhoneOS 构建及 TIPA 上传通过。本地证据为 artifacts/2026-10-27-health-status/build-0478d48.json 和对应日志。
- 首次 run 40503844116 缺少 archive.h，已调整依赖安装顺序并指定 Homebrew libarchive；第二次 run 40504182159 的阻塞目标是假设错误（libarchive 可把普通文件替换成目录），已改为真实不可写目录后通过，没有跳过测试。
- 生产修复为 b9011595，640a5a4/0478d48 仅调整测试依赖与夹具。安装包为 Dopamine_3.0.7-0478d48_roothide.tipa；用户手动下载，本轮未完成本地新包静态核验或新版真机全流程验收。
- 本次不是完整事务恢复：复制到一半失败仍可能留下部分替换；调用方保留原有失败停止行为；App 重建 basebin 的先删后解包顺序未改变。断电／进程中断恢复仍需独立设计与验证。
