# Build later on ARM Linux, or with its matching hard-float cross compiler.
CC ?= cc
APP := ../../../app/src
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Werror -fPIC -fno-fast-math
SOURCES := camera_bridge.c $(APP)/ai_camera_math.c $(APP)/ai_detector.c $(APP)/ai_display.c

all: libnpu_camera.so

libnpu_camera.so: $(SOURCES) $(wildcard $(APP)/*.h)
	$(CC) $(CPPFLAGS) $(CFLAGS) -I$(APP) -shared $(SOURCES) $(LDFLAGS) -o $@

syntax:
	$(CC) $(CPPFLAGS) $(CFLAGS) -I$(APP) -fsyntax-only $(SOURCES)

.PHONY: all syntax
