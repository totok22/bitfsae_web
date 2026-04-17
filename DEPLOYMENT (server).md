# BITFSAE 部署与迁移手册

这份文档只保留当前现网真正需要执行的步骤。

适用场景：

- 在新服务器上重建当前线上环境
- 把域名从旧值迁到新值，例如从 `bitfsae.xin` 迁到 `bitfsae.com`

## 1. 当前线上架构

- 宿主机 `nginx` 负责 `80/443` 和 TLS
- 宿主机 `pm2` 负责 Web 进程 `bitfsae`，监听 `127.0.0.1:3000`
- `docker compose` 只运行这 4 个容器：`mosquitto`、`influxdb`、`telegraf`、`grafana`
- Grafana 只监听宿主机回环地址：`127.0.0.1:3001`
- Nginx 通过 `/monitor/` 反代 Grafana

- 本仓库不包含现网 Web 源码，也没有 `package.json`
- 当前仓库中的 `docker-compose.yml` 不负责 Web 站点
- Web 运行目录在服务器本地：`/opt/bitfsae`
- Web 入口文件是 `/opt/bitfsae/.output/server/index.mjs`

Web 站点源码仓库：<https://github.com/totok22/bitfsae-nuxt>

## 2. 部署前要准备的变量

先把下面这些值换成你的目标环境：

```bash
PRIMARY_DOMAIN=bitfsae.com
ALT_DOMAIN=www.bitfsae.com
LETSENCRYPT_EMAIL=3226534205@qq.com
DEPLOY_ROOT=/home/admin/fsae_project
WEB_ROOT=/opt/bitfsae
APP_PORT=3000
GRAFANA_PORT=3001
NGINX_SITE=/etc/nginx/sites-available/bitfsae
SSL_DIR=/etc/nginx/ssl
ACME_WEBROOT=/var/www/certbot
```

域名迁移时，必须同步修改这几处：

- `docker-compose.yml` 里的 `GF_SERVER_DOMAIN`
- `docker-compose.yml` 里的 `GF_SERVER_ROOT_URL`
- `/opt/bitfsae/.env` 里的 `DOMAIN`、`ALT_DOMAIN`、`LETSENCRYPT_EMAIL`
- Nginx 里的 `server_name`
- Nginx 证书文件名
- 外部 OAuth、Webhook、CDN、DNS 白名单中的旧域名

## 3. 新服务器初始化

以下命令按 Ubuntu 22.04 新机整理。

### 3.1 安装基础依赖

```bash
sudo timedatectl set-timezone Asia/Shanghai

sudo apt update
sudo apt upgrade -y
sudo apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  unzip \
  jq \
  git \
  ufw \
  nginx
```

### 3.2 给 2C2G 机器加 swap

```bash
sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

cat <<'EOF' | sudo tee /etc/sysctl.d/99-bitfsae-memory.conf >/dev/null
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

sudo sysctl --system
free -h
swapon --show
```

### 3.3 安装 Docker Engine 和 Compose 插件

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
docker --version
docker compose version
```

### 3.4 安装 Node 22 和 PM2

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v

sudo npm install -g pm2
pm2 -v
```

### 3.5 开服务和防火墙

```bash
sudo systemctl enable --now nginx

sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 1883/tcp
sudo ufw allow 9001/tcp
sudo ufw allow 8086/tcp
sudo ufw --force enable
sudo ufw status verbose
```

## 4. 拉仓库并创建目录

```bash
cd /home/admin
git clone https://github.com/totok22/bitfsae_web fsae_project
cd /home/admin/fsae_project

sudo mkdir -p /opt/bitfsae
sudo mkdir -p /etc/nginx/ssl
sudo mkdir -p /var/www/certbot/.well-known/acme-challenge
chmod +x /home/admin/fsae_project/scripts/ssl_auto_renew.sh
```

如果需要迁移旧数据，后面还会用到这些目录：

- `influxdb_1.8_data/`
- `grafana_data/`
- `mosquitto/data/`
- `mosquitto/log/`

## 5. 先改 compose 里的 Grafana 域名

当前 compose 只需要关心 Grafana 这两项：

```yaml
GF_SERVER_DOMAIN=bitfsae.com
GF_SERVER_ROOT_URL=https://bitfsae.com/monitor/
```

不改的话，Grafana 会继续跳旧域名。

修改后启动容器：

```bash
cd /home/admin/fsae_project
docker compose up -d
docker compose ps
```

预期：

- `grafana` 映射到 `127.0.0.1:3001`
- `mosquitto`、`influxdb`、`telegraf`、`grafana` 全部为 `Up`

## 6. 准备 `/opt/bitfsae/.env`

新服务器至少先放下面这些键：

