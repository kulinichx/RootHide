
#include <stdbool.h>

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/jbclient_xpc.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/codesign.h>

bool isJailbreakBundlePath(const char* path);

#ifdef __OBJC__
// Official RootHide coordinate conversion; nil means the runtime API is absent.
NSString* rcRootfsPath(NSString* path);
NSString* rcJbrootPath(NSString* path);
#endif
