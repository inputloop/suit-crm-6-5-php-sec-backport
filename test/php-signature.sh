#!/bin/sh
# php-signature.sh -- confirm a built php carries the CVE-2026-109618/109619
# EOL-branch mitigation.  No exploit, no provoked fault: we only check that
# what the patch adds is present in the binary and its INI table.
#
# usage: php-signature.sh <php-prefix>
set -u
PREFIX=${1:?php prefix}
PHP="$PREFIX/bin/php"
fail=0
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }

# 1. new INI directive the patch backports (main/main.c)
v=$("$PHP" -n -r 'var_export(ini_get("max_multipart_body_parts"));')
case "$v" in "'-1'") ok "ini max_multipart_body_parts present (default -1)";; *) bad "ini max_multipart_body_parts: $v";; esac

# 2. strings the patch introduces (main/rfc1867.c, Zend/zend_alloc.c)
strings "$PHP" | grep -q 'Multipart body parts limit exceeded' && ok "rfc1867 limit message present" || bad "rfc1867 limit message missing"
if strings "$PHP" | grep -q 'zend_mm_safe_error_ex'; then ok "zend_mm_safe_error_ex present"; else echo "INFO  zend_mm_safe_error_ex not visible as a string (expected on some builds)"; fi

# 3. BUILD-INFO pins the commit
sed -n 's/^php-src commit: //p' "$PREFIX/BUILD-INFO.txt" | grep -qE '^[0-9a-f]{40}$' && ok "BUILD-INFO pins a commit" || bad "BUILD-INFO missing commit"

[ $fail = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $fail