```bash
sudo tee /opt/bitfsae/.env >/dev/null <<'EOF'
DOMAIN=bitfsae.com
ALT_DOMAIN=www.bitfsae.com
LETSENCRYPT_EMAIL=3226534205@qq.com
NUXT_INDEXNOW_SYNC_SECRET=
NUXT_OAUTH_GITHUB_CLIENT_ID=
NUXT_OAUTH_GITHUB_CLIENT_SECRET=
NUXT_SESSION_PASSWORD=
STUDIO_GITHUB_CLIENT_ID=
STUDIO_GITHUB_CLIENT_SECRET=
STUDIO_GITHUB_REDIRECT_URL=https://bitfsae.com/__nuxt_studio/auth/github
EOF

sudo chmod 600 /opt/bitfsae/.env
```

注意：

- `NUXT_SESSION_PASSWORD` 至少 32 字符
- `.env` 只放服务器本地，不要提交进公开仓库

## 7. 复制 Web 运行产物并启动 PM2

- `/opt/bitfsae/.output/`
- `/opt/bitfsae/ecosystem.config.cjs`

如果直接按当前线上机器复制：

```bash
sudo mkdir -p /opt/bitfsae

sudo rsync -avz <old-server>:/opt/bitfsae/.output/ /opt/bitfsae/.output/
sudo scp <old-server>:/opt/bitfsae/ecosystem.config.cjs /opt/bitfsae/ecosystem.config.cjs

# 二选一：复制旧 .env，或者继续使用第 6 步手工创建的新 .env
sudo scp <old-server>:/opt/bitfsae/.env /opt/bitfsae/.env
sudo chmod 600 /opt/bitfsae/.env
```

当前线上 PM2 配置至少要满足这些字段：

```js
module.exports = {
  apps: [
    {
      name: 'bitfsae',
      port: '3000',
      exec_mode: 'cluster',
      instances: 'max',
      script: './.output/server/index.mjs',
      max_memory_restart: '512M',
      env: {
        NODE_ENV: 'production',
        NITRO_PRESET: 'node-server',
        NUXT_PUBLIC_SITE_URL: 'https://<your-domain>'
      }
    }
  ]
}
```

启动 PM2：

```bash
cd /opt/bitfsae
pm2 start ecosystem.config.cjs
pm2 save
pm2 ls

sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root
pm2 save
```

本机自检：

```bash
curl -I http://127.0.0.1:3000
```

## 8. 写宿主机 Nginx 配置

迁移时，按这个模板写入 `/etc/nginx/sites-available/bitfsae`：

```nginx
upstream nuxt_app {
    server 127.0.0.1:3000;
    keepalive 64;
}

upstream grafana_app {
    server 127.0.0.1:3001;
}

server {
    listen 80;
    server_name bitfsae.com;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        return 301 https://www.bitfsae.com$request_uri;
    }
}

server {
    listen 80;
    server_name www.bitfsae.com;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        return 301 https://www.bitfsae.com$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name bitfsae.com;

    ssl_certificate     /etc/nginx/ssl/bitfsae.com.pem;
    ssl_certificate_key /etc/nginx/ssl/bitfsae.com.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        return 301 https://www.bitfsae.com$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name www.bitfsae.com;

    ssl_certificate     /etc/nginx/ssl/bitfsae.com.pem;
    ssl_certificate_key /etc/nginx/ssl/bitfsae.com.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        proxy_pass http://nuxt_app;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /_nuxt/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_cache_bypass $http_upgrade;
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
    }

    location /monitor/ {
        proxy_pass http://grafana_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

启用并检查：

```bash
sudo ln -sf /etc/nginx/sites-available/bitfsae /etc/nginx/sites-enabled/bitfsae
sudo nginx -t
sudo systemctl reload nginx

# 验证 bitfsae.com 会 301 到 https://www.bitfsae.com
curl -I http://bitfsae.com
curl -I https://bitfsae.com

