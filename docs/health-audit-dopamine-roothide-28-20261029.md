# RC9 Health Audit Against Dopamine RootHide 28

Date: 2026-10-29 (Asia/Shanghai)

## Baseline and limits

The reference is the user-provided local directory `参照官方dopamine/Dopamine-roothide-28`. Its project metadata identifies Dopamine `3.0.12` and RootHide `28`. The directory has no `.git` metadata, so its originating commit and whether it matches the author's latest remote state cannot be verified from this checkout. This audit pins important reference files by SHA-256 below.

The reference supports several architectures and system releases. This comparison is limited to code paths compiled or selected for the RC9 iOS 16 target. An upstream-only file or branch is not automatically a defect: project layout, target membership, call sites, and runtime availability must all match before porting behavior.

This is a staged audit, not a claim that all RC9 code has been reviewed or that the device has passed end-to-end testing. Existing user changes, local backups, and generated artifacts are outside this audit.

## Confirmed comparisons

| Area | RootHide 28 reference | RC9 at `0478d481` | Finding |
|---|---|---|---|
| Basebin userspace update | `BaseBin/launchdhook/src/update.m` ignores directory enumeration and per-item remove/copy results; daemon plist parsing/writes are unchecked. | `BaseBin/launchdhook/src/update.m` validates staged trustcache/version/plists, checks replacement and marker operations, and attempts temporary extraction cleanup. | The reference retains the failure-handling gap. RC9 has the stronger tested implementation. A mid-copy failure can still leave a partial live replacement; this is not transactional rollback. |
| Archive extraction | `BaseBin/libjailbreak/src/util.c` ignores severe `archive_write_header` errors and leaks reader/writer objects on early returns. | `BaseBin/libjailbreak/src/util.c` propagates severe header errors, checks bounded paths, and closes/frees archive objects on exit. | The reference retains the failure-handling gap. RC9's focused native and real-libarchive tests plus full CI are recorded in `docs/update-failure-audit-20261027.md`. |
| Trustcache file input | `BaseBin/libjailbreak/src/trustcache.c` does not check `malloc`, `open`, `fstat`, or `read`; a short-file return can leave the descriptor open. | RC9 validates allocation, file metadata and reads, and cleans up failed paths. | RC9 has additional input/error handling. This comparison does not establish that either implementation's kernel trustcache lifetime is fully safe. |
| Generated basebin/dyld | `BaseBin/libjailbreak/src/basebin_gen.m` ignores multiple copy, directory, link, remove, and move results. | RC9 checks these operations and attempts recovery when the final dyld move fails. | RC9 has additional failure handling; it is not power-loss or process-interruption transactional recovery. |
| RootHide bootstrap rebuild | The active RootHide path in `Application/Dopamine/Jailbreak/DOBootstrapper.m` removes the old `basebin` before extracting the replacement. | The baseline RC9 path had the same gap; the current worktree stages, validates, marks, and directory-swaps the replacement, with backup recovery on the next attempt. | Current RC9 closes the modeled basebin directory interruption window at source level. Foundation/libarchive fault injection, power-loss durability, and device validation remain outstanding; generated dyld and trustcache lifecycles are separate. |
| jailbreakd request validation | `BaseBin/jailbreakd/src/server.m` creates a reply and reads the message ID before checking that the request is a dictionary. | RC9 checks the dictionary and ID types, reply creation, numeric bounds, and caller/target PID bounds before dispatch. | RC9 has additional malformed-input handling. |
| UTType hooks | RootHide 28 has the active `UTTypeHooks` group and initializes it when required symbols are present. | RC9 has the active group plus additional runtime class/API guards and exception-state restoration. | No missing-hook finding in the current RC9 tree; retain the additional guards unless iOS 16 runtime evidence contradicts them. |
| RunningBoard iOS 16 | RootHide 28 registers `_allowedLockedFilePaths` for iOS 16+, but does not check image/symbol lookup before initialization and drops paths that fail `realpath`. | RC9 checks image/symbol/process access, uses the Objective-C IMP signature including `SEL`, and preserves an allowance if canonicalization fails. | RC9 has deliberate defensive differences. Validate private ABI on supported iOS 16 releases; do not replace with the less guarded reference verbatim. |

