TARGET = glassrenderhook.dylib
CXX = clang++
SDKROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)

CXXFLAGS = -I../.include -isysroot $(SDKROOT) -arch arm64 -arch arm64e -miphoneos-version-min=16.0 -std=c++17 -fobjc-arc -fblocks -Os -moutline -Wno-deprecated-declarations
LDFLAGS = -dynamiclib -install_name @loader_path/$(TARGET) -rpath @loader_path/fallback -L../_external/lib -lellekit -framework Foundation -framework QuartzCore -framework Metal

sign: $(TARGET)
	@ldid -S $^

$(TARGET): src/main.mm
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^

clean:
	@rm -f $(TARGET)
