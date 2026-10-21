#!/bin/sh
# setup-suitecrm.sh -- install SuiteCRM 7.13.x (SugarCRM CE 6.5 lineage) on a
# PHP built by ../php/build-php.sh, serve it with Apache mod_php, and prove it
# works: silent install, login page, authenticated login.
#
# usage: setup-suitecrm.sh <php-prefix> [suitecrm-tag] [docroot] [port]
#
# SuiteCRM's compatibility matrix (docs.suitecrm.com/admin/compatibility-matrix):
#   7.13.x -> PHP 7.4, 8.0      7.14.x -> PHP 8.1, 8.2      7.15.x -> PHP 8.1-8.4
# so pass v7.13.4 for the 7.4/8.0 builds and v7.14.9 for the 8.1 build.
# (7.13's installer has `$GLOBALS = ...`, a compile error on 8.1.)
#
# Run as root inside the build container (Debian/Ubuntu with apache2 and
# mariadb-server from ../php/deps.sh).  Writes $docroot/../SMOKE-RESULT.txt.
set -eu

PREFIX=${1:?php prefix}
TAG=${2:-v7.13.4}
DOCROOT=${3:-/var/www/suitecrm}
PORT=${4:-80}
PHP="$PREFIX/bin/php"
DBNAME=suitecrm DBUSER=suitecrm DBPASS=suitecrm
ADMIN_USER=admin ADMIN_PASS=admin
RESULT=$(dirname "$DOCROOT")/SMOKE-RESULT.txt

say() { printf '%s\n' "== $*"; }
rec() { printf '%s\n' "$*" | tee -a "$RESULT"; }
: > "$RESULT"

"$PHP" -v | head -1
rec "php: $("$PHP" -v | head -1)"
rec "php-src: $(sed -n 's/^php-src commit: //p' "$PREFIX/BUILD-INFO.txt")"

# --- 1. MariaDB -------------------------------------------------------------
if ! mysqladmin ping --silent 2>/dev/null; then
    (service mariadb start || service mysql start || (mysqld_safe >/dev/null 2>&1 &)) 2>/dev/null || true
    i=0; while ! mysqladmin ping --silent 2>/dev/null; do i=$((i+1)); [ $i -gt 60 ] && { say "mariadb did not start"; exit 2; }; sleep 1; done
fi
mysql -e "CREATE DATABASE IF NOT EXISTS $DBNAME CHARACTER SET utf8 COLLATE utf8_general_ci;
          CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
          CREATE USER IF NOT EXISTS '$DBUSER'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
          GRANT ALL ON $DBNAME.* TO '$DBUSER'@'localhost';
          GRANT ALL ON $DBNAME.* TO '$DBUSER'@'127.0.0.1'; FLUSH PRIVILEGES;"
rec "mariadb: $(mysql -N -e 'SELECT VERSION()')"
# a from-source php defaults its mysql socket to /tmp/mysql.sock; point it at
# the distro's, and have the installer use TCP anyway (host 127.0.0.1)
SOCK=$(mysql -N -e "SHOW VARIABLES LIKE 'socket'" | awk '{print $2}')
printf 'mysqli.default_socket=%s\npdo_mysql.default_socket=%s\n' "$SOCK" "$SOCK" > "$PREFIX/etc/conf.d/50-mysql-socket.ini"

# --- 2. SuiteCRM source + composer deps -----------------------------------
if [ ! -f "$DOCROOT/index.php" ]; then
    git clone -q --depth 1 --branch "$TAG" https://github.com/salesagility/SuiteCRM "$DOCROOT"
fi
cd "$DOCROOT"
rec "suitecrm: $TAG $(git rev-parse HEAD)"
if [ ! -f vendor/autoload.php ]; then
    if [ ! -f /usr/local/bin/composer ]; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        "$PHP" /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    fi
    COMPOSER_ALLOW_SUPERUSER=1 "$PHP" /usr/local/bin/composer install --no-dev --no-interaction --no-progress --prefer-dist 2>&1 | tail -3
fi
rec "composer: $("$PHP" /usr/local/bin/composer --version 2>/dev/null | head -1)"

# --- 3. Apache + mod_php from the prefix -----------------------------------
MOD="$PREFIX/lib/apache2/libphp.so"
[ -f "$MOD" ] || { say "no apache module at $MOD"; exit 2; }
# the module's registered name differs by version (php7_module vs php_module)
MODNAME=$(strings "$MOD" | grep -oE '^php[0-9]?_module$' | head -1)
[ -n "$MODNAME" ] || MODNAME=php_module
for m in php7 php8.1 php8.2 php8.3 php; do a2dismod -q "$m" 2>/dev/null || true; done
cat > /etc/apache2/mods-available/php-cve.load <<EOF
LoadModule $MODNAME $MOD
EOF
cat > /etc/apache2/mods-available/php-cve.conf <<'EOF'
<FilesMatch ".+\.ph(ar|p|tml)$">
    SetHandler application/x-httpd-php
</FilesMatch>
<FilesMatch ".+\.phps$">
    Require all denied
</FilesMatch>
DirectoryIndex index.php index.html
EOF
cat > /etc/apache2/sites-available/suitecrm.conf <<EOF
Listen $PORT
<VirtualHost *:$PORT>
    DocumentRoot $DOCROOT
    <Directory $DOCROOT>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/suitecrm-error.log
    CustomLog \${APACHE_LOG_DIR}/suitecrm-access.log combined
