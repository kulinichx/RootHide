/*
 * systemhook links roothider/jailbreakd.c without roothider/common.m.
 * Keep the process-version primitive available in this standalone dylib.
 * The ABI layout and behavior mirror roothider/common.m.
 */
#include <libproc.h>
#include <stdint.h>
#include <sys/types.h>

struct roothide_systemhook_uniqidentifierinfo {
    uint8_t  p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t  p_idversion;
    uint32_t p_reserve2;
    uint64_t p_reserve3;
    uint64_t p_reserve4;
};

enum { ROOTHIDE_PROC_PIDUNIQIDENTIFIERINFO = 17 };

int proc_get_pidversion(pid_t pid)
{
    struct roothide_systemhook_uniqidentifierinfo info = {0};
    int ret = proc_pidinfo(pid, ROOTHIDE_PROC_PIDUNIQIDENTIFIERINFO,
                           0, &info, (int)sizeof(info));
    if (ret <= 0) return 0;
    return info.p_idversion;
}
