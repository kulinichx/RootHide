#ifndef RC9_JETSAM_LIMIT_H
#define RC9_JETSAM_LIMIT_H

#include <limits.h>
#include <math.h>

// This function is implemented once per dylib by systemhook/src/_zqbb.c.
// Both launchdhook and systemhook include that compilation unit in RC9.
int zqbb_getJetsamAddend(const char *path);

// ZQBB: configured per-process addend (default 10) + round(multiplier * 10).
// Apply only for finite multipliers > 1; saturate before casting to int.
static inline int rc9_zqbb_jetsam_addend(int configured, double multiplier)
{
    if (configured <= 0) configured = 10;
    if (!isfinite(multiplier) || multiplier <= 1) return 0;
    double extra = round(multiplier * 10.0);
    if (!isfinite(extra) || extra >= (double)(INT_MAX - configured)) return INT_MAX;
    return configured + (int)extra;
}

// Preserve unlimited (-1) and unexpected negative limits; ZQBB caps positives.
static inline int rc9_zqbb_jetsam_limit(int limit, int addend)
{
    if (limit < 0 || addend <= 0) return limit;
    if (limit >= INT_MAX - addend) return INT_MAX;
    return limit + addend;
}

#endif // RC9_JETSAM_LIMIT_H
