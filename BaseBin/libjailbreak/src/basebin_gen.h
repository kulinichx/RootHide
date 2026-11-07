#ifndef __BASEBIN_GEN_H
#define __BASEBIN_GEN_H

#import <Foundation/Foundation.h>
#include <stdbool.h>

int basebin_generate_internal(NSString *originUsrLibPath, NSString *basebinPath, NSString *targetBasebinPath, bool comingFromJBUpdate);
int basebin_generate(bool comingFromJBUpdate);

#endif
