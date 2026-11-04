SHELL := /bin/sh
.DEFAULT_GOAL := help
PREFIX ?= /opt/npu100
DESTDIR ?=
CROSS_COMPILE ?= arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc
CFLAGS ?= -O3 -Wall -Wextra -std=c11
.PHONY: help app driver install install-service clean
help:
	@echo 'Targets: app (local C math bridge), driver, install, install-service'
	@echo 'No default build, hardware programming, service enable, or SD write.'
app:
	$(MAKE) -C app CC=$(CC)
driver:
	$(MAKE) -C driver
install:
	install -d $(DESTDIR)$(PREFIX)
	install -m 0755 npu_runtime.py pack_sd.py linux_camera.py preflight.py $(DESTDIR)$(PREFIX)/
	install -m 0644 manifest.py $(DESTDIR)$(PREFIX)/
	install -d $(DESTDIR)$(PREFIX)/app $(DESTDIR)/etc/npu100
	install -m 0755 app/libnpu_camera.so $(DESTDIR)$(PREFIX)/app/
	install -m 0644 camera.json $(DESTDIR)/etc/npu100/camera.json
install-service:
	install -d $(DESTDIR)/etc/systemd/system
	install -m 0644 systemd/unified-npu.service $(DESTDIR)/etc/systemd/system/
	install -m 0644 systemd/npu100-fpga-check.service $(DESTDIR)/etc/systemd/system/
clean:
	rm -f app/libnpu_camera.so

