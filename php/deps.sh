#!/bin/sh
# deps.sh -- build and runtime dependencies for build-php.sh and the SuiteCRM
# demo, on Debian/Ubuntu.  Run as root.  Idempotent.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    build-essential autoconf bison re2c pkg-config git curl ca-certificates \
    libxml2-dev libssl-dev libcurl4-openssl-dev libzip-dev libonig-dev \
    libsqlite3-dev libpng-dev libjpeg-dev libfreetype6-dev libicu-dev \
    libxslt1-dev zlib1g-dev libbz2-dev libsodium-dev \
    apache2 apache2-dev \
    mariadb-server mariadb-client unzip procps
