# mt - macOS terminal
# See LICENSE file for copyright and license details.
.POSIX:

include config.mk

SRC = st.c
OBJCSRC = mac.m
OBJ = st.o mac.o

all: mt

config.h:
	cp config.def.h config.h

st.o: st.c config.h st.h win.h
	$(CC) $(STCFLAGS) -c st.c

mac.o: mac.m arg.h config.h st.h win.h
	$(CC) $(MACFLAGS) -ObjC -c mac.m

$(OBJ): config.h config.mk

mt: $(OBJ)
	$(CC) -o $@ $(OBJ) $(STLDFLAGS)

clean:
	rm -f mt $(OBJ) mt-$(VERSION).tar.gz

dist: clean
	mkdir -p mt-$(VERSION)
	cp -R FAQ LEGACY TODO LICENSE Makefile README config.mk\
		config.def.h st.info st.1 arg.h st.h win.h st.c mac.m\
		mt-$(VERSION)
	tar -cf - mt-$(VERSION) | gzip > mt-$(VERSION).tar.gz
	rm -rf mt-$(VERSION)

install: mt
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp -f mt $(DESTDIR)$(PREFIX)/bin
	chmod 755 $(DESTDIR)$(PREFIX)/bin/mt
	tic -sx st.info
	@echo Please see the README file regarding the terminfo entry of st.

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/mt

.PHONY: all clean dist install uninstall
