# Patched PHP 7.4 / 8.0 / 8.1 for SuiteCRM (SugarCRM CE 6.5 lineage) — CVE-2026-109618, CVE-2026-109619

This repository builds PHP from the **end-of-life mitigation branches the PHP
project published on 2026-10-18/21** for two critical (CVSS 9.2) issues, proves
that SuiteCRM 7.13 installs and logs in on each build, and publishes the
binaries **together with the complete sources** they were built from.

It is a build-and-prove apparatus. It contains no exploit and no vulnerable
code of its own; the patches are the PHP project's, unchanged.

## What the two advisories say (in one paragraph each)

- **CVE-2026-109618 — "RCE via OOM corruption"**
  ([GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)).
  PHP handled out-of-memory by `longjmp()`-ing out of the request. If that
  happened while request state was only partly initialised, shutdown could
  walk invalid memory. Confirmed exploitable against Apache `mod_php`;
  PHP-FPM is believed susceptible from source analysis. Fixed in 8.2.35,
  8.3.36, 8.4.27, 8.5.12.
- **CVE-2026-109619 — "RCE via stale global state"**
  ([GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)).
  Fatal errors (including OOM and execution-time limits) could leave global
  state pointing at a previous request's heap; a later request could use it
  before normal initialisation. Same fixed versions.

Both advisories say updating is the only complete mitigation and give interim
settings; the one that applies to SuiteCRM deployments is
`session.upload_progress.enabled = 0`, which the build's `php.ini` sets.

## What the EOL branches contain

The PHP project published one commit per EOL branch, "Avoid state corruption
via bailout — Minimal mitigation for EOL version", by Arnaud Le Blanc,
co-authored by Ilija Tovilo. This repository pins those commits by full SHA
and the build refuses to proceed if the branch head moves:

| PHP | php-src branch | commit |
|-----|----------------|--------|
| 7.4 | `PHP-7.4-CVE-2026-109618-109619` | `712e60f9edfd03f0960fc4fc3c2c375f42b90aa2` |
| 8.0 | `PHP-8.0-CVE-2026-109618-109619` | `82f8f31b16a035c1b67cc253e79f7cc288f4cc20` |
| 8.1 | `PHP-8.1-CVE-2026-109618-109619` | `1d7dec178a094e6e75b229ce22754045f8c6070a` |

Read the diff yourself: `git show <commit>` in a php-src checkout. In plain
terms, the 7.4/8.0 commit (17 files):

- memory-exhaustion and allocation-overflow errors no longer unwind through
  `zend_bailout()`; they print the fatal error to stderr and `_exit(1)` the
  worker (`Zend/zend_alloc.c`: new `zend_mm_safe_error_ex`);
- executor/SAPI globals that could be read before request startup are reset
  at shutdown (`Zend/zend_execute_API.c`, `main/SAPI.c`, `main/main.c`);
- multipart parsing keeps only the headers it uses, bounds the number of body
  parts (new INI `max_multipart_body_parts`, default = `max_input_vars` +
  `max_file_uploads`), and sizes small arrays exactly (`main/rfc1867.c`,
  `main/php_variables.c`, `Zend/zend_hash.c`);
- session upload-progress tracking is **disabled unconditionally**
  (`ext/session/session.c`).

The 8.1 commit (23 files) does the same in the 8.1 code and also resets
opcache state that can outlive a request (`ext/opcache/*`).

These are "minimal mitigations", the PHP project's words. They are not the
full fix that 8.2+ received (delayed soft-OOM at a VM safe point). A worker
that hits OOM on a patched EOL build now dies with exit status 1 instead of
being reused; with Apache prefork or PHP-FPM that is a respawn, not an outage.

## What this repository does

```
php/deps.sh              build + runtime packages (Debian/Ubuntu)
php/build-php.sh         clone php-src at the pinned SHA, configure, build, install
                         SAPIs: cli, cgi, fpm, apache2handler
                         extensions SuiteCRM 7 needs: mysqli/pdo_mysql, gd, zip, curl,
                         mbstring, xml/xsl, soap, intl, openssl, opcache, bcmath, sodium…
test/php-signature.sh    confirms the mitigation is in the built binary (no exploit)
suitecrm/setup-suitecrm.sh
                         MariaDB + Apache mod_php from the build + SuiteCRM
                         (v7.13.4 on PHP 7.4/8.0, v7.14.9 on PHP 8.1, per SuiteCRM's
                         compatibility matrix) silent install, then proves the login
                         page and an authenticated login over HTTP; writes SMOKE-RESULT.txt
.github/workflows/build.yml
                         the same scripts, in a matrix, on GitHub Actions
```

The same three shell scripts are what the CI runs and what was run by hand
in LXD containers on a lab host (see `RUNBOOK.md`), so there are two
independent witnesses to each build.