The six high-risk error-handling reference files are pinned by SHA-256:

| Reference file | SHA-256 |
|---|---|
| `BaseBin/launchdhook/src/update.m` | `49a7fd249cd76f491b2da4e276c4513281075d70f83b388fc96533f86e03438e` |
| `BaseBin/libjailbreak/src/util.c` | `60af6658fa334dfb85a15a2683f20ffb9749690432248c14a56f57aa3c04dee9` |
| `BaseBin/libjailbreak/src/trustcache.c` | `4400bbea25c7f43d9e639ba4d797fdcd93e827fb5b7ff2258c1277542d46869a` |
| `BaseBin/libjailbreak/src/basebin_gen.m` | `da8cae711f097e3a532f55a4991d90ab3ef9be6407563e248a6a787b21612732` |
| `BaseBin/jailbreakd/src/server.m` | `ccca43a5bfe6290325bda2e6ce6379298d0da39ca0362c061759b1904149d9bd4` |
| `Application/Dopamine/Jailbreak/DOBootstrapper.m` | `62c171c4b360dfa05b554c12de5de655fcc2a0bfdec769b5b12a0cad9e7a5e13` |

## Structural differences requiring semantic review

- RootHide 28 builds `libroothider` as a separate BaseBin project. RC9 places the corresponding code under `BaseBin/libjailbreak/src/roothider`. File absence at the old path is therefore a layout difference, not by itself a missing feature.
- RootHide 28 includes additional system and architecture branches, including iOS 17/18+ and arm64 support. Their presence is not a reason to add those branches to the iOS 16 RC9 target.
- RootHide 28's RunningBoard implementation is less defensive than RC9 around symbol lookup and unresolved filesystem paths; RC9 differences are intentional pending device ABI verification.
- RootHide 28's trustcache code documents a concurrency/lifetime concern when replacing an existing kernel trustcache. RC9 has a mutex around parts of RootHide dynamic trustcache work, but this audit has not established that all upload, replacement, and kernel-reader lifetime paths share a sufficient synchronization contract.

## Confirmed XPC dispatch difference

The iOS 16 JBServer path had a protocol difference from RootHide 28. The reference returns `true` after applying its blacklist-specific message handling, and `jbserver_received_xpc_message` returns `-2` before looking up a JBServer domain. RC9 previously exposed a `void` handler and continued dispatch after blacklist processing. The RootHide domain independently rejects blacklisted callers, but `JBS_DOMAIN_ROOT` only checks effective UID 0; therefore its permission handler did not provide the same blacklist boundary for root-owned blacklisted clients.

RC9 now returns a boolean from `roothide_handle_xpc_msg`, returns `true` for blacklisted callers after retaining its existing message filtering, and makes JBServer return `-2` before domain lookup. The existing `check_usreboot_msg` call remains before the blacklist check, preserving RC9's prior ordering. Added a source-contract regression in `tests/test_rc9_services.py`.

This confirms the dispatch-boundary mismatch and its reachable root-domain path; it does not establish that a particular device/app configuration makes the difference exploitable. Native execution and on-device regression testing remain outstanding.

## iOS 16 injection chain review: no additional defect confirmed

RC9's launchd prehook applies `isBlacklistedPath()` locally before entering the shared spawn hook. The shared `common.c` is compiled into both launchdhook and systemhook; `RC9_LAUNCHD` excludes only the server-side dynamic-blacklist IPC from launchd, avoiding a launchd-to-JBServer dependency at that boundary. The systemhook path performs the dynamic blacklist query and both paths then apply the shared ProcessBlacklist, zqbb whitelist, SafeMode, DriverKit, hook-existence, and environment cleanup rules.

The two-manager behavior is intentional and must remain distinct: presence of `cn.zqbb.inject.plist` activates zqbb's executable whitelist, `cn.zqbb.inject.system.plist` supplies path-substring system allowances, and RootHide app blacklist handling is gated per executable by `cn.zqbb.inject.wantsblacklist.plist`. The independent tweak-injection toggle remains at the TweakLoader boundary. In particular, do not reinterpret the RootHide blacklist as an unconditional override of zqbb's whitelist.

