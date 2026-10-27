# RootHide Manager · Trust

> 2026-10-27 设备反馈：Sileo / RC9 c252f6a 上两个 trust1 应用均启动闪退，trust1 已撤回。
> trust2 是恢复原始启动元数据/归档约定的排障候选，尚未确认修复。没有设备日志，根因未定。

只维护用户确认后的 BindFS 挂载信任，以及 VPN/代理检测提示偏好。
字体挂载属于 BindFS 挂载的一种；不会自动信任所有挂载，也不修改网络状态或内核 trustcache。
RCInjectAnalysis 不纳入此适配。

## 版本约定

| 管理器 | 包版本 | 保持原始应用版本 |
| --- | --- | --- |
| RootHide Inject Manager | 3.2.1-5+trust2 | 3.2.1-5 |
| RootHide Manager | 1.3.9+trust2 | 1.3.9 |

保留应用名称、包 ID、配置路径及最低系统版本。后续适配层更新递增 trust3、trust4。
Info.plist 完整字节保持原样，不向 CFBundleShortVersionString 填入展示文案。
“· Trust”仅用于说明和发行标签，安装器显示 +trust2。安装器按 Debian 包版本判断升级。
这是对 trust1 中不必要的启动元数据修改的撤回；不能在无日志情况下断言它是闪退根因。

## 已保存的内容

- source/blacklist/：从本地 Git 对象 b15df6a01b027d2e6850912576be9a6899ab151d 原样恢复的 AppDelegate、头文件、中英文本地化、MIT 许可证；provenance.json 记录哈希。
- source/blacklist/DetectionTrust.patch：652b6a6 到 b15df6a 的功能/文案补丁，不含旧 CI 和包版本变动。
- vendor/DetectionTrustHook.dylib：从用户旧版 3.2.1-3 FINAL 包提取的原始双架构 Hook。其 Objective-C 源码本次未找到；这是二进制归档，不能称为完整 Hook 源码。
- vendor/inject-3.2.1-5.deb：用户提供的新版原包，作为已审接口的固定输入。
- build.py：可重复打包、双架构加载命令适配、代码页及签名特殊槽哈希验证。
- test_build.py：检测代码/entitlement 损坏、重复适配、非法 padding，以及资源/设置保留。

## 构建

在仓库根目录运行 Python 3.11 或更新版本：

    python tools/manager-trust/test_build.py
    python tools/manager-trust/build.py --output artifacts/manager-trust

仅使用 Python 标准库。不执行 deb 的 postinst，不安装手机，不改当前 RC9 的内置包。
生成两个独立候选 deb、verification.json 和 SHA256SUMS.txt。
相同 Python/zlib 环境重复构建的 deb 字节一致；不同平台/版本的 gzip 压缩器可能产生不同压缩流。
跨环境核对应比较解压后的 control.tar/data.tar 和各文件哈希；交付以私有 CI 产物及其 SHA256 为准。
黑名单以 RC9 原有 1.3.9+bindtrust1 为底包，整个 data.tar.lzma 原字节直接复用，主程序、签名、Info.plist、资源和权限均原样保留，没有分析模块。
白名单恢复原包 data.tar.lzma 格式、原始 tar 成员路径（包括 ./postinst）和 Info.plist；不再添加 RHUpstreamVersion/RHTrustRevision 键。
白名单以 3.2.1-5 为底包，在两个 slice 的零填充头部追加 Hook 加载命令，不移动代码、数据、chained fixups 或既有依赖次序；保留 XML/DER entitlement 和 requirements，重算 SHA256 CodeDirectory 页哈希。
保留原包的无 CMS 签名结构；哈希校验不能替代 iOS 真机的加载验证。
macOS codesign 对提供的原版 Inject 3.2.1-5 也提示 no signature / invalid entitlements blob。
CI 记录并逐项对比原包与候选诊断，使用 ldid 独立读取 XML entitlement；不将该原包限制描述为 Apple 签名通过。
原签名没有非零 Info.plist 特殊槽哈希，不代表任意 bundle 元数据都满足设备注册/启动要求；trust2 不修改该文件。

## 后续升级流程

1. 保存新的上游原包和 SHA256，不直接覆盖已审输入。
2. 白名单核对 WhitelistViewController 的 setStartupMessages:、AppDelegate 的 getDefaultsForKey:/setDefaults:forKey: 的类型和行为；特别检查告警字典格式、语言、回调和新增展开/收起 UI。
3. 确认既有四个偏好键继续兼容：TrustedBindMountWarningsV1、TrustedBindMountsV1、IgnoreInjectVPNProxyWarningV1、IgnoreVPNProxyWarningV1。
4. 黑名单优先将源码补丁应用到新版源码，并核对告警入口。不要把旧主程序当作新版源码构建产物。
5. 审阅后更新固定哈希、版本和验证矩阵。脚本遇到未审输入或不同签名/架构结构会拒绝，不承诺任意新版本一键移植。
6. 检查版本排序、双架构、签名、权限、资源、原名单/自定义清理规则和模式切换，再做真机验证。

## 真机验收与回退

先在原环境安装黑名单 trust2 再单独启动：其整个应用数据归档与原 bindtrust 包相同，可用于区分重打包/元数据与设备环境问题。
如果仍闪退，停止连续换包，采集 RootHide 的崩溃或启动拒绝日志及 Sileo 安装输出；排查 postinst/uicache、.jbroot 依赖和 RC9 环境。
黑名单确认恢复后再测白名单 trust2。不要卸载清配置，也不要删除白名单/信任数据库。

先保存现有 RootHideConfig.plist、cn.zqbb.inject*.plist 和 varCleanRules-custom.plist。
验证正常启动；未信任挂载弹提示；“继续提示”不写入；只信任所选挂载；重启后承接偏好；VPN/代理提示偏好持久；未知告警仍展示；白名单折叠 UI 和两种模式切换正常。
更新包不会操作这些配置文件，但应用原有清理规则生成逻辑仍然存在。
从带 analysis 的旧黑名单包升级时，旧包拥有的 analysis 文件应由包管理器清理；真机尚未确认。
原输入包留作回退。回退到旧版本需安装器允许降级，不能卸载清配置后再装。

## 证据边界

Architecture: iphoneos-arm64e 是包字段；已审的上游和自定义管理器均同时含 arm64/arm64e Mach-O slice。
本次未新增设备支持承诺。RC9 后端 c252f6a 的策略修复与本目录的管理器适配是两个独立层次。
这是可复现的候选适配；真机测试完成前不要标记为正式发布版。
