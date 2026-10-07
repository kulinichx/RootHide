#!/usr/bin/env python3
"""Exercise persistent stage logging; no iOS runtime or reboot is simulated."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'BaseBin/libjailbreak/src'

HARNESS = r'''
#include "roothide_stage.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void read_log(const char *path, char *buffer, size_t size) {
    FILE *file = fopen(path, "r");
    assert(file);
    size_t length = fread(buffer, 1, size - 1, file);
    buffer[length] = 0;
    fclose(file);
}

int main(int argc, char **argv) {
    assert(argc == 3 || argc == 4);
    const char *path = argv[2];
    if (argc == 4) {
        struct stat log_stat;
        assert(stat(path, &log_stat) == 0);
        for (int fd = 3; fd < 256; fd++) {
            struct stat fd_stat;
            if (fstat(fd, &fd_stat) == 0)
                assert(fd_stat.st_dev != log_stat.st_dev || fd_stat.st_ino != log_stat.st_ino);
        }
        return 0;
    }

    char buffer[8192];
    errno = EDOM;
    roothide_stage_log("disabled");
    assert(errno == EDOM && access(path, F_OK) != 0);
    char service_path[4096];
    snprintf(service_path, sizeof(service_path), "%s.service", path);
    errno = EDOM;
    roothide_stage_file_log(service_path, "bootstrap-only event=%d", 1);
    assert(errno == EDOM);
    read_log(service_path, buffer, sizeof(buffer));
    assert(strstr(buffer, "bootstrap-only event=1"));
    roothide_stage_log("must-remain-disabled");
    assert(access(path, F_OK) != 0); // One event must not enable general logging.
    assert(roothide_stage_begin(path, false) == 0);
    roothide_stage_file_log(service_path, "second-bootstrap-event");
    errno = ERANGE;
    roothide_stage_log("first result=%d", 7);
    assert(errno == ERANGE);
    read_log(path, buffer, sizeof(buffer));
    assert(strstr(buffer, "first result=7")); // Visible before close/normal exit.
    assert(!strstr(buffer, "bootstrap-event")); // Do not replace the active App log.

    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        execl(argv[0], argv[0], "inherited-fd-check", path, "exec", NULL);
        _exit(111);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid && status == 0);
    roothide_stage_end();
    roothide_stage_log("after-end");
    read_log(path, buffer, sizeof(buffer));
    assert(!strstr(buffer, "after-end"));

    assert(roothide_stage_begin(path, true) == 0);
    roothide_stage_log("app-reopened");
    roothide_stage_end();
    read_log(path, buffer, sizeof(buffer));
    assert(strstr(buffer, "first result=7") && strstr(buffer, "app-reopened"));

    pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        assert(roothide_stage_begin(path, false) == 0);
        roothide_stage_log("before-abrupt-exit");
        _exit(0); // No end(), fclose(), or exit() flushing.
    }
    assert(waitpid(pid, &status, 0) == pid && status == 0);
    read_log(path, buffer, sizeof(buffer));
    assert(strstr(buffer, "before-abrupt-exit") && !strstr(buffer, "first result=7"));

    char link_path[4096];
    snprintf(link_path, sizeof(link_path), "%s.link", path);
    assert(symlink(path, link_path) == 0);
    errno = EDOM;
    assert(roothide_stage_begin(link_path, false) != 0 && errno == EDOM);
    roothide_stage_log("file-open-failed-stderr-only");
    assert(errno == EDOM);
    roothide_stage_end();
    read_log(path, buffer, sizeof(buffer));
    assert(strstr(buffer, "before-abrupt-exit") && !strstr(buffer, "stderr-only"));
    assert(unlink(link_path) == 0);
    assert(symlink(path, link_path) == 0);
    roothide_stage_file_log(link_path, "must-not-follow-symlink");
    read_log(path, buffer, sizeof(buffer));
    assert(!strstr(buffer, "must-not-follow-symlink"));
    assert(unlink(link_path) == 0);
    assert(unlink(service_path) == 0);
    puts("PASS: persists before abrupt exit, append/truncate, errno, opt-in, no inherited fd, no symlink overwrite");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    workflow = (ROOT / '.github/workflows/roothide.yml').read_text(encoding='utf-8')
    assert 'run: python3 .github/scripts/test_roothide_stage_log.py' in workflow
    jailbreaker = (ROOT / 'Application/Dopamine/Jailbreak/DOJailbreaker.m').read_text(encoding='utf-8')
    assert jailbreaker.index('int logResult = roothide_stage_begin') < jailbreaker.index('int ret = basebin_generate(false)')
    ui = (ROOT / 'Application/Dopamine/UI/Settings/DOSettingsController.m').read_text(encoding='utf-8')
    assert 'shareRootHideStageLogPressed' in ui
    environment = (ROOT / 'Application/Dopamine/Jailbreak/DOEnvironmentManager.m').read_text(encoding='utf-8')
    reboot = environment.split('- (void)rebootUserspace', 1)[1].split('- (void)refreshJailbreakApps', 1)[0]
    assert 'dispatch_get_global_queue' in reboot and 'if (requestInFlight) return' in reboot
    assert 'Userspace_Reboot_Failed_Format' in reboot and 'userspace_reboot.return result=%d' in reboot
    assert 'spawnJbctlAsRootWithArgs:@[@"reboot_userspace"]' in reboot
    helper = environment.split('- (int)spawnJbctlAsRootWithArgs:', 1)[1].split('- (int)runTrollStoreAction:', 1)[0]
    assert '[self runAsRoot:^' in helper
    assert '"--waitfor"' in helper
    assert 'jbclient_dopamine_get_root()' in environment
    assert 'jbclient_dopamine_drop_root()' in environment
    assert 'seteuid(0)' not in environment and 'setegid(0)' not in environment
    assert 'setuid(0)' not in environment and 'setgid(0)' not in environment
    main_ui = (ROOT / 'Application/Dopamine/UI/DOMainViewController.m').read_text(encoding='utf-8')
    assert '[self fadeToBlack:^{\n                [[DOEnvironmentManager sharedManager] rebootUserspace];' not in main_ui
    assert '[self fadeToBlack:^{\n            [[DOEnvironmentManager sharedManager] rebootUserspace];' not in main_ui
    print('PASS: persistent diagnostics and post-relaunch export wired into App and CI', flush=True)
    if args.check_only:
        print('C logger harness NOT run (--check-only); Apple build and device behavior remain unverified.')
        return
    with tempfile.TemporaryDirectory(prefix='roothide-stage-') as directory:
        temp = Path(directory)
        harness = temp / 'test.c'
        harness.write_text(HARNESS, encoding='utf-8')
        binary = temp / 'test'
        # Darwin hides O_NOFOLLOW in the POSIX-only namespace. Enable its
        # extensions without removing strict C11 or warning checks.
        subprocess.run(['cc', '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror',
                        '-pthread', '-I', str(SOURCE), str(harness), str(SOURCE / 'roothide_stage.c'),
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary), 'test', str(temp / 'stage.log')], check=True)


if __name__ == '__main__':
    main()
