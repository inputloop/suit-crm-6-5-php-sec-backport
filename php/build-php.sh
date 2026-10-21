#!/bin/sh
# build-php.sh -- build PHP from a pinned php-src commit, with the SAPIs and
# extensions SuiteCRM 7.x (SugarCRM CE 6.5 lineage) needs.
#
# usage: build-php.sh <branch> <expected-commit-sha> [prefix] [srcdir]
#
#   branch   php-src branch, e.g. PHP-7.4-CVE-2026-109618-109619
#   sha      full commit sha the branch head MUST equal (the build refuses otherwise)
#   prefix   install prefix (default /opt/php-<branch>)
#   srcdir   where to clone (default /usr/local/src/php-src-<branch>)
#
# Environment: JOBS (default nproc), APXS (default /usr/bin/apxs; empty to skip
# the apache2handler SAPI), PHP_GIT (default https://github.com/php/php-src).
#
# Output: $prefix/{bin,sbin,lib,etc}, plus $prefix/BUILD-INFO.txt and the
# apache module copied to $prefix/lib/apache2/libphp.so (apxs installs its
# copy into the system apache tree; we keep one with the prefix so the
# tarball is self-contained).
#
# POSIX sh; no bashisms, so it runs the same in LXD, docker, and CI.
set -eu

BRANCH=${1:?branch}
SHA=${2:?expected sha}
PREFIX=${3:-/opt/php-$BRANCH}
SRC=${4:-/usr/local/src/php-src-$BRANCH}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
APXS=${APXS-/usr/bin/apxs}
PHP_GIT=${PHP_GIT:-https://github.com/php/php-src}

say() { printf '%s\n' "== $*"; }

say "branch=$BRANCH sha=$SHA prefix=$PREFIX src=$SRC jobs=$JOBS"

# --- 1. source, pinned -----------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    git clone --branch "$BRANCH" --depth 1 "$PHP_GIT" "$SRC"
fi
cd "$SRC"
git fetch --depth 1 origin "$BRANCH"
git checkout -q --detach FETCH_HEAD
HEAD=$(git rev-parse HEAD)
if [ "$HEAD" != "$SHA" ]; then
    say "REFUSING: branch $BRANCH is at $HEAD, expected $SHA"
    exit 3
fi
say "source pinned at $HEAD"

# --- 2. configure ------------------------------------------------------------
./buildconf --force

set -- \
    --prefix="$PREFIX" \
    --with-config-file-path="$PREFIX/etc" \
    --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
    --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data \
    --with-openssl --with-zlib --with-bz2 --with-curl \
    --enable-mbstring --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
    --with-pdo-sqlite --with-sqlite3 \
    --enable-gd --with-jpeg --with-freetype \
    --with-zip --enable-soap --enable-intl --enable-bcmath --enable-sockets \
    --with-xsl --enable-exif --enable-opcache --with-sodium \
    --enable-calendar --enable-pcntl --with-gettext

if [ -n "$APXS" ] && [ -x "$APXS" ]; then
    set -- "$@" --with-apxs2="$APXS"
else
    say "no apxs: skipping apache2handler SAPI"
fi

./configure "$@" 2>&1 | tee "$SRC/configure.log" | tail -20

# --- 3. build + install -------------------------------------------------------
make -j"$JOBS" 2>&1 | tee "$SRC/make.log" | grep -E '^(Build complete|Don.t forget|/bin/sh|make|.*error)' | tail -5 || true
make install 2>&1 | tee "$SRC/install.log" | tail -5

# keep the apache module with the prefix, not only where apxs put it
if [ -n "$APXS" ] && [ -x "$APXS" ]; then
    LIBEXEC=$("$APXS" -q LIBEXECDIR)
    mkdir -p "$PREFIX/lib/apache2"
    for m in "$LIBEXEC"/libphp*.so; do
        [ -f "$m" ] && cp "$m" "$PREFIX/lib/apache2/" && cp "$m" "$PREFIX/lib/apache2/libphp.so"
    done
fi

# --- 4. php.ini: production, plus the two advisory-recommended settings ---
mkdir -p "$PREFIX/etc/conf.d"
cp php.ini-production "$PREFIX/etc/php.ini"
cat > "$PREFIX/etc/conf.d/90-cve-2026-109618-109619.ini" <<'EOF'
; From GHSA-6wmf-4rv5-p3rp / GHSA-w8hw-w9fx-j79w interim guidance.
; The patch is the mitigation; these reduce exposure further and SuiteCRM
; does not use either feature.
session.upload_progress.enabled = 0
; PHP >= 8.5 only; harmless as an unknown directive on older builds.
fatal_error_backtraces = 0
EOF
cp sapi/fpm/php-fpm.conf "$PREFIX/etc/php-fpm.conf" 2>/dev/null || true
[ -f "$PREFIX/etc/php-fpm.d/www.conf.default" ] && cp "$PREFIX/etc/php-fpm.d/www.conf.default" "$PREFIX/etc/php-fpm.d/www.conf" || true

# --- 5. record what was built ----------------------------------------------
{
    echo "php-src branch: $BRANCH"
    echo "php-src commit: $HEAD"
    echo "php-src remote: $PHP_GIT"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host: $(uname -srm)"
    echo "os: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    echo "cc: $(cc --version | head -1)"
    echo "configure: $*"
    echo "---- php -v"
    "$PREFIX/bin/php" -v
    echo "---- php -m"
    "$PREFIX/bin/php" -m
} > "$PREFIX/BUILD-INFO.txt"
cat "$PREFIX/BUILD-INFO.txt"
say "done: $PREFIX"
