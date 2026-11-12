# pmon - NSP midterm
#
#   make            normal build  -> build/
#   make DEBUG=1    debug build   -> build-debug/  (LOG_DEBUG compiled in, -g)
#   make deploy     copy the client and the shared library to the client VMs
#   make dist       pack the committed source into pmon-source.zip
#   make clean      remove both build directories
#
# The two builds live in separate directories so they can be compared.

CC     := gcc
CFLAGS := -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Iinclude

ifeq ($(DEBUG),1)
BUILD  := build-debug
CFLAGS += -DPMON_DEBUG -g -O0
else
BUILD  := build
CFLAGS += -O2
endif

# Hosts that "make deploy" copies the client to.
CLIENTS ?= nsp-client-1 nsp-client-2

LIB    := $(BUILD)/lib/libpmon.so
SERVER := $(BUILD)/bin/pmond
CLIENT := $(BUILD)/bin/pmon

LIB_OBJ    := $(patsubst %.c,$(BUILD)/obj/%.o,$(wildcard lib/*.c))
SERVER_OBJ := $(patsubst %.c,$(BUILD)/obj/%.o,$(wildcard server/*.c))
CLIENT_OBJ := $(patsubst %.c,$(BUILD)/obj/%.o,$(wildcard client/*.c))

# Both programs link against the shared library. The rpath makes each
# program look for it in ../lib relative to its own location, so it runs
# without LD_LIBRARY_PATH wherever bin/ and lib/ are copied together.
LDLIBS := -L$(BUILD)/lib -lpmon -Wl,-rpath,'$$ORIGIN/../lib'

.PHONY: all deploy dist clean
all: $(LIB) $(SERVER) $(CLIENT)

# Library objects must be position-independent to go into a shared object.
$(BUILD)/obj/lib/%.o: lib/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -fPIC -MMD -MP -c $< -o $@

$(BUILD)/obj/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(LIB): $(LIB_OBJ)
	@mkdir -p $(@D)
	$(CC) -shared -o $@ $^

$(SERVER): $(SERVER_OBJ) $(LIB)
	@mkdir -p $(@D)
	$(CC) -o $@ $(SERVER_OBJ) $(LDLIBS)

$(CLIENT): $(CLIENT_OBJ) $(LIB)
	@mkdir -p $(@D)
	$(CC) -o $@ $(CLIENT_OBJ) $(LDLIBS)

# The client VMs have no compiler: they receive the client program together
# with the very same libpmon.so the server uses.
deploy: all
	@for h in $(CLIENTS); do \
		ssh $$h 'mkdir -p pmon/bin pmon/lib' && \
		scp -q $(CLIENT) $$h:pmon/bin/ && \
		scp -q $(LIB) $$h:pmon/lib/ && \
		echo "deployed $(BUILD) to $$h:~/pmon" || exit 1; \
	done

# The archive handed in with the report. It is made from the last commit,
# so it holds exactly what is in version control and no build output.
dist:
	git archive --format=zip --prefix=pmon/ -o pmon-source.zip HEAD
	@echo "wrote pmon-source.zip ($$(git rev-parse --short HEAD))"

clean:
	rm -rf build build-debug pmon-source.zip

-include $(LIB_OBJ:.o=.d) $(SERVER_OBJ:.o=.d) $(CLIENT_OBJ:.o=.d)
