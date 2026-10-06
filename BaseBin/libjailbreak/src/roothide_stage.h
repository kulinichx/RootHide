#ifndef ROOTHIDE_STAGE_H
#define ROOTHIDE_STAGE_H

#include <stdbool.h>

// Opt-in, process-local diagnostics. Call only from the App's activation path.
// The caller supplies a path in its private Documents directory.
int roothide_stage_begin(const char *path, bool append);
void roothide_stage_log(const char *format, ...) __attribute__((format(printf, 1, 2)));
void roothide_stage_end(void);

#endif
