#!/bin/sh
set -xe

# Install dependencies
apt-get install -y \
    liblzo2-dev \
    libebtree6-dev \
    libgcrypt-dev \
    libglib2.0-dev \
    libgpg-error-dev
