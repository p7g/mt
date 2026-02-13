# mt - macOS terminal
# See LICENSE file for copyright and license details.
.POSIX:

include config.mk

SRC = st.c
OBJCSRC = mac.m
OBJ = st.o mac.o

all: mt.app

config.h:
	cp config.def.h config.h

st.o: st.c config.h st.h win.h
	$(CC) $(STCFLAGS) -c st.c

mac.o: mac.m arg.h config.h st.h win.h
	$(CC) $(MACFLAGS) -ObjC -c mac.m

$(OBJ): config.h config.mk

mt: $(OBJ)
	$(CC) -o $@ $(OBJ) $(STLDFLAGS)

mt.icns: mkicon.m
	$(CC) -framework Cocoa -framework CoreText -o mkicon mkicon.m
	./mkicon
	iconutil -c icns mt.iconset
	rm -rf mt.iconset mkicon

mt.app: mt Info.plist mt.icns
	mkdir -p mt.app/Contents/MacOS mt.app/Contents/Resources
	cp mt mt.app/Contents/MacOS/
	cp Info.plist mt.app/Contents/
	cp mt.icns mt.app/Contents/Resources/

clean:
	rm -f mt $(OBJ) mt.icns mt-$(VERSION).tar.gz
	rm -rf mt.app mt.iconset mkicon

dist: clean
	mkdir -p mt-$(VERSION)
	cp -R FAQ LEGACY TODO LICENSE Makefile README config.mk\
		config.def.h Info.plist mkicon.m st.info st.1 arg.h st.h win.h st.c mac.m\
		mt-$(VERSION)
	tar -cf - mt-$(VERSION) | gzip > mt-$(VERSION).tar.gz
	rm -rf mt-$(VERSION)

install: mt.app
	rm -rf $(HOME)/Applications/mt.app
	cp -R mt.app $(HOME)/Applications/
	tic -sx st.info
	@echo Installed mt.app to $(HOME)/Applications

uninstall:
	rm -rf $(HOME)/Applications/mt.app

.PHONY: all clean dist install uninstall