Build membership also matches the active call graph: BaseBin builds both launchdhook and systemhook, launchdhook compiles the shared spawn implementation and zqbb policy code, and libjailbreak compiles its `src/roothider` sources. Existing policy and shared-spawn contract tests cover these boundaries. No further source-level defect was confirmed in this pass; device behavior and native tests remain unverified in this Windows environment.

## Confirmed XPF custom-set construction defect

RC9's initial patchfinding path in `Application/Dopamine/Jailbreak/DOJailbreaker.m` and the later userspace refresh path in `BaseBin/launchdhook/src/update.m` appended `namecache` and, when supported, `amfi_oids` to the set list passed to `xpf_construct_offset_dictionary()`. RC9 had no local registration for these custom sets. RootHide 28 defines their `XPFSet` metrics and item callbacks in `BaseBin/libroothider/src/xpf.m`; its wrapper first constructs the normal dictionary, then registers the custom items and appends the RootHide sets with `xpf_offset_dictionary_add_set()`. Its source comment explicitly says to keep these names out of the original set list.

RC9 now carries that wrapper implementation in `BaseBin/libjailbreak/src/roothider/xpf.m`. `libjailbreak` links `libxpf`, and both RC9 call sites use the wrapper, so initial patchfinding and subsequent system-info refresh use the same offset construction path. The BaseBin target dependency now builds XPF before libjailbreak. The added contract test checks registration, append ordering, and both call sites.

The RC9 XPF gitlink points to `b703bf3b3fee75ea18c676cc00e87f9770957cc3`, but that submodule is not checked out and its git object is unavailable in this workspace. The defect conclusion is based on RC9's absent local registration and the matched RootHide 28 wrapper contract; compatibility still needs a real build against the locked XPF revision and on-device patchfinding. The Python 3.14.7 interpreter is installed, but the Windows `py` launcher does not discover it and the `python` command resolves to a non-runnable WindowsApps alias. Running the suite through the interpreter's full path passes all 29 source-contract tests. Native macOS/Foundation tests and the iOS build remain unavailable in this Windows environment.

Follow-up review of the copied XPF implementation found two upstream error-path defects. When the namecache adjacency check failed, both offsets were set to `-1`; because the callback returns `uint64_t` and the cache check treats any nonzero pair as initialized, the invalid value could be returned as a successful offset. RC9 now resets both values to zero so the existing failure check aborts patchfinding. Also, the wrapper now releases its newly-created XPC dictionary when appending RootHide sets fails. The initial patchfinding caller now releases the successfully consumed offset dictionary before replacing it with serialized system info, and the update path releases both temporary dictionaries after deserialization. The current 31-test source-contract suite passes with assertions for these cases; neither source assertion substitutes for a build against the locked XPF revision or device patchfinding.

## Staged-update request acknowledgment

Both RC9 and RootHide 28's `platform_stage_jailbreak_update()` checked that the archive path existed but ignored `setenv("STAGED_JAILBREAK_UPDATE", ...)`. If environment allocation fails, the platform XPC action could report success and `DOEnvironmentManager` would start a userspace reboot, while launchd had no staged archive path to apply. RC9 now returns a nonzero result when `setenv` fails, and `tests/test_rc9_services.py` includes a contract assertion. This is a narrow shared edge-case fix, not an upstream alignment change; runtime fault injection remains unrun in this Windows environment.

The basebin updater also previously set `JBUPDATE_PREV_VERSION` and `JBUPDATE_NEW_VERSION` only after replacing the trustcache and live files. An environment allocation failure at that point returned an error after mutation, and the caller escalates updater errors through `launchd_panic()`. RC9 now reserves both finalizer markers after staging validation but before trustcache upload or live replacement, and clears them from `@finally` on subsequent failure. The updater runs synchronously inside the userspace-reboot spawn hook; in normal control flow, the reboot process is passed to the original spawn only after update success, and the markers are consumed by the later launchdhook initializer. The native updater fixture was extended so marker-allocation failures must leave the live basebin untouched and must not upload the staged trustcache; its failure cases also assert that later updater failures clear the markers. This narrows the marker-allocation failure window; it does not make the later per-item replacement interruption-safe. The source-contract suite passes, but the Objective-C/Foundation fault-injection executable cannot run on this Windows host.

