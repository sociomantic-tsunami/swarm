override DFLAGS += -w -dip25
override LDFLAGS += -lebtree -llzo2 -lrt -lgcrypt -lgpg-error -lglib-2.0

DC ?= dmd
