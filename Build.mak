override DFLAGS += -w
override LDFLAGS += -lebtree -llzo2 -lrt -lgcrypt -lgpg-error -lglib-2.0

DC ?= dmd