## Archive extraction path confinement

RC9 and RootHide 28 both prepend the destination directory to each archive pathname, but neither enabled libarchive's `ARCHIVE_EXTRACT_SECURE_NODOTDOT` or `ARCHIVE_EXTRACT_SECURE_SYMLINKS`. A `..` entry can therefore escape the extraction root; an archive can also create a symlink and then attempt to write a later entry through it. Hardlink targets use a separate archive field and likewise need confinement. The helper is used both for staged basebin updates and bootstrap extraction, so the destination may be a temporary directory or the live jailbreak root. RC9 now enables both libarchive protections, rejects absolute hardlink targets and any `..` hardlink path component, prefixes relative hardlink targets with the extraction root, and fails if the requested options cannot be applied. `tests/test_rc9_update.py` adds real-libarchive cases for traversal, a symlink pivot, and an absolute hardlink target, while retaining regular-file and leaf-symlink cases; the native stub also verifies relative hardlink traversal rejection. The 29 Python source-contract tests pass, but the new real-libarchive runtime cases require the macOS native test environment and have not run here. A full build/device test must also confirm that shipped archives do not rely on extracting through a previously created symlink or hardlink target.

### CI follow-up: destination aliases

Private Actions run `40873413441` at `caabb516` passed the injected archive
tests but failed real extraction with `Cannot extract through symlink` for a
destination under `/var/folders`. The two earlier fixture changes did not
resolve this failure. Libarchive checks every destination path component,
including the caller-supplied extraction directory; changing tar headers
does not resolve filesystem aliases such as Darwin's `/var`.

The extractor now resolves the existing destination prefix with `realpath`
and appends any not-yet-created directory suffix before prefixing archive
entries. Archive entry paths and hardlink targets retain their confinement
checks. Native coverage includes existing and missing destinations under an
explicit directory symlink, nested directories, relative destinations, and
path-resolution failure. Local source-contract tests pass; macOS native and
full TIPA validation must be recorded from the new CI run.

### CI follow-up: hosted runner allocation

Public manual run `40880284312` (`0575a045`, run number 557) ended without
executing any steps. Its check annotations report that the hosted runner
did not acquire the job after multiple attempts, with macOS arm64 capacity
notices. This run provides no native-test or compilation result.

GitHub's runner-images announcement `actions/runner-images#13518` schedules
macOS 14 retirement for 2026-11-02, with a brownout on 2026-10-29 from
14:00 UTC. Run 557 ended at 13:30 UTC, before that brownout; the annotation,
not the brownout schedule, establishes its allocation failure.

The RC9 build workflow now requests `macos-15-intel` and Xcode 16.2 with
the matching iPhoneOS 18.2 SDK check. GitHub's published macOS 15 Intel
software manifest lists that toolchain. The separate Theos SDK remains
16.5. Manual dispatch now defaults to a full build, matching branch-push
builds. Native and full-build compatibility still require an executed CI
run; changing runner configuration does not validate RC9's runtime code.

### CI follow-up: ARC ownership compilation failure

Public run `40885020218` (`affaf13a`, run number 558) acquired a macOS 15
Intel runner, passed all six native regression scripts, and reached the full
iOS build. This includes the real-libarchive alias, traversal, symlink-pivot,
hardlink, truncated-archive, and permission-error cases. Full compilation
then failed on explicit `xpc_release` calls in ARC-compiled `blacklist.m`
and the new XPF wrapper. The earlier source-contract assertions had required
those calls without accounting for ARC, and did not catch this defect.

The pure-C XPF implementation now uses the `.c` extension so its manual
cleanup matches the C XPF API. Its public declaration, and the C serializer
`jbinfo_get_serialized`, declare their retained return values for Objective-C
callers. The policy cache already had that annotation. Objective-C consumers
now rely on ARC, retaining explicit release calls only when XPC objects are
not managed by ARC; the app also clears its consumed instance variable.
The next full run must validate compilation and packaging.

