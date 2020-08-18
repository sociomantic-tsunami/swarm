override DFLAGS += -w
override LDFLAGS += -lebtree -llzo2 -lrt -lgcrypt -lgpg-error -lglib-2.0

DC ?= dmd

# Remove deprecated modules from testing:
TEST_FILTER_OUT += \
	$C/src/swarm/util/Verify.d
