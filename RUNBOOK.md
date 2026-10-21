# RUNBOOK — building and proving by hand (LXD on a lab host)

This is what was run on gw19 on 2026-10-21. CI runs the identical scripts.

## One-time, on the host

```
sudo lxd init --auto
# gw19 ships with unprivileged user namespaces disabled (CVE-2026-46243
# mitigation); LXD containers need them. This is a hardening setting.
# LAB HOST ONLY: do not do this on a shared or production machine. On any such
# host run the same scripts in docker instead (the CI workflow is exactly that:
# `docker run --rm -v "$PWD":/w ubuntu:20.04 sh -c 'cd /w && sh php/deps.sh && ...'`,
# see .github/workflows/build.yml for the per-version base images).
# Re-enable only while containers run; it does not persist across reboot.
sudo sysctl -w user.max_user_namespaces=65536
```

## Containers

```
sudo lxc launch ubuntu:20.04      isc2-php74
sudo lxc launch images:debian/12  isc2-php81
sudo lxc file push -p php/*.sh suitecrm/*.sh test/*.sh isc2-php74/root/w/
sudo lxc file push -p php/*.sh suitecrm/*.sh test/*.sh isc2-php81/root/w/
```

## Build (inside each container, as root)

```
sh /root/w/deps.sh
JOBS=12 sh /root/w/build-php.sh PHP-7.4-CVE-2026-109618-109619 712e60f9edfd03f0960fc4fc3c2c375f42b90aa2
#          ...or PHP-8.1-CVE-2026-109618-109619 1d7dec178a094e6e75b229ce22754045f8c6070a
sh /root/w/php-signature.sh /opt/php-PHP-7.4-CVE-2026-109618-109619
sh /root/w/setup-suitecrm.sh  /opt/php-PHP-7.4-CVE-2026-109618-109619 v7.13.4 /var/www/suitecrm 80
cat /var/www/SMOKE-RESULT.txt
```

`lxc list` gives each container's address; SuiteCRM answers on it
(`admin` / `admin`, lab only).

## MANUAL RUN — what a person does, not CI

- **Tag a release**: `git tag v0.1.0 && git push --tags` on `main`; the
  `release` job attaches the artifacts of that run.
- **Re-pin after upstream moves**: if php-src force-pushes an EOL branch, the
  build refuses (`REFUSING: branch … is at …`). Read the new diff, then update
  the SHA in `.github/workflows/build.yml` and `README.md` together.
- **Tear down on gw19**: `sudo lxc delete -f isc2-php74 isc2-php81` and
  `sudo sysctl -w user.max_user_namespaces=0` to restore the hardening.
