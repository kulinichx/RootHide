# RC9 服务层健康审计（2026-10-27）

基线 b8800ef6974961aea7f173763d6f7329f47dd57f。参照为用户提供的 Dopamine-3.x_roothide 快照。
本报告是已检查模块的证据记录，不代表整个 RC9 零缺陷或真机验收完成。

## 已落实修复

1. **UTType 过滤实际被关闭。** 6fa2ddf 把函数钩子和 _LSDReadClient 钩子置于两个 `#if 0` 块，删除了 UTTypeHooks 分组及符号初始化。恢复参照的六个函数钩子和九个请求钩子；以 CoreServices image、六个函数地址、记录类访问器全部存在为安装条件。保留原回调签名及 Apple core/public-domain 排除规则。嵌套请求保存/恢复原线程状态，`@finally` 确保异常不遗留过滤状态与 busy 计数。仍需 iOS16 各小版本实测私有 ABI。
2. **RunningBoard iOS16 模块未接入。** 增加 systemhook 定向加载、roothidehooks 分派和 `-[RBProcess _allowedLockedFilePaths]` 路径修正。Objective-C IMP 保留 self 与 SEL 两个参数；image/符号/进程访问器缺失不安装或沿用原结果。不引入 iOS15/palera1n/iOS17 子系统。
3. **本地 `rootfs` 宏语义错误。** `BaseBin/_external/include/roothide.h` 将 `rootfs` 和 `jbroot` 都写成前缀拼接，不能完成反向坐标转换。修复当前两个调用点（pathhook 与新增 RunningBoard）使用官方 `rootfs_alloc`/`jbroot_alloc`，按官方约定释放返回缓冲区。通过现有 jbroot 内 `/usr/lib/libroothide.dylib` 可选加载；库/函数不可用则保留原路径，不新增强链接依赖。RunningBoard realpath 失败保留原 allowance，pathhook 只有新 URL 创建成功才释放原 URL。
4. **jailbreakd 消息边界。** 在任何字典操作前校验消息类型和 id 类型；检查 reply 创建失败、64 位 id 截断、无效调用方 PID、请求 PID 越界。未知操作返回 ENOTSUP。关闭日志的 release daemon 收到 SYSTEMWIDE_LOG 时返回成功而非 abort。TEST_CALL 倍增使用 int64 边界检查；原 root 专用 crashreporter 测试保留。
5. **进程名获取失败。** `_NSGetExecutablePath` 失败时返回 nil，避免把未初始化缓冲区构造为进程名。
6. **trustcache 读取/分配失败。** 检查 open/fstat/malloc、普通文件及 v1 头、长度一致性；循环处理短读和 EINTR，所有退出路径关闭 fd 并释放内存，输出指针失败时置空。哈希批量转换由栈上 VLA 改为检查过的堆分配。大小计算用溢出检查。
7. **dyld 生成失败被误报成功。** 检查目录/副本/链接操作，失败立即返回；安装新 dyld 前保留旧 vnode，新文件移动失败时尝试恢复旧路径，回退失败单独报错。不把进程中断/断电场景说成已经事务化。getAMFI 查找失败释放 MachO 对象。

## 官方依赖核验

CI 固定 Theos `88506b2c22e9e07dd4ed055f23c9e398a117a2c7`。其 headers 子模块 `ac1c4fd21214548d6d308fcb835d30df1e43953d` 的 roothide/roothide.h 声明：rootfs 为 rootfs→jbroot 坐标转换，jbroot 为反方向，alloc 变体需 free。lib 子模块 `85e9b5b8aff11bbefc59525c64c8f55149926e56` 的 iphone/roothide/libroothide.tbd 导出这两个 alloc 函数，安装名为 @loader_path/.jbroot/usr/lib/libroothide.dylib。通过 GitHub API 只读核验。

## 验证

- 既有 12 项源码契约、新增 4 项服务、2 项 trustcache、3 项 dyld 契约，共 21 项通过。
- 新增 test_rc9_services.py --native：编译实际生产方法/函数，模拟 OS/XPC 边界，覆盖嵌套 UTType 请求与异常恢复、RunningBoard 普通/JB 应用与路径失败、异常消息、PID 越界、日志请求、未知消息及整数溢出。使用 macOS Foundation 和 ASan/UBSan。
- 新增 trustcache 故障注入和 dyld 安装/回退测试；f71e060 的 full run 40499573382 中全部 native 回归已通过（ASan/UBSan），完整 iPhoneOS 构建及制品上传成功，完成于 2026-10-27 19:55:54（Asia/Shanghai）。证据为 artifacts/2026-10-27-health-status/build-f71e060.json。前三次失败为新增 fixture 的 SDK 名称冲突/诊断函数缺失，随后一次发现溢出检查在 64 位下的编译警告，均已修正；不跳过失败测试。
- 内置 bootstrap_1900.tar.zst 已确认包含 /usr/lib/libroothide.dylib 和两个 alloc API 字符串；依赖证据在 artifacts/2026-10-27-health-status/bootstrap-path-api.json。
- Windows 无 Apple 编译环境；源码检查不能替代 native/iPhoneOS 构建或真机。

## 继续审计与未决项

