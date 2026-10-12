CC      ?= gcc
CFLAGS  ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared -ldl

all: build/libkernelua_loader.so

build/libkernelua_loader.so: src/loader.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

check: all
	python3 -m py_compile src/backend.py
	node --check src/inject.js
	bash -n install.sh
	@echo "checks passed"

clean:
	rm -rf build

.PHONY: all check clean
