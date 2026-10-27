# RC9 服务层健康审计（2026-10-27）

基线 b8800ef6974961aea7f173763d6f7329f47dd57f。参照为用户提供的 Dopamine-3.x_roothide 快照。
本报告是已检查模块的证据记录，不代表整个 RC9 零缺陷或真机验收完成。

## 已落实修复

1. **UTType 过滤实际被关闭。** 6fa2ddf 把函数钩子和 _LSDReadClient 钩子置于两个 `#if 0` 块，删除了 UTTypeHooks 分组及符号初始化。恢复参照的六个函数钩子和九个请求钩子；以 CoreServices image、六个函数地址、记录类访问器全部存在为安装条件。保留原回调签名及 Apple core/public-domain 排除规则。嵌套请求保存/恢复原线程状态，`@finally` 确保异常不遗留过滤状态与 busy 计数。仍需 iOS16 各小版本实测私有 ABI。
2. **RunningBoard iOS16 模块未接入。** 增加 systemhook 定向加载、roothidehooks 分派和 `-[RBProcess _allowedLockedFilePaths]` 路径修正。Objective-C IMP 保留 self 与 SEL 两个参数；image/符号/进程访问器缺失不安装或沿用原结果。不引入 iOS15/palera1n/iOS17 子系统。
3. **本地 `rootfs` 宏语义错误。** `BaseBin/_external/include/roothide.h` 将 `rootfs` 和 `jbroot` 都写成前缀拼接，不能完成反向坐标转换。修复当前两个调用点（pathhook 与新增 RunningBoard）使用官方 `rootfs_alloc`/`jbroot_alloc`，按官方约定释放返回缓冲区。通过现有 jbroot 内 `/usr/lib/libroothide.dylib` 可选加载；库/函数不可用则保留原路径，不新增强链接依赖。RunningBoard realpath 失败保留原 allowance，pathhook 只有新 URL 创建成功才释放原 URL。
4. **jailbreakd 消息边界。** 在任何字典操作前校验消息类型和 id 类型；检查 reply 创建失败、64 位 id 截断、无效调用方 PID、请求 PID 越界。未知操作返回 ENOTSUP。关闭日志的 release daemon 收到 SYSTEMWIDE_LOG 时返回成功而非 abort。TEST_CALL 倍增使用 int64 边界检查；原 root 专用 crashreporter 测试保留。
5. **进程名获取失败。** `_NSGetExecutablePath` 失败时返回 nil，避免把未初始化缓冲区构造为进程名。

## 官方依赖核验

CI 固定 Theos `88506b2c22e9e07dd4ed055f23c9e398a117a2c7`。其 headers 子模块 `ac1c4fd21214548d6d308fcb835d30df1e43953d` 的 roothide/roothide.h 声明：rootfs 为 rootfs→jbroot 坐标转换，jbroot 为反方向，alloc 变体需 free。lib 子模块 `85e9b5b8aff11bbefc59525c64c8f55149926e56` 的 iphone/roothide/libroothide.tbd 导出这两个 alloc 函数，安装名为 @loader_path/.jbroot/usr/lib/libroothide.dylib。通过 GitHub API 只读核验。

## 验证

- 既有 12 项源码契约与新增 4 项服务源码契约通过。
- 新增 test_rc9_services.py --native：编译实际生产方法/函数，模拟 OS/XPC 边界，覆盖嵌套 UTType 请求与异常恢复、RunningBoard 普通/JB 应用与路径失败、异常消息、PID 越界、日志请求、未知消息及整数溢出。使用 macOS Foundation 和 ASan/UBSan。
- 新测试已加入完整/focused CI。当前提交前尚未执行该 CI；构建结果另行记录。
- Windows 无 Apple 编译环境；源码检查不能替代 native/iPhoneOS 构建或真机。

## 继续审计与未决项

- hookd 已读取输入边界及客户端；独立 hookd 未列入当前 BaseBin subprojects，需查清实际加载路径再判断影响，不能将死代码问题写成已证明的设备缺陷。
- Mach/XPC 超时、端口归属、dyld/trustcache 和 bootstrap 更新恢复还需进一步审查。
- 两个 trust2 管理器没有设备启动回执或 .ips，不能声称本轮 RunningBoard 修复已经解决它们的闪退。
- 不修改 Glass/Issuer/Supporter、黑白名单配置、字体/VPN 偏好，不将分析模块或独立 HelloBundleID 授权任务混入本次提交。
