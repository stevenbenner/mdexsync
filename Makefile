SHELL = /bin/bash

ifeq (, $(shell which shellcheck))
$(error "Failed! Could not find shellcheck.")
endif

.PHONY: check
check:
	@shellcheck src/*.bash
