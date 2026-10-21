#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright 2026 Corwin Brust and contributors. Expat (MIT) licence, matching the
# licence of Debian's php7.4 packaging (debian/* in Debian's debian/copyright)
# which this script extends. The patch in debian/patches/ is upstream's code
# and stays under the PHP License 3.01.
# build-srcpkg.sh -- produce a Debian source package of php7.4 carrying the
# PHP project's EOL mitigation for CVE-2026-109618 / CVE-2026-109619.
#
# Shape: Debian's own php7.4 7.4.33-1+deb11u5 (bullseye) orig tarball and
# packaging, plus ONE quilt patch (debian/patches/CVE-2026-109618-109619.patch,
# a DEP-3 export of php-src commit 712e60f9ed), versioned
#   7.4.33-1+deb11u5+isc2.1
# so it sorts after Debian's package and before any later Debian upload.
#
# usage: build-srcpkg.sh [outdir] [workdir]
#
# Environment:
#   MIRROR        base URL for the pool (default https://deb.debian.org/debian)
#   VERIFY_SIG    1 (default) = dscverify Debian's .dsc against debian-keyring;
#                 set 0 only where the keyring is unavailable; the checksums in
#                 the .dsc are still enforced either way.
#   BUILD_BINARY  1 = also run dpkg-buildpackage -b (needs build-deps; CI does
#                 this; default 0 = source package only)
#   DEBEMAIL/DEBFULLNAME  changelog author (defaults below)
#
# Output in $outdir: php7.4_7.4.33-1+deb11u5+isc2.1.dsc, .debian.tar.xz,
# php7.4_7.4.33.orig.tar.xz (Debian's, unchanged), SHA256SUMS, and with
# BUILD_BINARY=1 the .deb files and the .changes.
#
# POSIX sh; runs the same in docker, CI, and a bare bullseye host.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/out}
WORK=${2:-$PWD/work}
MIRROR=${MIRROR:-https://deb.debian.org/debian}
VERIFY_SIG=${VERIFY_SIG:-1}
BUILD_BINARY=${BUILD_BINARY:-0}
export DEBEMAIL=${DEBEMAIL:-mplscorwin@gmail.com}
export DEBFULLNAME=${DEBFULLNAME:-Corwin Brust}

SRC=php7.4
UV=7.4.33
DV=7.4.33-1+deb11u5
NV=${DV}+isc2.1
PATCH=CVE-2026-109618-109619.patch
POOL=$MIRROR/pool/main/p/$SRC

say() { printf '%s\n' "== $*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

say "source=$SRC debian=$DV new=$NV out=$OUT work=$WORK"
mkdir -p "$OUT" "$WORK"
cd "$WORK"

# --- 1. fetch Debian's source package, verify ------------------------------
# bullseye's LTS ended 2026-08-31; the pool is still on deb.debian.org at the
# time of writing but moves to archive.debian.org eventually, so try both.
fetch() {
    for m in "$MIRROR" https://archive.debian.org/debian; do
        curl -fsSL -o "$1" "$m/pool/main/p/$SRC/$1" && return 0
    done
    die "could not fetch $1 from $MIRROR or archive.debian.org"
}
for f in ${SRC}_${DV}.dsc ${SRC}_${DV}.debian.tar.xz ${SRC}_${UV}.orig.tar.xz ${SRC}_${UV}.orig.tar.xz.asc; do
    [ -s "$f" ] || { say "fetch $f"; fetch "$f"; }
done

# checksums: every file the .dsc lists must match its Checksums-Sha256 entry
awk '/^Checksums-Sha256:/{p=1;next} /^[A-Z]/{p=0} p&&NF==3{print $1"  "$3}' \
    "${SRC}_${DV}.dsc" > dsc.sha256
sha256sum -c dsc.sha256 || die "Debian .dsc checksums do not match"
say "dsc checksums OK"

if [ "$VERIFY_SIG" = 1 ]; then
    dscverify --no-default-keyrings \
        --keyring /usr/share/keyrings/debian-keyring.gpg \
        --keyring /usr/share/keyrings/debian-maintainers.gpg \
        "${SRC}_${DV}.dsc" || die "dscverify failed (set VERIFY_SIG=0 only without the keyring)"
    say "dsc signature OK (debian-keyring)"
else
    say "dsc signature NOT verified (VERIFY_SIG=0)"
fi

# --- 2. unpack, add the one patch, bump the changelog ----------------------
rm -rf "${SRC}-${UV}"
dpkg-source -x "${SRC}_${DV}.dsc" >/dev/null
cd "${SRC}-${UV}"

cp "$HERE/patches/$PATCH" debian/patches/
grep -qx "$PATCH" debian/patches/series || printf '%s\n' "$PATCH" >> debian/patches/series

# prove the patch applies on top of Debian's stack, then unapply (dpkg-source
# applies the series itself at build time)
QUILT_PATCHES=debian/patches quilt push -a >/dev/null || die "quilt push -a failed: patch does not apply"
say "patch applies on top of Debian's series"

# --- 2b. count the cards: with everything applied, every file our patch
# touches must equal upstream's file at the pinned commit, except the three
# files where Debian's own LTS backports also live (those are printed, not
# asserted). Needs git access to php-src; skipped (loudly) without it.
PIN=712e60f9edfd03f0960fc4fc3c2c375f42b90aa2
PHP_GIT=${PHP_GIT:-https://github.com/php/php-src}
if git -C "$WORK/php-src" rev-parse "$PIN^{commit}" >/dev/null 2>&1 \
   || { rm -rf "$WORK/php-src" && mkdir "$WORK/php-src" && git -C "$WORK/php-src" init -q \
        && git -C "$WORK/php-src" fetch -q --depth=1 "$PHP_GIT" "$PIN" 2>/dev/null; }; then
    bad=0
    for f in $(grep -E '^\+\+\+ ' "debian/patches/$PATCH" | sed 's/^+++ b\///'); do
        git -C "$WORK/php-src" show "$PIN:$f" > "$WORK/upstream.tmp"
        n=$(diff "$WORK/upstream.tmp" "$f" | grep -cE '^[<>]' || true)
        case $f in
            ext/session/session.c|main/rfc1867.c|main/php_variables.c)
                say "tree-check $f: $n lines differ (Debian's own backports; expected)";;
            *)  if [ "$n" != 0 ]; then say "tree-check $f: $n lines differ -- NOT expected"; bad=1; fi;;
        esac
    done
    [ "$bad" = 0 ] || die "patched tree differs from upstream $PIN outside the Debian-backport files"
    say "tree-check OK: patched files equal upstream at $PIN (minus Debian's own backports)"
else
    say "tree-check SKIPPED: php-src not reachable from here"
fi

QUILT_PATCHES=debian/patches quilt pop -a >/dev/null
rm -rf .pc

# Changelog entry written by hand, not by dch: dch wraps text differently
# across versions and stamps the wall clock, which made two witnesses produce
# different .dsc hashes for identical input. Fixed date = the date the CVE
# commit landed upstream. SOURCE_DATE_EPOCH clamps the tar mtimes, so the
# source package is byte-reproducible wherever it is built.
CL_DATE='Sun, 18 Oct 2026 18:09:54 +0000'
export SOURCE_DATE_EPOCH=1792346994   # == $CL_DATE (2026-10-18T18:09:54Z, the CVE commit's author date)
{
cat <<EOC
$SRC ($NV) bullseye; urgency=medium

  * Rebuild of Debian's $DV with the PHP project's EOL mitigation for
    CVE-2026-109618 (RCE via OOM corruption) and CVE-2026-109619 (RCE via
    stale global state): php-src commit 712e60f9ed from branch
    PHP-7.4-CVE-2026-109618-109619, as debian/patches/$PATCH.
    Not a Debian upload.
    https://github.com/inputloop/suit-crm-6-5-php-sec-backport

 -- $DEBFULLNAME <$DEBEMAIL>  $CL_DATE

EOC
cat debian/changelog
} > debian/changelog.new && mv debian/changelog.new debian/changelog
dpkg-parsechangelog -S Version | grep -qx "$NV" || die "changelog version mismatch"
find debian -newermt "@$SOURCE_DATE_EPOCH" -exec touch -d "@$SOURCE_DATE_EPOCH" {} +

# --- 3. source package -----------------------------------------------------
# dpkg-source -b (not dpkg-buildpackage -S): the tree was unpacked fresh and
# only debian/ changed, so there is nothing to clean, and running debian/rules
# clean would need the full build-dependency set (dh addons) for a source-only
# step. The binary path below does use the full tool chain.
cd ..
dpkg-source -b "${SRC}-${UV}" >/dev/null
say "source package built"

# --- 4. optional binary build ---------------------------------------------
if [ "$BUILD_BINARY" = 1 ]; then
    rm -rf bin && mkdir bin && cd bin
    dpkg-source -x "../${SRC}_${NV}.dsc" >/dev/null
    cd "${SRC}-${UV}"
    say "binary build (this takes a while)"
    dpkg-buildpackage -b -us -uc -j"${JOBS:-$(nproc 2>/dev/null || echo 4)}" >../build.log 2>&1 \
        || { tail -40 ../build.log; die "binary build failed; see $WORK/bin/build.log"; }
    cd ..
    cp ./*.deb ./*.changes "$OUT"/ 2>/dev/null || true
    cd ..
    say "binary build OK"
fi

# --- 5. deliver ------------------------------------------------------------
cp "${SRC}_${NV}.dsc" "${SRC}_${NV}.debian.tar.xz" \
   "${SRC}_${UV}.orig.tar.xz" "${SRC}_${UV}.orig.tar.xz.asc" "$OUT"/
cd "$OUT" && sha256sum ./* > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS
say "delivered to $OUT:"
cat SHA256SUMS