</VirtualHost>
EOF
# mod_php wants prefork
a2dismod -q mpm_event mpm_worker 2>/dev/null || true
a2enmod -q mpm_prefork rewrite php-cve >/dev/null
a2dissite -q 000-default 2>/dev/null || true
a2ensite -q suitecrm >/dev/null
sed -i 's/^Listen 80$/#Listen 80/' /etc/apache2/ports.conf
[ "$PORT" = 80 ] && sed -i 's/^#Listen 80$/Listen 80/' /etc/apache2/ports.conf && sed -i '/^Listen 80$/d' /etc/apache2/sites-available/suitecrm.conf
# the installer's recursive mkdir of cache/upload/import fails on a fresh
# checkout under mod_php (seen on both 7.4 and 8.1); pre-create what it wants
mkdir -p "$DOCROOT/cache/upload/import" "$DOCROOT/cache/images" "$DOCROOT/cache/modules" "$DOCROOT/cache/themes" "$DOCROOT/custom"
chown -R www-data:www-data "$DOCROOT"
apachectl configtest
(service apache2 restart || (apachectl -k stop; sleep 1; apachectl -k start)) 2>&1 | tail -1
sleep 2
rec "apache: $(apachectl -v | head -1) module=$MODNAME"

# prove it is OUR php behind apache, not a distro one
cat > "$DOCROOT/_whoami.php" <<'EOF'
<?php header('Content-Type: text/plain'); echo PHP_VERSION, "\n", PHP_BINARY, "\n", php_sapi_name(), "\n";
EOF
WHO=$(curl -s "http://127.0.0.1:$PORT/_whoami.php")
rec "mod_php reports: $(echo "$WHO" | tr '\n' ' ')"
echo "$WHO" | head -1 | grep -q "$("$PHP" -r 'echo PHP_VERSION;')" || { say "apache is not running the built php"; exit 2; }
rm -f "$DOCROOT/_whoami.php"

# --- 4. silent install ------------------------------------------------------
if [ ! -f "$DOCROOT/config.php" ] || ! grep -q "'installer_locked' => true" "$DOCROOT/config.php"; then
    cat > "$DOCROOT/config_si.php" <<EOF
<?php
\$sugar_config_si = array(
    'setup_db_host_name' => '127.0.0.1',
    'setup_db_database_name' => '$DBNAME',
    'setup_db_drop_tables' => 0,
    'setup_db_create_database' => 0,
    'setup_db_admin_user_name' => '$DBUSER',
    'setup_db_admin_password' => '$DBPASS',
    'setup_db_type' => 'mysql',
    'setup_db_create_sugarsales_user' => 0,
    'setup_db_sugarsales_user' => '$DBUSER',
    'setup_db_sugarsales_password' => '$DBPASS',
    'dbUSRData' => 'same',
    'default_currency_iso4217' => 'USD',
    'default_currency_name' => 'US Dollar',
    'default_currency_significant_digits' => '2',
    'default_currency_symbol' => '\$',
    'default_date_format' => 'Y-m-d',
    'default_time_format' => 'H:i',
    'default_decimal_seperator' => '.',
    'default_export_charset' => 'UTF-8',
    'default_language' => 'en_us',
    'default_locale_name_format' => 's f l',
    'default_number_grouping_seperator' => ',',
    'export_delimiter' => ',',
    'setup_site_url' => 'http://127.0.0.1:$PORT',
    'setup_site_admin_user_name' => '$ADMIN_USER',
    'setup_site_admin_password' => '$ADMIN_PASS',
    'setup_system_name' => 'SuiteCRM on patched PHP',
    'demoData' => 'no',
    'setup_site_sugarbeet_automatic_checks' => false,
);
EOF
    chown www-data:www-data "$DOCROOT/config_si.php"
    say "running silent install"
    curl -s -o /tmp/install.out -w '%{http_code}\n' "http://127.0.0.1:$PORT/install.php?goto=SilentInstall&cli=true"
    grep -iE 'error|fail|exception' /tmp/install.out | head -5 || true
    grep -q "'installer_locked' => true" "$DOCROOT/config.php" || { say "silent install did not lock the installer"; tail -20 "$DOCROOT/install.log" 2>/dev/null; exit 2; }
fi
rec "install: installer_locked=true in config.php"

# --- 5. smoke: login page, then authenticated login -------------------------
CJ=/tmp/suitecrm.cookies; rm -f $CJ
LOGIN=$(curl -s -c $CJ -b $CJ "http://127.0.0.1:$PORT/index.php?action=Login&module=Users")
echo "$LOGIN" | grep -q 'name="user_name"' && rec "login page: OK (user_name field present)" || { rec "login page: FAIL"; exit 2; }
HOME_CODE=$(curl -s -c $CJ -b $CJ -o /tmp/login.out -w '%{http_code}' \
    -d "module=Users&action=Authenticate&return_module=Users&return_action=Login&user_name=$ADMIN_USER&username_password=$ADMIN_PASS&Login=Log+In" \
    "http://127.0.0.1:$PORT/index.php")
HOMEPAGE=$(curl -s -c $CJ -b $CJ "http://127.0.0.1:$PORT/index.php?module=Home&action=index")
if echo "$HOMEPAGE" | grep -q 'name="user_name"'; then
    rec "login: FAIL (still on login form; auth code $HOME_CODE)"; exit 2
fi
echo "$HOMEPAGE" | grep -qiE 'module=Home|Dashboard|logout' && rec "login: OK (authenticated Home page served, auth HTTP $HOME_CODE)" || { rec "login: FAIL (unexpected page)"; exit 2; }
rec "apache error log tail:"
tail -5 /var/log/apache2/suitecrm-error.log | tee -a "$RESULT" || true
rec "RESULT: PASS $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "wrote $RESULT"