Public run `40885984595` (`97d62925`, run number 559) passed the native
suite and built BaseBin, including the C XPF wrapper and launchdhook.
The App build reached asset catalog compilation, where Xcode 16.2's
`actool` rejected the installed simulator runtimes: SDK build `22C146`
had no matching runtime among the image's installed versions. The workflow
now selects the image's Xcode 16.4 and iPhoneOS 18.5 SDK, matching its
installed iOS 18.5 runtime (`22F77`). No asset compilation is skipped.

Public run `40887818486` (`f56d19cd`, run number 560) progressed past the
previous toolchain mismatch, but the App compile found another defect in
the staged-bootstrap change: `jbrootPrefix` was first called above its
declaration. Its existing declaration is now placed before the first
`DOBootstrapper` implementation. The declaration-order contract is checked,
and the next full build must verify the App and final artifact.

## Basebin trustcache collection errors

RC9 and RootHide 28 both enumerate regular files, call `ensure_randomized_cdhash()`, and silently skip every nonzero return. That is needed for expected data files such as plists and `.version`, but it also hides failures to rewrite a valid Mach-O's signature, potentially publishing that file without its cdhash in the new basebin trustcache. RC9 now first classifies parseable Mach-O files with ChOma's read-only `fat_init_from_path()`; non-Mach-O data stays skipped, while randomization failure for a parsed Mach-O, resource lookup failure, or directory enumeration failure aborts trustcache preparation. Missing input paths and missing regular-file attributes also fail explicitly, with nonempty fallback diagnostics. Call-graph search found one RC9 caller: the basebin updater processes the extracted staging directory before replacing live files. It is not the initial jailbreak trustcache path, so a collection failure prevents staged publication. The focused source-contract check is in `tests/test_rc9_services.py`. Actual iOS 16 signature rewriting still requires native/device validation.

## Trustcache replacement remains an unresolved lifecycle risk

RootHide 28 and RC9 both replace a same-UUID, differently-sized trustcache by unlinking the old node, sleeping 10 ms, freeing it, then allocating and inserting the replacement. Both implementations acknowledge that this only hopes in-flight kernel readers have finished. RC9's `gJbTrustcacheLock` protects its own append/clear operations, but `trustcache_file_upload()` is outside that lock, and a userspace mutex would not synchronize kernel readers of the trustcache list. RC9's basebin and dyld trustcache upload paths can reach the UUID replacement API.

No verified kernel reader-quiescence primitive or device reproducer is available in this audit environment. Therefore this is not classified as an RC9-only regression and was not changed: replacing the delay with another arbitrary wait would not establish memory reclamation safety. A robust fix requires a platform-supported synchronization contract or a design that never frees/reuses a published node.

## Bootstrap and generated-dyld recovery gaps

In the active RootHide bootstrap path, `DOJailbreaker` calls `prepareBootstrap` before loading the basebin trustcache and before `basebin_generate(false)` creates the runtime `.fakelib`/dyld state and `restoreFakeMounts` runs. RootHide 28 removes the existing `basebin` and extracts the bundled archive directly into the live jailbreak root. RC9 previously followed that destructive ordering; the current worktree now stages the archive under `.basebin-rc9-stage`, patches and validates daemon plists, removes the staged trustcache, and writes a readiness marker before moving the old directory to `.basebin-rc9-backup` and publishing the staged directory. Recovery restores the backup if publication stopped after the old directory was moved, accepts a marked new generation and removes its backup if publication completed, and rejects ambiguous unmarked live/backup combinations without deleting either. The same recovery routine runs before a new publication attempt. This protects the basebin directory across the modeled process-interruption points; it does not establish power-loss durability, validate libarchive's extraction behavior on device, or make the subsequent trustcache, generated-dyld, and fake-mount lifecycle transactional.

