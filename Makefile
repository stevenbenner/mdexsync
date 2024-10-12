NAME := mdexsync
PREFIX ?= /usr/local
SHELL = /bin/bash

ifeq (, $(shell which shellcheck))
$(error "Failed! Could not find shellcheck.")
endif

.PHONY: check
check:
	@shellcheck src/*.bash

.PHONY: install
install:
	install -dm755 '$(DESTDIR)$(PREFIX)/bin'
	install -m755 'src/$(NAME).bash' '$(DESTDIR)$(PREFIX)/bin/$(NAME)'

.PHONY: uninstall
uninstall:
	rm --force '$(DESTDIR)$(PREFIX)/bin/$(NAME)'
