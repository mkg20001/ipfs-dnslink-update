PREFIX    ?= /usr
BINDIR    ?= $(PREFIX)/bin

all:

install:
	install -m 755 -g root -o root ipfs-dnslink-update.sh $(BINDIR)/ipfs-dnslink-update
