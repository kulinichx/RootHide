#ifndef RC9_JETSAM_LIMIT_H
#define RC9_JETSAM_LIMIT_H

#include <limits.h>
#include <math.h>

// Keep RC9's existing multiplier semantics, but avoid undefined int overflow.
// Negative limits, including -1 (unlimited), must not be scaled.
static inline int rc9_jetsam_scaled_limit(int limit, double multiplier)
{
    if (limit <= 0) return limit;
    double scaled = (double)limit * multiplier;
    return scaled >= (double)INT_MAX ? INT_MAX : (int)scaled;
}

#endif // RC9_JETSAM_LIMIT_H