- hookd 已读取输入边界及客户端；独立 hookd 未列入当前 BaseBin subprojects，需查清实际加载路径再判断影响，不能将死代码问题写成已证明的设备缺陷。
- Mach/XPC 超时、端口归属与完整内核信任链仍需审查。独立 hookd 未进入当前 subprojects/launchdhook，不能把其审查等同于当前实际执行链验证。
- 已确认的共同代码模式：launchdhook/update.m 的 basebin 逐项 remove/copy 忽略返回值；Application 的有效 RootHide bootstrap 分支先删除旧 basebin 再解包。此次已逐段核对，本地 zqbb 参照也如此，不能归类为 RC9 移植遗漏。这证明相应失败路径缺少检查/原位恢复，不证明用户设备发生过更新损坏；后续先验证调用方、触发条件与恢复路径，再决定补丁范围，不把全面事务重构当作已证明必要的修复。
- 用户于 2026-10-27 明确反馈管理器闪退已解决，移出未解决故障列表；未提供足以把原因归于某一个 runtime 补丁的证据。
- 不修改 Glass/Issuer/Supporter、黑白名单配置、字体/VPN 偏好，不将分析模块或独立 HelloBundleID 授权任务混入本次提交。

## 2026-10-27：针对“zqbb 对照是否也有这些问题”的复核

RC9 读取版本为 f71e060c1bc61f7c8273068867d5f465334868b2。参照限于用户本地 `参照官方dopamine/Dopamine-3.x_roothide`，不声称代表作者远端最新提交。该目录没有独立 .git 元数据，以下以实际文件内容和行号作为证据。除本记录外，此次没有修改生产代码。

### RC9 的对齐遗漏／偏离：以 zqbb 的 iOS16 实现为依据修复

- 共享 common：zqbb 的 launchdhook/Makefile:15 编译公共目录，common/common.c:222、229 调用 allowInjectWithSafeMode；RC9 当前两个目标已共享 common/common.c，并在 :255、261 恢复该调用。不是需要长期维护两套不同越狱实现。
- UTType：zqbb 的 roothidehooks/src/lsd.x:236、703 有分组和初始化；`git show b8800ef:BaseBin/roothidehooks/lsd.x` 确认 RC9 修复前存在两个 #if 0 块。当前 RC9 lsd.x:237、765 已恢复，另保留符号检查和异常恢复。
- RunningBoard：zqbb 的 roothidehooks/src/runningboardd.x:60、78 明确包含 iOS16 分支，systemhook/src/roothider_main.c:642 有加载路径；b8800ef 的 RC9 不含该模块。当前 RC9 已补入；不需要为此引入 iOS17/18 子系统。
- 日志请求 abort：b8800ef 的 RC9 jailbreakd/src/server.m 在 ENABLE_LOGS 关闭时有 `#else abort()`；zqbb 对应 :136–155 无该 abort。当前 RC9 :183–185 返回成功。root 专用 TEST_CALL 的 abort 在两边都存在，是另一条路径，不能混为同一问题。

### 双方共有的失败处理缺口：zqbb 没有可直接复制的完整修复

| 项目 | zqbb 本地证据 | 当前 RC9 证据／状态 |
|---|---|---|
| basebin 逐项更新 | launchdhook/src/update.m:54–63：目录读取、删除与复制结果未检查 | 同文件 :57–66 相同模式；尚未改造，不是 RC9 特有遗漏 |
| RootHide basebin 重建顺序 | Application/Dopamine/Jailbreak/DOBootstrapper.m:1331–1342：先删除，再解包；解包错误返回，没有在该分支恢复旧目录 | 当前 :1264–1305 同样顺序，另有 dyld.old 删除异常处理；后者不等于完整回滚 |
| trustcache 读取与分配 | libjailbreak/src/trustcache.c:408–409 未检查 malloc；:425–437 未检查 open/fstat/read，短文件分支直接返回而未 close | 当前已补检查、完整读取与失败清理；属于源码证据驱动的补强，不应声称复制自 zqbb 已修实现 |
| dyld 生成及移动 | libjailbreak/src/basebin_gen.m:133–149 忽略多项文件操作结果；:162–169 移动后直接 return 0 | 当前已检查返回值并尝试安装失败回退；不等于断电中断恢复已完成 |
| jailbreakd 消息边界 | jailbreakd/src/server.m:29–33：先创建 reply、取字典 id，后检查 dictionary 类型 | 当前 :32–46 已先校验类型和 id；这是额外错误处理，不是上游已有检查的简单移植 |

上述 DOBootstrapper 行号均指实际 RootHide 方法：zqbb 方法从 :1252 开始，RC9 从 :1184 开始；没有把前面的 #if 0 旧方法当作有效运行代码。

参照文件 SHA256：
- launchdhook/src/update.m：49a7fd249cd76f491b2da4e276c4513281075d70f83b388fc96533f86e03438e
- Application/Dopamine/Jailbreak/DOBootstrapper.m：c6559bab35349640e6e94d65b1394d65022b8fd588601a9cc7d10050195eea41

### 尚未形成缺陷结论的审查项

Mach/XPC 超时、端口归属、完整 trustcache 并发/内核生命周期仍是审查范围，尚不能表述为“RC9 存在这些 bug”，也没有证据断言 zqbb 已全部解决。CI、包静态核验和真机验证是不同的验证层级，不应计作三个已确认代码缺陷。

后续原则：限定 iOS16，逐函数对照实际编译与调用链；优先恢复 zqbb 已有且适用的逻辑；每个保留差异注明行为和证据；共同失败路径用复现或故障注入决定最小修改；无证据时不改生产代码，不以“定制”或“健康审计”泛化解释差异。
