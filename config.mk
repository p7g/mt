# mt version
VERSION = 0.9.3

# paths
PREFIX = /usr/local
MANPREFIX = $(PREFIX)/share/man

# macOS frameworks
FRAMEWORKS = -framework Cocoa -framework CoreText -framework Carbon
LIBS = $(FRAMEWORKS) -lutil

# flags
STCPPFLAGS = -DVERSION=\"$(VERSION)\" -D_XOPEN_SOURCE=600
STCFLAGS = $(STCPPFLAGS) $(CPPFLAGS) -O2 $(CFLAGS)
MACFLAGS = -DVERSION=\"$(VERSION)\" $(CPPFLAGS) -O2 $(CFLAGS)
STLDFLAGS = $(LIBS) $(LDFLAGS)

# compiler and linker
CC = clang