### Artifacts every CI run publishes

- `php-<ver>-cve-2026-109618-109619-<sha12>-linux-x86_64.tar.gz` — the
  installed tree (`/opt/php-<branch>`): `bin/php`, `bin/php-cgi`,
  `sbin/php-fpm`, `lib/apache2/libphp.so`, `etc/php.ini`, `BUILD-INFO.txt`
- `php-src-<branch>-<sha12>.tar.gz` — **the complete PHP source at that
  commit** (`git archive`), so anyone can rebuild without trusting us
- `build-apparatus-<rev>.tar.gz` — this repository at the revision that built
- `BUILD-INFO-<ver>.txt`, `configure-<ver>.log`, `signature-<ver>.txt`,
  `smoke-<ver>.txt`, `SHA256SUMS-<ver>.txt`

A `v*` tag turns the same set into a GitHub Release.

### Where the binaries were built

| PHP | CI image | lab container (gw19, LXD) | SuiteCRM proven |
|-----|----------|---------------------------|-----------------|
| 7.4 | `ubuntu:20.04` | `ubuntu:20.04` (PASS 2026-10-21T18:14Z) | v7.13.4 |
| 8.0 | `ubuntu:20.04` | — (CI only) | v7.13.4 |
| 8.1 | `debian:bookworm` | `images:debian/12` (PASS 2026-10-21T18:12Z) | v7.14.9 |

7.4 is built on an OpenSSL 1.1 / libxml2 2.9 base because that is what the
7.4 series was developed against; newer bases need source changes unrelated
to these CVEs.

## Using a build

```
tar -C /opt -xzf php-7.4-cve-2026-109618-109619-712e60f9edfd-linux-x86_64.tar.gz
/opt/php-PHP-7.4-CVE-2026-109618-109619/bin/php -v
```

Apache: `LoadModule php7_module /opt/php-.../lib/apache2/libphp.so` (8.x:
`php_module`), prefork MPM. FPM: `sbin/php-fpm -y etc/php-fpm.conf`.
`suitecrm/setup-suitecrm.sh` is a worked example of both the Apache wiring
and a SuiteCRM install.

The build needs the shared libraries from the OS it was built on (see the
table above). Rebuilding on your own base is the supported path: that is
why the full sources ship with every artifact.

## Status and bounds, stated plainly

- Done: PHP 7.4 and 8.1 built from the pinned commits in LXD on a lab host;
  SuiteCRM 7.13.4 (on 7.4) and 7.14.9 (on 8.1) installed by the script;
  login proven over HTTP through Apache mod_php; the same scripts run in CI
  (plus 8.0) with artifacts and sources attached.
- Not done: `make test` of php-src against these builds (the EOL branches
  carry no test changes; running the suite is cheap to add and is the next
  step); PHP-FPM is built but only mod_php was smoke-tested; no exploit was
  run against patched or unpatched builds — the proof here is "the pinned
  patch is in the binary and the application works on it", not "the exploit
  fails".
- "SuiteCRM 6.5": SuiteCRM's 7.x line is the continuation of SugarCRM CE
  6.5. No single 7.x release spans PHP 7.4 and 8.1 — SuiteCRM's
  [compatibility matrix](https://docs.suitecrm.com/admin/compatibility-matrix/)
  gives 7.13.x → PHP 7.4/8.0 and 7.14.x → PHP 8.1/8.2 (7.13's installer
  has a `$GLOBALS = …` assignment that is a compile error on 8.1; we hit it).
  So the demonstrator is 7.13.4 on the 7.4/8.0 builds and 7.14.9 on 8.1.
  A literal SugarCRM CE 6.5.x install is not covered here.

## Credits

- Vulnerability reporters (per the advisories): lcfr-hax, sagitzadik-wiz,
  tomash-areion, amyb-oai.
- Remediation (PHP project): Arnaud Le Blanc (arnaud-lb), Ilija Tovilo
  (iluuu1994), Jakub Zelenka (bukka), Niels Dossche (ndossche).
- SuiteCRM: SalesAgility and contributors; SugarCRM CE 6.5 lineage.
- This apparatus: Corwin Brust and Claude (Mythos 5.1), inputloop, 2026-10-21.

## Sources

- https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w
- https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp
- https://github.com/php/php-src/tree/PHP-7.4-CVE-2026-109618-109619
- https://github.com/php/php-src/tree/PHP-8.0-CVE-2026-109618-109619
- https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619
- https://github.com/salesagility/SuiteCRM/tree/v7.13.4

## License

The scripts and documents in this repository: GNU General Public License,
version 3 or any later version (SPDX `GPL-3.0-or-later`). PHP is under the
PHP License 3.01; SuiteCRM under AGPL-3.0. Shipped sources carry their own
licenses unchanged.
