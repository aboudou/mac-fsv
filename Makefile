# mac-fsv - macOS port of fsv (3D File System Visualizer)
#
# Requires only the Xcode command line tools (clang, iconutil, codesign).
#
#   make            build build/mac-fsv.app
#   make run        build and launch
#   make clean

APP      := build/mac-fsv.app
BIN      := $(APP)/Contents/MacOS/mac-fsv
OBJDIR   := build/obj

ARCHS    ?= -arch arm64 -arch x86_64
MINVER   := -mmacosx-version-min=14.0
CC       := clang

CPPFLAGS := -Isrc/compat -Isrc/core
WARN     := -Wall -Wno-self-assign -Wno-unused-function -Wno-unused-variable
CFLAGS   := -O2 -g $(WARN) $(ARCHS) $(MINVER)
OBJCFLAGS := $(CFLAGS) -fobjc-arc
LDFLAGS  := $(ARCHS) $(MINVER) -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore

CORE_SRC := about animation camera colexp color common fsv geometry nvstore ogl scanfs tmaptext viewport
COMPAT_C := glib minigl
COMPAT_M := minigl_metal
MAC_SRC  := FSVApp FSVMainWindow FSVViewport FSVDialogs FSVColorSetup FSVXPM

OBJS := $(CORE_SRC:%=$(OBJDIR)/core/%.o) \
        $(COMPAT_C:%=$(OBJDIR)/compat/%.o) \
        $(COMPAT_M:%=$(OBJDIR)/compat/%.o) \
        $(MAC_SRC:%=$(OBJDIR)/mac/%.o)

HEADERS := $(wildcard src/core/*.h src/compat/*.h src/compat/GL/*.h src/mac/*.h)

DOCS := $(wildcard resources/doc/*)

.PHONY: all run clean

all: $(APP)

$(OBJDIR)/core/%.o: src/core/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(OBJDIR)/compat/%.o: src/compat/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(OBJDIR)/compat/%.o: src/compat/%.m $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) -c $< -o $@

$(OBJDIR)/mac/%.o: src/mac/%.m $(HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(OBJCFLAGS) -c $< -o $@

$(BIN): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) $(OBJS) -o $@

# Application icon, generated from fsv's original XPM icon
build/mkicon: tools/mkicon.m src/mac/FSVXPM.m $(HEADERS)
	@mkdir -p build
	$(CC) $(CPPFLAGS) -O2 -fobjc-arc $(MINVER) tools/mkicon.m src/mac/FSVXPM.m -framework Cocoa -o $@

build/AppIcon.icns: build/mkicon
	rm -rf build/AppIcon.iconset
	build/mkicon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

$(APP): $(BIN) resources/Info.plist build/AppIcon.icns $(DOCS)
	@mkdir -p $(APP)/Contents/Resources/doc
	cp resources/Info.plist $(APP)/Contents/Info.plist
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(DOCS) $(APP)/Contents/Resources/doc/
	cp resources/COPYING resources/AUTHORS $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)
	@touch $(APP)

run: $(APP)
	open $(APP)

clean:
	rm -rf build
