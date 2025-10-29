#!/usr/bin/env bash
set -euo pipefail

# === CURSOR AGENT FAST INSTALL (StackFood v10) ===
# Domain: hayyaeats.com
# Subdomains: api.hayyaeats.com, admin.hayyaeats.com, restaurant.hayyaeats.com
# Timezone: America/Toronto
# NOTE: Credentials are weak for speed. Complete install first, harden later.
# Zip sources (as provided): /var/www/hayyaeats/*.zip

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

log() { echo -e "\n==> $1"; }
retry() { local n=0; until "$@"; do n=$((n+1)); if [[ $n -ge 3 ]]; then return 1; fi; sleep 2; done }

# ---------------------------------------------------------------------
# 1) SERVER PREP
# ---------------------------------------------------------------------
log "Updating system and installing base packages..."
retry apt update
retry apt -y upgrade
retry timedatectl set-timezone America/Toronto
retry apt -y install nginx mysql-server redis-server software-properties-common unzip git curl htop fail2ban

log "Installing PHP 8.2..."
add-apt-repository ppa:ondrej/php -y
retry apt update
retry apt -y install php8.2 php8.2-fpm php8.2-cli php8.2-common php8.2-bcmath php8.2-curl php8.2-intl php8.2-mbstring php8.2-mysql php8.2-xml php8.2-zip php8.2-gd php8.2-readline

log "Installing Composer..."
cd /usr/local/bin && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

log "Installing Node.js 18 and pnpm..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
retry apt -y install nodejs
npm i -g pnpm

log "Creating deploy user and preparing /var/www..."
if ! id deploy &>/dev/null; then
  adduser deploy --disabled-password --gecos ""
fi
usermod -aG sudo,www-data deploy
mkdir -p /var/www && chown -R deploy:www-data /var/www

log "Configuring UFW..."
ufw allow OpenSSH || true
ufw allow 'Nginx Full' || true
ufw --force enable || true

# ---------------------------------------------------------------------
# 2) DATABASE (weak creds for speed)
# ---------------------------------------------------------------------
log "Configuring MySQL users and database..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'HayyaRoot123!'; FLUSH PRIVILEGES;" || true
mysql -uroot -pHayyaRoot123! -e "CREATE DATABASE IF NOT EXISTS stackfood DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -uroot -pHayyaRoot123! -e "CREATE USER IF NOT EXISTS 'stackfood'@'localhost' IDENTIFIED BY 'HayyaDb123!';"
mysql -uroot -pHayyaRoot123! -e "GRANT ALL PRIVILEGES ON stackfood.* TO 'stackfood'@'localhost'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------------------
# 3) BACKEND DEPLOY
# ---------------------------------------------------------------------
log "Preparing backend directory..."
su -s /bin/bash -c "mkdir -p /var/www/stackfood" deploy
cd /var/www/stackfood

BACKEND_STAGE=/var/www/hayyaeats/extracted-main
rm -rf "$BACKEND_STAGE"
mkdir -p "$BACKEND_STAGE"

# Detect main StackFood package zip (prefer the one with laravel admin in name)
MAIN_ZIP="$(ls -1 /var/www/hayyaeats/*laravel-admin* 2>/dev/null | head -n1)"
if [[ -z "${MAIN_ZIP}" ]]; then
  MAIN_ZIP="$(ls -S /var/www/hayyaeats/*.zip 2>/dev/null | head -n1)"
fi
if [[ -z "${MAIN_ZIP}" || ! -f "${MAIN_ZIP}" ]]; then
  echo "Missing StackFood main zip under /var/www/hayyaeats. Place the large codecanyon zip there and rerun." >&2
  exit 1
fi

log "Unzipping main package: ${MAIN_ZIP} ..."
unzip -o "${MAIN_ZIP}" -d "$BACKEND_STAGE" >/dev/null

# Find Laravel backend source (directory containing artisan)
BACKEND_SRC="$(dirname "$(find "$BACKEND_STAGE" -maxdepth 5 -type f -name artisan 2>/dev/null | head -n1)")"
if [[ -z "${BACKEND_SRC}" || ! -f "${BACKEND_SRC}/artisan" ]]; then
  echo "Could not detect Laravel backend inside ${MAIN_ZIP}. Please check package structure." >&2
  exit 1
fi

