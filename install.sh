#!/bin/bash
set -e

# 确保以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本（使用 sudo）"
    exit 1
fi

echo "更新系统..."
apt update && apt upgrade -y

echo "安装基本工具..."
apt install -y curl wget gnupg2 ca-certificates apt-transport-https software-properties-common lsb-release sudo git

curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx

curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
echo "X-Repolib-Name: MariaDB" | sudo tee /etc/apt/sources.list.d/mariadb.sources
echo "Types: deb" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "URIs: https://deb.mariadb.org/11.4/debian" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Suites: bookworm" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Components: main" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources
echo "Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp" | sudo tee -a /etc/apt/sources.list.d/mariadb.sources

apt update

apt install -y nginx redis-server mariadb-server jq

systemctl start nginx
systemctl enable nginx
systemctl start redis-server
systemctl enable redis-server
systemctl start mariadb
systemctl enable mariadb

mariadb-secure-installation <<EOF
\n
n
n
y
y
y
y
EOF

read -p "请输入要创建的数据库名称: " dbname
read -p "请创建数据库用户名: " dbuser
read -p "请创建数据库用户密码: " dbpass
echo

mariadb -u root <<EOF
CREATE DATABASE $dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';
GRANT ALL PRIVILEGES ON $dbname.* TO '$dbuser'@'localhost';
FLUSH PRIVILEGES;
EOF

# 添加 PHP 8.4 源 (Sury)
echo "添加 PHP 8.4 源..."
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
apt update

# 安装 PHP 8.4 及其扩展
echo "安装 PHP 8.4 及其扩展..."
apt install -y php8.4-cli php8.4-mysql php8.4-redis php8.4-swoole php8.4-dev php8.4-xml php-pear
if [ $? -ne 0 ]; then
    echo "PHP 8.4 扩展安装失败，请检查软件源或网络连接"
    exit 1
fi

# 设置 PHP 8.4 为默认版本
echo "设置 PHP 8.4 为默认版本..."
update-alternatives --set php /usr/bin/php8.4
update-alternatives --set phpize /usr/bin/phpize8.4
update-alternatives --set php-config /usr/bin/php-config8.4

# 安装 event 扩展
echo "安装 event 扩展..."
apt install -y libevent-dev libssl-dev zlib1g-dev gcc g++ make autoconf pkg-config libc6-dev
if ! pecl install event; then
    echo "event 扩展安装失败，请检查日志或尝试手动安装"
    exit 1
fi

# 配置扩展加载顺序，确保 sockets 在 event 之前
echo "配置 PHP 扩展加载顺序..."
echo "extension=sockets.so" > /etc/php/8.4/mods-available/sockets.ini
ln -sf /etc/php/8.4/mods-available/sockets.ini /etc/php/8.4/cli/conf.d/10-sockets.ini
echo "extension=event.so" > /etc/php/8.4/mods-available/event.ini
ln -sf /etc/php/8.4/mods-available/event.ini /etc/php/8.4/cli/conf.d/20-event.ini

# 启用 PHP 相关函数
echo "启用 PHP 相关函数..."
PHP_INI="/etc/php/8.4/cli/php.ini"
sed -i '/disable_functions/d' "$PHP_INI"
echo "disable_functions =" >> "$PHP_INI"

# 创建并进入 /www/xboard 目录，克隆 Xboard 项目
echo "创建网站目录并克隆 Xboard 项目..."
mkdir -p /www/xboard
cd /www/xboard
git clone https://github.com/cedar2025/Xboard.git ./

# 设置网站目录权限
echo "设置网站目录权限..."
chmod -R 755 /www/xboard/*
chown -R www-data:www-data /www/xboard/*

# 执行 Xboard 初始化步骤
echo "执行 Xboard 初始化步骤..."
rm -rf /www/xboard/composer.phar
wget https://github.com/composer/composer/releases/latest/download/composer.phar -O /www/xboard/composer.phar
php /www/xboard/composer.phar install -vvv
echo "即将运行 Xboard 安装命令，请根据提示输入必要信息（数据库信息可用之前输入的 $dbname, $dbuser, $dbpass）..."
php artisan xboard:install

# 安装 Supervisor
echo "安装 Supervisor..."
apt install -y supervisor

# 配置 Supervisor - Xboard Horizon 队列进程
echo "配置 Supervisor - Xboard Horizon 队列进程..."
cat <<EOF > /etc/supervisor/conf.d/xboard.conf
[program:xboard]
user=www-data
directory=/www/xboard
command=php artisan horizon
numprocs=1
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
EOF

# 配置 Supervisor - Octane 服务进程
echo "配置 Supervisor - Octane 服务进程..."
cat <<EOF > /etc/supervisor/conf.d/octane.conf
[program:octane]
user=www-data
directory=/www/xboard
command=/www/server/php/84/bin/php artisan octane:start --port=7010
numprocs=1
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
EOF

# 配置定时任务
echo "配置定时任务 - v2board..."
echo "* * * * * www-data php /www/xboard/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/v2board

# 启动 Supervisor 并更新配置
echo "启动 Supervisor 并加载配置..."
systemctl enable supervisor
systemctl start supervisor
supervisorctl reread
supervisorctl update
supervisorctl start all

# 检查安装情况
echo "安装完成，版本信息如下："
mariadb --version
redis-cli --version
nginx -v
php -v

echo "PHP 扩展："
php -m | grep -E "redis|fileinfo|swoole|readline|event|pcntl|sockets"

echo "PHP 关键函数启用状态："
php -r "echo function_exists('putenv') ? 'putenv 启用' : 'putenv 未启用'; echo PHP_EOL;"
php -r "echo function_exists('proc_open') ? 'proc_open 启用' : 'proc_open 未启用'; echo PHP_EOL;"
php -r "echo function_exists('pcntl_alarm') ? 'pcntl_alarm 启用' : 'pcntl_alarm 未启用'; echo PHP_EOL;"
php -r "echo function_exists('pcntl_signal') ? 'pcntl_signal 启用' : 'pcntl_signal 未启用'; echo PHP_EOL;"

echo "安装脚本执行完毕！"
