NAME := mdexsync
PREFIX ?= /usr/local
SHELL = /bin/bash

.PHONY: check
check:
	@if ! command -v shellcheck &> /dev/null; then echo "Failed! Could not find shellcheck."; exit 1; fi
	@shellcheck src/*.bash

.PHONY: install
install:
	install -dm755 '$(DESTDIR)$(PREFIX)/bin'
	install -m755 'src/$(NAME).bash' '$(DESTDIR)$(PREFIX)/bin/$(NAME)'

.PHONY: uninstall
uninstall:
	rm --force '$(DESTDIR)$(PREFIX)/bin/$(NAME)'
