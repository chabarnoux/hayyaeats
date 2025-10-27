#!/usr/bin/env bash
set -euo pipefail

# === CURSOR AGENT FAST INSTALL (StackFood v10) ===
# Domain: hayyaeats.com
# Subdomains: api.hayyaeats.com, admin.hayyaeats.com, restaurant.hayyaeats.com
# Timezone: America/Toronto
# NOTE: Credentials are weak for speed. Complete install first, harden later.

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
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'TempRoot123!'; FLUSH PRIVILEGES;" || true
mysql -uroot -pTempRoot123! -e "CREATE DATABASE IF NOT EXISTS stackfood DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -uroot -pTempRoot123! -e "CREATE USER IF NOT EXISTS 'stackfood'@'localhost' IDENTIFIED BY 'TempDB123!';"
mysql -uroot -pTempRoot123! -e "GRANT ALL PRIVILEGES ON stackfood.* TO 'stackfood'@'localhost'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------------------
# 3) BACKEND DEPLOY
# ---------------------------------------------------------------------
log "Preparing backend directory..."
su -s /bin/bash -c "mkdir -p /var/www/stackfood" deploy
cd /var/www/stackfood

if [[ ! -f "/var/www/stackfood/stackfood-backend.zip" ]]; then
  echo "Missing /var/www/stackfood/stackfood-backend.zip. Upload your Laravel backend zip with this exact name, then rerun." >&2
  exit 1
fi

log "Unzipping backend release..."
su -s /bin/bash -c "unzip -o /var/www/stackfood/stackfood-backend.zip -d /var/www/stackfood/release" deploy
cd /var/www/stackfood/release

log "Installing PHP dependencies..."
su -s /bin/bash -c "composer install --no-dev --prefer-dist --optimize-autoloader" deploy

log "Setting up environment..."
su -s /bin/bash -c "cp -n .env.example .env || true" deploy
su -s /bin/bash -c "php artisan key:generate" deploy || true

log "Writing minimal .env..."
cat > /var/www/stackfood/release/.env <<'ENV'
APP_NAME="HayyaEats"
APP_ENV=production
APP_KEY=base64:REPLACED_BY_KEY_GENERATE
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
DB_PASSWORD=TempDB123!

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

FILESYSTEM_DISK=public

MAIL_MAILER=smtp
MAIL_HOST=smtp.sendgrid.net
MAIL_PORT=587
MAIL_USERNAME=apikey
MAIL_PASSWORD=TempMail123!
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=noreply@hayyaeats.com
MAIL_FROM_NAME="HayyaEats"

GOOGLE_MAPS_KEY=
FCM_SERVER_KEY=
FCM_SENDER_ID=
STRIPE_KEY=
STRIPE_SECRET=

CORS_ALLOWED_ORIGINS=https://admin.hayyaeats.com,https://restaurant.hayyaeats.com
ENV

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

if [[ -f "/var/www/apps/user-app.zip" ]]; then
  log "Building USER app..."
  su -s /bin/bash -c "unzip -o /var/www/apps/user-app.zip -d /var/www/apps/user-app" deploy
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
  su -s /bin/bash -c "unzip -o /var/www/apps/restaurant-app.zip -d /var/www/apps/restaurant-app" deploy
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
  su -s /bin/bash -c "unzip -o /var/www/apps/delivery-app.zip -d /var/www/apps/delivery-app" deploy
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