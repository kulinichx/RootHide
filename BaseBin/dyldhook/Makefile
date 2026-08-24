CC = clang

CFLAGS = -I../.include -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -Wno-deprecated-declarations -fno-stack-check -D_FORTIFY_SOURCE=0 -O2
CFLAGS += -nostdlib -L. -lSystem # using a empty libSystem to check undefined symbols at build time
CFLAGS_IOS15 = $(CFLAGS) -miphoneos-version-min=15.0
CFLAGS_IOS16 = $(CFLAGS) -miphoneos-version-min=16.0
LDFLAGS = -shared -Xlinker -add_split_seg_info
FILES = $(wildcard src/*.c src/*.S ../libjailbreak/src/jbclient_mach.c)
FILES_IOS15 = $(wildcard src/generated/ios15/*.c)
FILES_IOS16 = $(wildcard src/generated/ios16/*.c)

all: dyldhook_merge.arm64e.dylib dyldhook_merge.arm64.dylib

dyldhook_merge.arm64e.dylib: $(FILES) $(FILES_IOS16)
	$(CC) -arch arm64e $(CFLAGS_IOS16) -DIOS=16 $(LDFLAGS) -o $@ $^
	@ldid -S $@

dyldhook_merge.arm64e.iOS15.dylib: $(FILES) $(FILES_IOS15)
	$(CC) -arch arm64e $(CFLAGS_IOS15) -DIOS=15 $(LDFLAGS) -o $@ $^
	@ldid -S $@

dyldhook_merge.arm64.dylib: $(FILES) $(FILES_IOS16)
	$(CC) -arch arm64 $(CFLAGS_IOS16) -DIOS=16 $(LDFLAGS) -o $@ $^
	@ldid -S $@

dyldhook_merge.arm64.iOS15.dylib: $(FILES) $(FILES_IOS15)
	$(CC) -arch arm64 $(CFLAGS_IOS15) -DIOS=15 $(LDFLAGS) -o $@ $^
	@ldid -S $@

clean:
	@rm -f dyldhook_merge.arm64e.dylib
	@rm -f dyldhook_merge.arm64e.iOS15.dylib
	@rm -f dyldhook_merge.arm64.dylib
	@rm -f dyldhook_merge.arm64.iOS15.dylib
