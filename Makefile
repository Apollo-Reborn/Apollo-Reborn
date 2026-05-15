export ARCHS = arm64
export libFLEX_ARCHS = arm64

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Apollo
THEOS_LEAN_AND_MEAN = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ApolloImprovedCustomApi

SSZIPARCHIVE_FILES = $(wildcard ZipArchive/SSZipArchive/*.m) \
    $(wildcard ZipArchive/SSZipArchive/minizip/*.c) \
    $(wildcard ZipArchive/SSZipArchive/minizip/compat/*.c)

ApolloImprovedCustomApi_FILES = \
    Tweak.xm \
    ApolloCommon.m \
    ApolloRedditMediaUpload.m \
    ApolloUserProfileCache.m \
    ApolloUserAvatars.xm \
    ApolloImageUploadHost.xm \
    ApolloCreatedAtAlert.xm \
    ApolloState.m \
    ApolloShareLinks.xm \
    ApolloMedia.xm \
    ApolloCommentsCollapse.xm \
    ApolloLiquidGlass.xm \
    ApolloLiquidGlassIconPicker.xm \
    ApolloAutoHideTabBar.xm \
    ApolloSettings.xm \
    ApolloRecentlyRead.xm \
    ApolloSavedCategories.xm \
    ApolloTranslation.xm \
    ApolloVideoUnmute.xm \
    ApolloVideoSwipeFix.xm \
    ApolloTagFilters.xm \
    ApolloInlineImages.xm \
    CustomAPIViewController.m \
    TranslationSettingsViewController.m \
    SavedCategoriesViewController.m \
    TagFiltersViewController.m \
    Defaults.m \
    UIWindow+Apollo.m \
    fishhook.c \
    $(SSZIPARCHIVE_FILES)
ApolloImprovedCustomApi_FRAMEWORKS = UIKit Security AVFoundation OSLog NaturalLanguage ImageIO
ApolloImprovedCustomApi_LIBRARIES = z iconv
ApolloImprovedCustomApi_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-module-import-in-extern-c -Iliquid-glass/generated -IZipArchive/SSZipArchive -IZipArchive/SSZipArchive/minizip -DHAVE_ARC4RANDOM_BUF -DHAVE_ICONV -DHAVE_INTTYPES_H -DHAVE_PKCRYPT -DHAVE_STDINT_H -DHAVE_WZAES -DHAVE_ZLIB -DZLIB_COMPAT

ApolloImprovedCustomApi_OBJ_FILES = $(shell find ffmpeg-kit -name '*.a')

SUBPROJECTS += Tweaks/FLEXing/libflex

CONTROL_FILE = $(THEOS_PROJECT_DIR)/control

# Generate Version.h
before-all:: generate_version_h

generate_version_h:
	@echo "Generating Version.h from control file"
	@version=$$(grep '^Version:' $(CONTROL_FILE) | cut -d' ' -f2); \
	echo "#define TWEAK_VERSION \"v$${version}\"" > $(THEOS_PROJECT_DIR)/Version.h

# Liquid Glass icon preview header is generated explicitly by running 'make lg-previews'
LG_DIR = $(THEOS_PROJECT_DIR)/liquid-glass
LG_PREVIEW_HEADER = $(LG_DIR)/generated/LiquidGlassIconPreviews.gen.h

.PHONY: lg-previews
lg-previews:
	@echo "Regenerating $(notdir $(LG_PREVIEW_HEADER)) from liquid-glass/icons.json"
	@python3 $(LG_DIR)/scripts/generate_previews_header.py $(LG_PREVIEW_HEADER)

include $(THEOS_MAKE_PATH)/aggregate.mk
include $(THEOS_MAKE_PATH)/tweak.mk
