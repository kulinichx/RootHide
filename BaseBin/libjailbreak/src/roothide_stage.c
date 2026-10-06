#include "roothide_stage.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t gStageLock = PTHREAD_MUTEX_INITIALIZER;
static int gStageFD = -1;
static bool gStageActive = false;

void roothide_stage_file_log(const char *path, const char *format, ...)
{
    int savedErrno = errno;
    pthread_mutex_lock(&gStageLock);
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        if (geteuid() != 0 || fchown(fd, 501, 501) == 0) {
            struct timespec now = {0};
            clock_gettime(CLOCK_REALTIME, &now);
            char message[2048];
            va_list args;
            va_start(args, format);
            vsnprintf(message, sizeof(message), format, args);
            va_end(args);
            dprintf(fd, "[RootHideStage %lld.%03ld pid=%d] %s\n",
                    (long long)now.tv_sec, now.tv_nsec / 1000000, getpid(), message);
        }
        close(fd);
    }
    pthread_mutex_unlock(&gStageLock);
    errno = savedErrno;
}

int roothide_stage_begin(const char *path, bool append)
{
    int savedErrno = errno;
    pthread_mutex_lock(&gStageLock);
    if (gStageFD >= 0) close(gStageFD);
    // No stdio buffering, no child inheritance, and no following a symlink.
    // The mobile App must be able to read/append after temporary root ends.
    // Keep the file private, and transfer root-created logs to mobile.
    gStageFD = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW |
                   (append ? 0 : O_TRUNC), 0600);
    int result = gStageFD < 0 ? errno : 0;
    if (gStageFD >= 0 && geteuid() == 0 && fchown(gStageFD, 501, 501) != 0) {
        result = errno;
        close(gStageFD);
        gStageFD = -1;
    }
    gStageActive = true; // Keep stderr diagnostics even if file creation fails.
    pthread_mutex_unlock(&gStageLock);
    errno = savedErrno;
    return result;
}

void roothide_stage_log(const char *format, ...)
{
    int savedErrno = errno;
    pthread_mutex_lock(&gStageLock);
    if (gStageActive) {
        struct timespec now = {0};
        clock_gettime(CLOCK_REALTIME, &now);
        char message[2048];
        va_list args;
        va_start(args, format);
        vsnprintf(message, sizeof(message), format, args);
        va_end(args);
        if (gStageFD >= 0) {
            dprintf(gStageFD, "[RootHideStage %lld.%03ld pid=%d] %s\n",
                    (long long)now.tv_sec, now.tv_nsec / 1000000, getpid(), message);
        }
        dprintf(STDERR_FILENO, "[RootHideStage %lld.%03ld pid=%d] %s\n",
                (long long)now.tv_sec, now.tv_nsec / 1000000, getpid(), message);
    }
    pthread_mutex_unlock(&gStageLock);
    errno = savedErrno;
}

void roothide_stage_end(void)
{
    int savedErrno = errno;
    pthread_mutex_lock(&gStageLock);
    if (gStageFD >= 0) close(gStageFD);
    gStageFD = -1;
    gStageActive = false;
    pthread_mutex_unlock(&gStageLock);
    errno = savedErrno;
}
