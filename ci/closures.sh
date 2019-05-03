#!/bin/sh
set -xe

# Enables printing of all potential GC allocation sources to stdout
export DFLAGS=-vgc

# Ensure that there are no lines about closure allocations in the output
# Filters away errors from submodules to focus on swarm own code only
! beaver dlang make fasttest 2>&1 | grep "\./src/.*\<closure\>"