RC9's generated-dyld path is more defensive than the reference: it checks copy/patch/sign/move operations and attempts to move `dyld.old` back if publishing the new dyld fails. The bootstrapper in both trees also has a special cleanup path for a `dyld.old` file that cannot be deleted, moving that historical corrupted orphan out of `basebin` so bootstrap removal can proceed. That cleanup is not recovery for an interrupted dyld publish: it does not decide whether `dyld.old`, `dyld`, or `dyld.inflight` is the valid generation, nor repair their symlink/trustcache relationship. There remains an interruption window after moving the live dyld to `dyld.old` and before promoting `dyld.inflight`; the ordinary error rollback runs only if execution continues. Closing that window needs a startup recovery protocol that validates generations and accounts for the live fakelib symlinks, loaded vnode lifetime, and trustcache. No production change was made without that contract.

Follow-up bootstrap review found that `patchBasebinDaemonPlists` also ignored directory enumeration, plist parsing, and write failures after extraction. RC9 now validates `ProgramArguments`, writes changed plists atomically, and propagates errors so bootstrap does not report success with an unpatched daemon configuration. The staged publisher applies this validation before publication; the regression suite parses both shipped daemon plist resources and confirms their argument arrays contain the expected `@JBROOT@` tokens. Its source-contract test checks the recovery branches and the stage/ready/backup ordering, but does not execute filesystem fault injection against Foundation or libarchive on the target OS.

The basebin update path also remains non-transactional after validation. It removes each colliding live item before copying its staged replacement; a later remove/copy error is reported and prevents successful finalization, but previously replaced items are not restored. Normal archives omit runtime-generated `gen` and `.fakelib`, so those live paths are not ordinarily overwritten by this loop, but a mid-copy failure can still leave a mixed basebin. The updater replaces the fixed-UUID basebin trustcache before beginning these copies; blindly restoring old binaries afterward could leave their randomized cdhashes absent from the active basebin trustcache. RootHide 28's updater has the same replacement model. The failure-injection tests verify error propagation and that runtime paths in the fixture remain untouched; they do not establish rollback. Today's call-graph audit confirms trustcache preparation is staging-only; it reduces risk from a rejected payload but does not make the later live replacement atomic. A production change needs a tested rollback or publish protocol that coordinates payload and trustcache generations, including recovery after process interruption, rather than only a temporary in-process backup.

## RC9 fixes already present before this comparison

The current audit branch already contains fixes for identified RC9-to-reference alignment gaps and local failure paths, including the iOS 16 RunningBoard path correction, re-enabled guarded UTType hooks, jailbreakd input validation, trustcache input validation, checked dyld generation, and update/archive error propagation. Their individual evidence remains in `docs/health-audit-20261027.md` and `docs/update-failure-audit-20261027.md`.

The XPC dispatch, trustcache collection, and update-marker fixes above are production changes from this comparison. RC7 is outside this RC9 audit.

## Delivery status

At baseline `0478d48`, the reviewed areas in this report had 29 source-contract tests. The current worktree has 32 tests, including the basebin publication/recovery contract; all 32 pass under `C:\Users\KOKOL\AppData\Local\Programs\Python\Python314\python.exe -m unittest discover -s tests`, and `git diff --check` is clean. The updated bootstrap test now asserts the active `prepareBootstrapWithCompletion:` calls the staged publisher and that plist-patch errors are propagated. These source-contract checks do not execute the Objective-C filesystem state machine and do not retroactively validate the baseline commit. This is a scoped audit of the listed RC9 paths, not certification of every source file.

Reviewing the remote build path found that the new XPF wrapper was called from the app and launchdhook but had no declaration in RC9's public `common.h`; an explicit declaration and source-contract assertion have now been added. The full macOS workflow builds the application and BaseBin, so it can verify this interface and the bootstrapper changes. The workflow supports manual dispatch and automatically runs full builds on pushes to `codex/health-audit-20261027`; no successful Apple compile has yet been recorded for the current candidate.

The result is not yet device-validated: the Objective-C/Foundation fault-injection tests require macOS, the iOS build requires Apple's SDK/toolchain, and neither is available on this Windows host. On-device iOS 16 behavior also remains unverified.

Remaining runtime validation risks: basebin publication needs device and power-loss durability testing; generated dyld still has an interruption window without startup generation recovery; and safe reclamation of replaced kernel trustcache nodes needs a verified reader-lifetime contract. Source-contract tests cannot establish those guarantees.