# 验证主站可访问
curl -I https://www.bitfsae.com
```

## 9. 处理 DNS

至少保证：

- `A @ -> 新服务器 IPv4`
- `A www -> 新服务器 IPv4`

如果要配 IPv6，再加：

- `AAAA @ -> 新服务器 IPv6`
- `AAAA www -> 新服务器 IPv6`

如果 IPv6 还没配好，先删旧 `AAAA`，不然 Let's Encrypt 很容易失败。

检查：

```bash
dig +short bitfsae.com A
dig +short www.bitfsae.com A
dig +short bitfsae.com AAAA
dig +short www.bitfsae.com AAAA
```

## 10. 补充：EdgeOne 和 GitHub CI/CD

- 如果域名接入腾讯云 EdgeOne，先确保源站 Nginx、证书和回源都正常，再开启代理、缓存或规则；`/.well-known/acme-challenge/` 不要被缓存、改写或拦截
- Nuxt 网站如果通过 GitHub CI/CD 部署，迁移域名时要同步检查构建环境变量、部署目标机器、回调地址和 `NUXT_PUBLIC_SITE_URL`，避免 CI 仍把产物发到旧环境或带着旧域名配置

## 11. 首次申请证书

本仓库已经有脚本：`/home/admin/fsae_project/scripts/ssl_auto_renew.sh`

首签前必须满足：

- 域名已经解析到新服务器
- 80 端口可从公网访问
- Nginx 已放行 `/.well-known/acme-challenge/`
- 如配置了 `AAAA`，IPv6 也指向新服务器

执行：

```bash
cd /home/admin/fsae_project
sudo /bin/bash -lc 'set -a; . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh'
```

成功后检查：

```bash
sudo openssl x509 -in /etc/nginx/ssl/bitfsae.com.pem -noout -issuer -subject -dates
```

## 12. 安装自动续签 cron

```bash
cat <<'EOF' | sudo tee /etc/cron.d/bitfsae-ssl-renew >/dev/null
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /bin/bash -lc 'set -a; [ -f /opt/bitfsae/.env ] && . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh >> /var/log/bitfsae-ssl-renew.log 2>&1'
EOF

sudo chmod 644 /etc/cron.d/bitfsae-ssl-renew
```

手工跑一次验证：

```bash
sudo /bin/bash -lc 'set -a; . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh'
```

## 13. 如需迁移旧数据

先停容器，再打包旧数据目录：

```bash
cd /home/admin/fsae_project
docker compose down
tar -czf fsae-data-backup.tar.gz influxdb_1.8_data grafana_data mosquitto/data mosquitto/log
```

迁移完成后重新启动：

```bash
docker compose up -d
docker compose ps
```

## 14. 切流前验收

正式切换前至少执行一次：

```bash
curl -I http://bitfsae.com
curl -I https://bitfsae.com
curl -I https://bitfsae.com/monitor/
pm2 ls
docker compose ps
sudo openssl x509 -in /etc/nginx/ssl/bitfsae.com.pem -noout -issuer -subject -dates
```

结果应满足：

- HTTP 能跳 HTTPS
- Web 首页能正常返回
- `/monitor/` 能正常打开 Grafana
- `pm2 ls` 中 `bitfsae` 为 `online`
- `docker compose ps` 中 4 个容器都为 `Up`
- 证书域名和到期时间正确

## 15. 迁移时最容易漏的点

只检查下面这几项，基本就够了：

1. `docker-compose.yml` 里的 Grafana 域名是否改了。
2. `/opt/bitfsae/.env` 里的 `DOMAIN`、`ALT_DOMAIN` 是否改了。
3. `/opt/bitfsae/ecosystem.config.cjs` 里的 `NUXT_PUBLIC_SITE_URL` 是否改了。
4. Nginx 的 `server_name` 和证书文件名是否改了。
5. `AAAA` 记录是不是还留着旧地址。
6. OAuth、Webhook、CDN、DNS 白名单里是否还有旧域名。
7. EdgeOne 和 GitHub CI/CD 里是否还保留旧域名或旧部署目标。

## 16. 和仓库隔离的敏感文件

当前仓库是公开仓库，下面这些内容不要提交：

- `/opt/bitfsae/.env`
- `/etc/letsencrypt/` 下的证书
- `/etc/nginx/ssl/` 下的证书和私钥
- Grafana、InfluxDB、Mosquitto 的导出数据
- 各类第三方平台密钥和回调参数

部署完成后可以顺手检查一次：

```bash
cd /home/admin/fsae_project
git status --ignored
find . -maxdepth 3 \( -name '*.pem' -o -name '*.key' -o -name '.env' -o -name '*.sql' -o -name '*.tar.gz' \)
```

## 17. 当前仓库里的历史目录

- `nginx_docker_old/` 是旧方案残留，不是当前现网配置
- `www_old_backup/` 是旧静态站备份，不参与当前线上服务

## 18. 备案阶段临时下线

如果处于备案阶段，需要临时关闭公开网站，建议只停 Web 进程，不停遥测容器。

执行下线：

```bash
cd /home/admin/fsae_project
sudo bash scripts/site_switch.sh down
pm2 ls
```

执行恢复：

```bash
cd /home/admin/fsae_project
sudo bash scripts/site_switch.sh up
pm2 ls
```

说明：

- 该操作只影响 `pm2` 的 `bitfsae` Web 进程。
- `docker compose` 的 `mosquitto`、`influxdb`、`telegraf`、`grafana` 不会被停止。