log "Syncing backend to /var/www/stackfood/release ..."
mkdir -p /var/www/stackfood/release
shopt -s dotglob
rm -rf /var/www/stackfood/release/*
cp -a "${BACKEND_SRC}/"* /var/www/stackfood/release/
shopt -u dotglob
cd /var/www/stackfood/release

log "Installing PHP dependencies..."
su -s /bin/bash -c "composer install --no-dev --prefer-dist --optimize-autoloader" deploy

log "Writing .env (prefilled weak creds)..."
cat > /var/www/stackfood/release/.env <<'ENV'
APP_NAME="HayyaEats"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://api.hayyaeats.com
APP_TIMEZONE=America/Toronto

LOG_CHANNEL=stack
LOG_LEVEL=info

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=stackfood
DB_USERNAME=stackfood
DB_PASSWORD=HayyaDb123!

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=smtp
MAIL_HOST=smtp.sendgrid.net
MAIL_PORT=587
MAIL_USERNAME=apikey
MAIL_PASSWORD=SG.fake-quick-setup
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=noreply@hayyaeats.com
MAIL_FROM_NAME="HayyaEats"

FILESYSTEM_DISK=public

# Dummy API keys for speed; replace after install
GOOGLE_MAPS_KEY=FAKE-GMAPS-KEY
FCM_SERVER_KEY=FAKE-FCM-KEY
FCM_SENDER_ID=1234567890
STRIPE_KEY=pk_test_fake
STRIPE_SECRET=sk_test_fake

# Allow admin/restaurant origins
CORS_ALLOWED_ORIGINS=https://admin.hayyaeats.com,https://restaurant.hayyaeats.com
ENV

chown deploy:www-data /var/www/stackfood/release/.env

log "Generating APP_KEY..."
su -s /bin/bash -c "php artisan key:generate" deploy || true

# ---------------------------------------------------------------------
# 5) MIGRATIONS & OPTIMIZATION
# ---------------------------------------------------------------------
log "Setting permissions and running artisan tasks..."
chown -R deploy:www-data /var/www/stackfood
find /var/www/stackfood/release/storage /var/www/stackfood/release/bootstrap/cache -type d -exec chmod 775 {} \;
su -s /bin/bash -c "php artisan storage:link" deploy || true
su -s /bin/bash -c "php artisan migrate --force" deploy || true
su -s /bin/bash -c "php artisan config:cache" deploy || true
su -s /bin/bash -c "php artisan route:cache" deploy || true
su -s /bin/bash -c "php artisan view:cache" deploy || true

# ---------------------------------------------------------------------
# 6) NGINX VHOSTS
# ---------------------------------------------------------------------
log "Configuring Nginx vhosts..."
cat > /etc/nginx/sites-available/stackfood-api <<'CONF'
server {
  server_name api.hayyaeats.com;
  root /var/www/stackfood/release/public;
  index index.php;
  client_max_body_size 20M;

  location / {
    try_files $uri $uri/ /index.php?$query_string;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
  }

  location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2)$ {
    expires 30d;
    access_log off;
  }

  access_log /var/log/nginx/stackfood-api.access.log;
  error_log  /var/log/nginx/stackfood-api.error.log;
}
CONF

cat > /etc/nginx/sites-available/stackfood-admin <<'CONF'
server {
  server_name admin.hayyaeats.com restaurant.hayyaeats.com;
  root /var/www/stackfood/release/public;
  index index.php;
  client_max_body_size 20M;

  location / {
    try_files $uri $uri/ /index.php?$query_string;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
  }

  location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2)$ {
    expires 30d;
    access_log off;
  }

  access_log /var/log/nginx/stackfood-admin.access.log;
  error_log  /var/log/nginx/stackfood-admin.error.log;
}
CONF

ln -sf /etc/nginx/sites-available/stackfood-api /etc/nginx/sites-enabled/stackfood-api
ln -sf /etc/nginx/sites-available/stackfood-admin /etc/nginx/sites-enabled/stackfood-admin
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------
# 7) SSL
# ---------------------------------------------------------------------
log "Installing certbot and issuing certificates..."
apt -y install certbot python3-certbot-nginx
certbot --nginx -d api.hayyaeats.com -d admin.hayyaeats.com -d restaurant.hayyaeats.com --redirect --agree-tos -m admin@hayyaeats.com -n || true

# ---------------------------------------------------------------------
# 8) QUEUES & SCHEDULER
# ---------------------------------------------------------------------
log "Configuring Supervisor and cron..."
apt -y install supervisor
cat > /etc/supervisor/conf.d/stackfood-queue.conf <<'CONF'
[program:stackfood-queue]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php /var/www/stackfood/release/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
numprocs=2
user=deploy
redirect_stderr=true
stdout_logfile=/var/log/supervisor/stackfood-queue.log
stopwaitsecs=3600
CONF

supervisorctl reread || true
supervisorctl update || true
supervisorctl status || true

( crontab -l 2>/dev/null; echo "* * * * * cd /var/www/stackfood/release && /usr/bin/php artisan schedule:run >> /dev/null 2>&1" ) | crontab -u deploy -

# ---------------------------------------------------------------------
# 9) FLUTTER APPS (optional quick build)
# ---------------------------------------------------------------------
log "Installing Flutter (snap) and Android build deps..."
if ! command -v snap &>/dev/null; then
  echo "Snap not available. Skipping Flutter installation." || true
else
  snap install flutter --classic || true
  flutter --version || true
  flutter doctor || true
fi
apt -y install openjdk-17-jdk || true

mkdir -p /var/www/apps
cd /var/www/apps

# Map provided zips if present under /var/www/hayyaeats
RESTA_ZIP=$(ls -1 /var/www/hayyaeats/*restaurant-app*v10.zip 2>/dev/null | head -n1 || true)
DELIV_ZIP=$(ls -1 /var/www/hayyaeats/*delivery*app*v10.zip 2>/dev/null | head -n1 || true)
USER_ZIP=$(ls -1 /var/www/hayyaeats/*user*app*v10.zip 2>/dev/null | head -n1 || true)

if [[ -n "${USER_ZIP}" && -f "${USER_ZIP}" ]]; then
  cp -f "${USER_ZIP}" /var/www/apps/user-app.zip
fi
if [[ -n "${RESTA_ZIP}" && -f "${RESTA_ZIP}" ]]; then
  cp -f "${RESTA_ZIP}" /var/www/apps/restaurant-app.zip
fi
if [[ -n "${DELIV_ZIP}" && -f "${DELIV_ZIP}" ]]; then
  cp -f "${DELIV_ZIP}" /var/www/apps/delivery-app.zip
fi

if [[ -f "/var/www/apps/user-app.zip" ]]; then
  log "Building USER app..."
  su -s /bin/bash -c "unzip -o /var/www/apps/user-app.zip -d /var/www/apps/_user-extract" deploy
  USER_DIR="$(find /var/www/apps/_user-extract -maxdepth 3 -name pubspec.yaml -exec dirname {} \; | head -n1)"
  if [[ -n "${USER_DIR}" ]]; then
    rm -rf /var/www/apps/user-app && mv "${USER_DIR}" /var/www/apps/user-app
  fi
  if [[ -f "/var/www/apps/user-app/lib/util/app_constants.dart" ]]; then
    su -s /bin/bash -c "sed -i 's#baseUrl *= *\"[^\"]*\"#baseUrl = \"https://api.hayyaeats.com\"#' /var/www/apps/user-app/lib/util/app_constants.dart" deploy || true
  fi
  cd /var/www/apps/user-app
  flutter clean && flutter pub get || true
  keytool -genkey -v -keystore /home/deploy/hayyaeats-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias hayyaeats -storepass TempKey123! -keypass TempKey123! -dname "CN=HayyaEats, OU=Tech, O=HayyaEats, L=Montreal, S=QC, C=CA" || true
  cat <<'EOF' > android/key.properties
storePassword=TempKey123!
keyPassword=TempKey123!
keyAlias=hayyaeats
storeFile=/home/deploy/hayyaeats-keystore.jks
EOF
  flutter build appbundle --release || true
  flutter build apk --release || true
  mkdir -p /var/www/builds/user
  cp -f build/app/outputs/bundle/release/app-release.aab /var/www/builds/user/ 2>/dev/null || true
  cp -f build/app/outputs/flutter-apk/app-release.apk /var/www/builds/user/ 2>/dev/null || true
fi

if [[ -f "/var/www/apps/restaurant-app.zip" ]]; then
  log "Building RESTAURANT app..."
  su -s /bin/bash -c "unzip -o /var/www/apps/restaurant-app.zip -d /var/www/apps/_restaurant-extract" deploy
  RESTA_DIR="$(find /var/www/apps/_restaurant-extract -maxdepth 3 -name pubspec.yaml -exec dirname {} \; | head -n1)"
  if [[ -n "${RESTA_DIR}" ]]; then
    rm -rf /var/www/apps/restaurant-app && mv "${RESTA_DIR}" /var/www/apps/restaurant-app
  fi
  if [[ -f "/var/www/apps/restaurant-app/lib/util/app_constants.dart" ]]; then
    su -s /bin/bash -c "sed -i 's#baseUrl *= *\"[^\"]*\"#baseUrl = \"https://api.hayyaeats.com\"#' /var/www/apps/restaurant-app/lib/util/app_constants.dart" deploy || true
  fi
  cd /var/www/apps/restaurant-app
  flutter clean && flutter pub get || true
  cp /home/deploy/hayyaeats-keystore.jks /home/deploy/hayyaeats-keystore-restaurant.jks || true
  cat <<'EOF' > android/key.properties
storePassword=TempKey123!
keyPassword=TempKey123!
keyAlias=hayyaeats
storeFile=/home/deploy/hayyaeats-keystore.jks
EOF
  flutter build appbundle --release || true
  flutter build apk --release || true
  mkdir -p /var/www/builds/restaurant
  cp -f build/app/outputs/bundle/release/app-release.aab /var/www/builds/restaurant/ 2>/dev/null || true
  cp -f build/app/outputs/flutter-apk/app-release.apk /var/www/builds/restaurant/ 2>/dev/null || true
fi

if [[ -f "/var/www/apps/delivery-app.zip" ]]; then
  log "Building DELIVERY app..."
  su -s /bin/bash -c "unzip -o /var/www/apps/delivery-app.zip -d /var/www/apps/_delivery-extract" deploy
  DELIV_DIR="$(find /var/www/apps/_delivery-extract -maxdepth 3 -name pubspec.yaml -exec dirname {} \; | head -n1)"
  if [[ -n "${DELIV_DIR}" ]]; then
    rm -rf /var/www/apps/delivery-app && mv "${DELIV_DIR}" /var/www/apps/delivery-app
  fi
  if [[ -f "/var/www/apps/delivery-app/lib/util/app_constants.dart" ]]; then
    su -s /bin/bash -c "sed -i 's#baseUrl *= *\"[^\"]*\"#baseUrl = \"https://api.hayyaeats.com\"#' /var/www/apps/delivery-app/lib/util/app_constants.dart" deploy || true
  fi
  cd /var/www/apps/delivery-app
  flutter clean && flutter pub get || true
  cp /home/deploy/hayyaeats-keystore.jks /home/deploy/hayyaeats-keystore-delivery.jks || true
  cat <<'EOF' > android/key.properties
storePassword=TempKey123!
keyPassword=TempKey123!
keyAlias=hayyaeats
storeFile=/home/deploy/hayyaeats-keystore.jks
EOF
  flutter build appbundle --release || true
  flutter build apk --release || true
  mkdir -p /var/www/builds/delivery
  cp -f build/app/outputs/bundle/release/app-release.aab /var/www/builds/delivery/ 2>/dev/null || true
  cp -f build/app/outputs/flutter-apk/app-release.apk /var/www/builds/delivery/ 2>/dev/null || true
fi

# ---------------------------------------------------------------------
# 9) BACKUPS (simple rotation)
# ---------------------------------------------------------------------
log "Configuring backups and rotation..."
mkdir -p /opt/backups && chown deploy:www-data /opt/backups
cat <<'SH' > /usr/local/bin/backup_stackfood.sh
#!/usr/bin/env bash
set -e
STAMP=$(date +"%Y%m%d-%H%M%S")
mkdir -p /opt/backups/$STAMP
mysqldump -ustackfood -p'HayyaDb123!' stackfood > /opt/backups/$STAMP/stackfood.sql
cp /var/www/stackfood/release/.env /opt/backups/$STAMP/.env
tar -czf /opt/backups/$STAMP-storage.tar.gz -C /var/www/stackfood/release storage/app/public
find /opt/backups -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null || true
SH
chmod +x /usr/local/bin/backup_stackfood.sh
( crontab -l 2>/dev/null; echo "30 2 * * * /usr/local/bin/backup_stackfood.sh" ) | crontab -u deploy -

# ---------------------------------------------------------------------
# 10) QUICK SECURITY/HEALTH (minimal)
# ---------------------------------------------------------------------
log "Tightening permissions and restarting services..."
chown -R deploy:www-data /var/www/stackfood
find /var/www/stackfood -type f -exec chmod 664 {} \;
find /var/www/stackfood -type d -exec chmod 775 {} \;
chmod -R 775 /var/www/stackfood/release/storage /var/www/stackfood/release/bootstrap/cache || true

systemctl restart nginx php8.2-fpm
supervisorctl restart all || true

log "DONE: Visit https://admin.hayyaeats.com and https://api.hayyaeats.com"
log "Android builds (if succeeded): /var/www/builds/{user,restaurant,delivery}"