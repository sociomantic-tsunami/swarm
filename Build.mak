override DFLAGS += -w
override LDFLAGS += -lebtree -llzo2 -lrt -lgcrypt -lgpg-error -lglib-2.0

ifeq ($(DVER),1)
override DFLAGS += -v2 -v2=-static-arr-params -v2=-volatile
else
DC ?= dmd
endif

# Remove deprecated modules from testing:
TEST_FILTER_OUT += \
	$C/src/swarm/neo/node/helper/SuspendableRequest.d \
	$C/src/swarm/neo/client/helper/SuspendableRequest.d

.PHONY: d2conv
d2conv: $O/d2conv.stamp
