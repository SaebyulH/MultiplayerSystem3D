CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=c11 -D_GNU_SOURCE
LDFLAGS ?=

TARGET := lobbyd
SRC := lobbyd.c sha256.c
HDR := sha256.h

.PHONY: all clean smoke

all: $(TARGET)

$(TARGET): $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)

smoke: $(TARGET)
	bash smoke.sh
