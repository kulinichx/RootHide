.PHONY: all clean build_clean

XCODEBUILD_SETTINGS = CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES='LaunchScreen.storyboard' INFOPLIST_KEY_UILaunchStoryboardName=LaunchScreen
DOPAMINE_VERSION ?= 3.0.7

all: Dopamine.ipa

Dopamine.ipa: build/Build/Products/Debug-iphoneos/Dopamine.app
	python3 ../.github/scripts/check_package_managers.py --app build/Build/Products/Debug-iphoneos/Dopamine.app
	@echo Ad-Hoc signing Dopamine
	xattr -rc build/Build/Products/Debug-iphoneos/Dopamine.app
	codesign --force --deep --sign - --timestamp=none build/Build/Products/Debug-iphoneos/Dopamine.app
	codesign --force --sign - --entitlements Dopamine/Dopamine.entitlements --timestamp=none build/Build/Products/Debug-iphoneos/Dopamine.app/Dopamine
	rm -rf Payload Dopamine.ipa
	mkdir Payload
	cp -r build/Build/Products/Debug-iphoneos/Dopamine.app Payload/Dopamine.app
	zip -Ar Dopamine.ipa Payload
	rm -rf Payload
	rm -rf Dopamine.tipa
	cp Dopamine.ipa Dopamine.tipa

ifeq ($(NIGHTLY), 1)
build/Build/Products/Debug-iphoneos/Dopamine.app: FORCE
	xcodebuild -project Dopamine.xcodeproj -target Dopamine -sdk iphoneos -configuration Debug CONFIGURATION_BUILD_DIR="$(CURDIR)/build/Build/Products/Debug-iphoneos" $(XCODEBUILD_SETTINGS) MARKETING_VERSION="$(DOPAMINE_VERSION)" GCC_PREPROCESSOR_DEFINITIONS='NIGHTLY=1 COMMIT_HASH=\"$(COMMIT_HASH)\"'
else
build/Build/Products/Debug-iphoneos/Dopamine.app: FORCE
	xcodebuild -project Dopamine.xcodeproj -target Dopamine -sdk iphoneos -configuration Debug CONFIGURATION_BUILD_DIR="$(CURDIR)/build/Build/Products/Debug-iphoneos" $(XCODEBUILD_SETTINGS) MARKETING_VERSION="$(DOPAMINE_VERSION)"
endif
	touch build/Build/Products/Debug-iphoneos/Dopamine.app/Dopamine.roothide
	mkdir -p build/Build/Products/Debug-iphoneos/Dopamine.app/Base.lproj
	cp -a Dopamine/Prebuilt/Base.lproj/LaunchScreen.storyboardc build/Build/Products/Debug-iphoneos/Dopamine.app/Base.lproj/
	@set -e; for package in Dopamine/Resources/*.deb; do \
		[ -f "$$package" ] || continue; \
		case "$${package##*/}" in zebra.deb) continue ;; esac; \
		cp -a "$$package" build/Build/Products/Debug-iphoneos/Dopamine.app/; \
	done
	# Remove resources left by an incremental build of an older revision.
	rm -f build/Build/Products/Debug-iphoneos/Dopamine.app/zebra.deb build/Build/Products/Debug-iphoneos/Dopamine.app/LICENSE_Zebra.md
	python3 ../.github/scripts/check_package_managers.py --app build/Build/Products/Debug-iphoneos/Dopamine.app
	for framework in ClearSword DarkSword Titan momentarius; do \
		rm -rf build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/$$framework.framework; \
		cp -a Dopamine/Prebuilt/Frameworks/$$framework.framework build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/; \
	done


clean:
	rm -rf build Payload Dopamine.ipa Dopamine.tipa

build_clean:
	rm -rf Payload build

FORCE: ;
