# BITFSAE 从零部署与迁移手册

本文档面向两类场景：

- 在一台全新服务器上从零部署当前系统
- 将现有系统迁移到新域名或新域名后缀，例如从 `bitfsae.xin` 迁到 `bitfsae.site`

文档按“先准备、再部署、后验收”的顺序整理，尽量避免依赖旧机器上的隐性状态。

## 1. 当前线上架构基线

当前已验证的生产架构如下：

- 宿主机 `nginx` 负责 `80/443` 入口与 TLS
- 宿主机 `pm2` 管理 Web 应用进程 `bitfsae`，监听 `127.0.0.1:3000`
- `docker compose` 仅运行遥测与监控容器：
  - `mosquitto`
  - `influxdb`
  - `telegraf`
  - `grafana`
- Nginx 路由：
  - `/` -> `127.0.0.1:3000`
  - `/monitor/` -> `127.0.0.1:3001`

当前机器还能确认到这些现网事实：

- Web 运行目录：`/opt/bitfsae`
- PM2 运行用户：`root`
- PM2 当前为 `cluster` 模式，在 2 核机器上实际跑 `2` 个实例
- PM2 日志目录：`/root/.pm2/logs`
- PM2 状态快照：`/root/.pm2/dump.pm2`
- Web 实际启动文件：`/opt/bitfsae/.output/server/index.mjs`
- 宿主机已启用站点链接：`/etc/nginx/sites-enabled/bitfsae -> /etc/nginx/sites-available/bitfsae`
- 当前 Node 版本：`22.22.0`
- 当前 PM2 版本：`6.0.14`
- 当前 Docker Compose 版本：`v5.0.0`

这意味着迁移时不要把本仓库误解为“Web 也由 Docker 托管”。当前仓库中的 `docker-compose.yml` 只覆盖遥测与监控链路，不负责 Web 站点本身。

 Web 站点源码：https://github.com/totok22/bitfsae-nuxt。

## 2. 迁移时必须替换的参数

新服务器或新域名上线时，先确定以下变量：

```bash
PRIMARY_DOMAIN=bitfsae.site
ALT_DOMAIN=www.bitfsae.site
LETSENCRYPT_EMAIL=3226534205@qq.com
APP_PORT=3000
GRAFANA_PORT=3001
DEPLOY_ROOT=/home/admin/fsae_project
ENV_FILE=/opt/bitfsae/.env
NGINX_SITE=/etc/nginx/sites-available/bitfsae
SSL_DIR=/etc/nginx/ssl
ACME_WEBROOT=/var/www/certbot
```

下面这些地方都要随域名更新：

- Nginx 的 `server_name`
- Nginx 证书文件名
- `docker-compose.yml` 中 Grafana 的 `GF_SERVER_DOMAIN`
- `docker-compose.yml` 中 Grafana 的 `GF_SERVER_ROOT_URL`
- `/opt/bitfsae/.env` 中的 `DOMAIN`、`ALT_DOMAIN`、`LETSENCRYPT_EMAIL`
- 任何 CI/CD、前端环境变量、第三方回调地址中写死的旧域名

## 3. 迁移前清单

迁移前先确认这些事实，否则很容易在切流后出错：

1. 你是否拥有新域名的 DNS 管理权限。
2. 新服务器是否开放 `80`、`443`、`1883`、`9001`、`8086`。
3. 若域名存在 `AAAA` 记录，IPv6 是否真的指向新服务器。
4. 如果 IPv6 尚未配置完成，迁移前先删除旧 `AAAA` 记录。
5. Web 应用的构建产物或源码启动方式是否已经准备好。
6. 旧服务器上的数据目录是否需要迁移：
   - `influxdb_1.8_data/`
   - `grafana_data/`
   - `mosquitto/data/`
   - `mosquitto/log/`

第 3 和第 4 点很重要。Let's Encrypt 校验会同时使用域名解析到的地址；如果 `AAAA` 记录还指向旧机器，会出现“明明 A 记录正确但签证失败”的情况。

## 4. 新服务器初始化

以下步骤按“Ubuntu 20.04、2 核 2G、全新机器”整理，尽量写成可以直接执行的命令。

### 4.1 基础系统初始化

```bash
sudo timedatectl set-timezone Asia/Shanghai
timedatectl

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

如果需要设置主机名：

```bash
sudo hostnamectl set-hostname bitfsae-prod
hostnamectl
```

### 4.2 为 2C2G 机器配置 swap

2G 内存在同时运行 Nginx、PM2、Grafana、InfluxDB、Mosquitto、Telegraf 时偏紧，建议至少先配一个 `2G swap`。如果后续 Web 站点构建也在这台机器上完成，可以直接改成 `4G`。

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

### 4.3 安装 Docker Engine 与 Compose 插件

Ubuntu 20.04 上建议使用 Docker 官方源，不建议长期依赖系统自带的较旧包。

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

如果后续希望当前用户直接运行 Docker：

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 4.4 安装 Node.js LTS 与 PM2

这一步是为当前现网的 Nuxt/Nitro 运行目录 `/opt/bitfsae` 准备运行环境。现网机器实际跑的是 Node `22.22.0`，因此新服务器建议直接对齐 Node 22。

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v

sudo npm install -g pm2
pm2 -v
```

### 4.5 启动系统服务与防火墙

```bash
sudo systemctl enable --now nginx
sudo systemctl status nginx --no-pager

sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 1883/tcp
sudo ufw allow 9001/tcp
sudo ufw allow 8086/tcp
sudo ufw --force enable
sudo ufw status verbose
```

### 4.6 2C2G 机器的额外建议

- 不要在这台机器上额外安装桌面环境。
- 如果 Web 站点需要本机编译，构建完成后及时清理缓存，例如 `npm cache clean --force`。
- 若 Grafana 插件较多或 InfluxDB 数据量很大，优先考虑把构建步骤放到 CI 或本地，再把产物上传到服务器。
- 生产环境尽量只保留必要进程，避免同时开多个 PM2 应用或无关容器。

## 5. 拉取仓库与目录准备

```bash
cd /home/admin
git clone https://github.com/totok22/bitfsae_web fsae_project
cd /home/admin/fsae_project

sudo mkdir -p /opt/bitfsae
sudo mkdir -p /etc/nginx/ssl
sudo mkdir -p /var/www/certbot/.well-known/acme-challenge
```

当前机器上，仓库外的 Web 运行目录实际长这样：

```text
/opt/bitfsae/
├── .env
├── ecosystem.config.cjs
└── .output/
    ├── nitro.json
    ├── public/
    └── server/
```

这几个文件和目录不在当前仓库里，但它们是现网 Web 正常运行所必需的。

给续签脚本执行权限：

```bash
chmod +x /home/admin/fsae_project/scripts/ssl_auto_renew.sh
```

## 6. 准备环境变量文件

当前自动续签链路和 Web 运行时都依赖 `/opt/bitfsae/.env`。现网机器上已确认存在以下键：

- `LETSENCRYPT_EMAIL`
- `NUXT_INDEXNOW_SYNC_SECRET`
- `NUXT_OAUTH_GITHUB_CLIENT_ID`
- `NUXT_OAUTH_GITHUB_CLIENT_SECRET`
- `NUXT_SESSION_PASSWORD`
- `STUDIO_GITHUB_CLIENT_ID`
- `STUDIO_GITHUB_CLIENT_SECRET`
- `STUDIO_GITHUB_REDIRECT_URL`

新服务器至少先写成下面这样，再按你的实际域名和凭据补齐真实值：

```bash
sudo tee /opt/bitfsae/.env >/dev/null <<'EOF'
DOMAIN=bitfsae.site
ALT_DOMAIN=www.bitfsae.site
LETSENCRYPT_EMAIL=3226534205@qq.com
NUXT_INDEXNOW_SYNC_SECRET=
NUXT_OAUTH_GITHUB_CLIENT_ID=
NUXT_OAUTH_GITHUB_CLIENT_SECRET=
NUXT_SESSION_PASSWORD=
STUDIO_GITHUB_CLIENT_ID=
STUDIO_GITHUB_CLIENT_SECRET=
STUDIO_GITHUB_REDIRECT_URL=https://bitfsae.site/__nuxt_studio/auth/github
EOF

sudo chmod 600 /opt/bitfsae/.env
```

其中：

- `NUXT_SESSION_PASSWORD` 必须至少 32 字符。
- `STUDIO_GITHUB_REDIRECT_URL` 要和你的最终域名一致。
- `.env` 只放服务器本地，绝对不要提交到公开仓库。

## 7. DNS 配置

至少需要以下记录：

- `A @ -> 新服务器 IPv4`
- `A www -> 新服务器 IPv4`

若服务器有可用 IPv6，再增加：

- `AAAA @ -> 新服务器 IPv6`
- `AAAA www -> 新服务器 IPv6`

如果暂时没有 IPv6，就不要保留旧的 `AAAA` 记录。

切换 DNS 后建议显式验证：

```bash
dig +short bitfsae.site A
dig +short www.bitfsae.site A
dig +short bitfsae.site AAAA
dig +short www.bitfsae.site AAAA
```

## 8. EdgeOne 接入建议

如果新域名大概率会挂到 EdgeOne 做加速，建议按下面原则接入，而不是一开始就把所有功能同时打开。

### 8.1 推荐接入顺序

1. 先让域名直连源站，完成 Nginx、PM2、Grafana、证书首签。
2. 确认源站 HTTPS 正常后，再到 EdgeOne 打开代理或加速。
3. 最后再逐项开启缓存、WAF、强制 HTTPS、页面规则。

这样做的原因很直接：证书、回源、站点本身三件事最好分阶段排错，不要同时变更。

### 8.2 EdgeOne 接入时要检查的点

- 源站回源必须能访问 `80/443`。
- 在源站证书尚未就绪前，不要先在 EdgeOne 侧强制 HTTPS 回源。
- `/.well-known/acme-challenge/` 不要被缓存、重写、鉴权或 WAF 拦截。
- 如果后续 Web 站点或 Grafana 使用 WebSocket，确认 EdgeOne 已允许对应升级请求。
- 首次切流时，建议先关闭激进缓存策略，避免把旧站页面或错误页长时间缓存到边缘。

### 8.3 与 Let's Encrypt 并用时的建议

本项目当前方案是“源站自己持有 Let's Encrypt 证书”，不是把 TLS 终止完全交给 EdgeOne。因此：

- 源站上的 `/etc/nginx/ssl/<域名>.pem` 与 `.key` 仍然必须存在。
- `/etc/letsencrypt/` 与自动续签仍然必须保留。
- 如果 EdgeOne 代理影响了 HTTP-01 校验，优先把 `/.well-known/acme-challenge/` 设为绕过规则，必要时可在首签阶段临时切回仅 DNS 解析。

## 9. 配置 Docker Compose

当前仓库中的 `docker-compose.yml` 只负责遥测与监控容器。迁移到新域名时，至少要改这两个环境变量：

```yaml
GF_SERVER_DOMAIN=bitfsae.site
GF_SERVER_ROOT_URL=https://bitfsae.site/monitor/
```

如果不改，Grafana 的跳转和静态资源 URL 仍会指向旧域名。

启动遥测与监控容器：

```bash
cd /home/admin/fsae_project
docker compose up -d
docker compose ps
```

预期结果：

- `grafana` 映射到 `127.0.0.1:3001`
- `mosquitto`、`influxdb`、`telegraf` 正常运行

## 10. 配置 Web 应用与 PM2

当前线上模式是宿主机 PM2 托管 Web 应用，反代入口由 Nginx 提供。

这一步不要再用泛化路径。按当前服务器实况，Web 运行目录就是 `/opt/bitfsae`，PM2 以 `root` 身份运行，入口文件就是 `/opt/bitfsae/.output/server/index.mjs`。

这一步取决于你的 Web 应用发布方式，但目标必须满足：

- 应用监听 `127.0.0.1:3000`
- PM2 进程名称为 `bitfsae`
- 当前现网的 PM2 模式为 `cluster`
- 当前现网的内存保护为 `max_memory_restart=512M`

### 10.1 需要从旧服务器复制的仓库外文件

如果你不在新服务器重新构建 Nuxt，而是按当前机器直接复刻运行环境，那么至少要复制这些仓库外内容：

```text
/opt/bitfsae/.output/
/opt/bitfsae/ecosystem.config.cjs
```

`.env` 不建议直接进入 Git，但在服务器迁移时可以安全地从旧服务器复制到新服务器，或者手动按上一节模板重建。

最直接的迁移命令示例：

```bash
sudo mkdir -p /opt/bitfsae

sudo rsync -avz <old-server>:/opt/bitfsae/.output/ /opt/bitfsae/.output/
sudo scp <old-server>:/opt/bitfsae/ecosystem.config.cjs /opt/bitfsae/ecosystem.config.cjs

# 二选一：复制旧服务器 .env，或按第 6 节手工重建
sudo scp <old-server>:/opt/bitfsae/.env /opt/bitfsae/.env
sudo chmod 600 /opt/bitfsae/.env
```

### 10.2 当前机器正在使用的 PM2 配置

当前现网 `/opt/bitfsae/ecosystem.config.cjs` 的结构如下，迁移时建议按这个结构重建，只替换域名相关值：

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

如果你要完全照当前现网复刻，新的 `/opt/bitfsae/ecosystem.config.cjs` 至少要具备上面这些字段。

### 10.3 启动 PM2

当前现网是 Nuxt/Nitro 产物直接运行，所以新服务器上建议直接这样做：

```bash
cd /opt/bitfsae
pm2 start ecosystem.config.cjs
pm2 save
pm2 ls
```

当前机器没有看到现成的 `pm2-*.service` 单元文件，因此为了让新服务器重启后也能自动拉起，建议额外执行：

```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root
pm2 save
```

当前现网 PM2 日志位置如下，排错时直接看这里：

```text
/root/.pm2/logs/bitfsae-out-0.log
/root/.pm2/logs/bitfsae-error-0.log
/root/.pm2/logs/bitfsae-out-1.log
/root/.pm2/logs/bitfsae-error-1.log
```

## 11. 配置 Nginx

新服务器上创建站点配置文件：

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
    server_name bitfsae.site www.bitfsae.site;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name bitfsae.site www.bitfsae.site;

    ssl_certificate     /etc/nginx/ssl/bitfsae.site.pem;
    ssl_certificate_key /etc/nginx/ssl/bitfsae.site.key;
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

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 1000;

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

写入 `/etc/nginx/sites-available/bitfsae` 后执行：

```bash
sudo ln -sf /etc/nginx/sites-available/bitfsae /etc/nginx/sites-enabled/bitfsae
sudo nginx -t
sudo systemctl reload nginx
```

## 12. 申请 SSL 证书

本仓库已有自动化脚本：`/home/admin/fsae_project/scripts/ssl_auto_renew.sh`

脚本支持从环境变量读取：

- `DOMAIN`
- `ALT_DOMAIN`
- `LETSENCRYPT_EMAIL`
- `LE_DIR`
- `WEBROOT_HOST`
- `CERT_OUT_DIR`
- `RELOAD_CMD`

首次申请前，确保：

1. 域名 DNS 已指向新服务器
2. `80` 端口能从公网访问
3. Nginx 已放行 `/.well-known/acme-challenge/`
4. 如果配置了 `AAAA`，IPv6 也必须正确

手动首签命令：

```bash
cd /home/admin/fsae_project
sudo /bin/bash -lc 'set -a; . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh'
```

签发成功后应看到：

- `/etc/letsencrypt/live/<域名>/fullchain.pem`
- `/etc/letsencrypt/live/<域名>/privkey.pem`
- `/etc/nginx/ssl/<域名>.pem`
- `/etc/nginx/ssl/<域名>.key`

验证命令：

```bash
sudo openssl x509 -in /etc/nginx/ssl/bitfsae.site.pem -noout -issuer -subject -dates
```

## 13. 配置自动续签

当前推荐使用系统级 cron：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /bin/bash -lc 'set -a; [ -f /opt/bitfsae/.env ] && . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh >> /var/log/bitfsae-ssl-renew.log 2>&1'
```

安装方式：

```bash
cat <<'EOF' | sudo tee /etc/cron.d/bitfsae-ssl-renew >/dev/null
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /bin/bash -lc 'set -a; [ -f /opt/bitfsae/.env ] && . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh >> /var/log/bitfsae-ssl-renew.log 2>&1'
EOF

sudo chmod 644 /etc/cron.d/bitfsae-ssl-renew
```

验证续签路径是否可工作：

```bash
sudo /bin/bash -lc 'set -a; . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh'
```

如果证书还未到期，看到 `Certificate not yet due for renewal` 属于正常现象。

## 14. 数据迁移

如果新服务器需要保留旧数据，至少迁移这些目录：

```bash
influxdb_1.8_data/
grafana_data/
mosquitto/data/
mosquitto/log/
```

推荐步骤：

1. 在旧服务器停止相关容器写入。
2. 打包并传输数据目录。
3. 在新服务器解压到仓库对应位置。
4. 重新执行 `docker compose up -d`。

示例：

```bash
cd /home/admin/fsae_project
docker compose down
tar -czf fsae-data-backup.tar.gz influxdb_1.8_data grafana_data mosquitto/data mosquitto/log
```

## 15. 切流前验收清单

正式切换前，至少逐项验证：

1. `curl -I http://<域名>` 能跳转到 HTTPS。
2. `curl -I https://<域名>` 返回 `200` 或正常业务状态码。
3. `curl -I https://<域名>/monitor/` 返回 `200`、`302` 或 Grafana 正常响应。
4. `pm2 ls` 中 `bitfsae` 为 `online`。
5. `docker compose ps` 中遥测与监控容器均为 `Up`。
6. `openssl x509` 看到的证书为新域名且到期时间正确。
7. `dig` 检查 `A/AAAA` 记录均指向新服务器。

## 16. 域名更换时最容易漏掉的地方

从 `.xin` 切到 `.site` 这类迁移，最常漏掉的是：

1. `docker-compose.yml` 里的 `GF_SERVER_DOMAIN` 和 `GF_SERVER_ROOT_URL`。
2. `/opt/bitfsae/.env` 中的 `DOMAIN` 和 `ALT_DOMAIN`。
3. Nginx 的 `server_name`。
4. Nginx 证书文件名。
5. 残留的 `AAAA` 记录。
6. CI/CD 或前端配置里写死的旧域名。
7. 外部服务白名单、Webhook、OAuth 回调地址。

## 17. 故障排查

### 17.1 Let's Encrypt 申请失败

先查日志：

```bash
sudo tail -n 200 /var/log/letsencrypt/letsencrypt.log
tail -n 200 /var/log/bitfsae-ssl-renew.log
```

常见原因：

- 域名解析还没生效
- `AAAA` 指向了错误的 IPv6
- Nginx 未放行 `/.well-known/acme-challenge/`
- 80 端口被防火墙拦截
- 443 路由把 challenge 覆盖掉了

### 17.2 Nginx 无法重载

```bash
sudo nginx -t
sudo journalctl -u nginx -n 200 --no-pager
```

### 17.3 Grafana 路由异常

```bash
docker compose logs -f grafana
docker compose ps
```

如果出现重定向到旧域名，优先检查 `GF_SERVER_DOMAIN` 与 `GF_SERVER_ROOT_URL`。

### 17.4 Web 首页无法访问

```bash
pm2 logs bitfsae
pm2 ls
curl -I http://127.0.0.1:3000
```

## 18. 公开仓库与密钥管理要求

当前仓库是公开仓库，因此下面这些内容必须明确与仓库隔离：

- 不要提交真实证书文件，例如 `.pem`、`.key`、`fullchain.pem`、`privkey.pem`。
- 不要提交服务器环境变量文件，例如 `/opt/bitfsae/.env`。
- 不要提交数据库导出、Grafana 备份、Mosquitto 持久化数据或包含账号信息的日志。
- 不要把 EdgeOne、DNS、邮件、Webhook、OAuth 等后台截图或敏感回调参数放进仓库文档。

建议的放置位置如下：

- 证书与私钥：`/etc/letsencrypt/`、`/etc/nginx/ssl/`
- 服务器环境变量：`/opt/bitfsae/.env`
- 自动续签计划：`/etc/cron.d/bitfsae-ssl-renew`
- Web 应用运行目录：`/opt/bitfsae/`
- PM2 运行状态与日志：`/root/.pm2/`

新服务器初始化后，建议先手动确认以下命令输出中没有误把秘密文件放进 Git：

```bash
cd /home/admin/fsae_project
git status --ignored
find . -maxdepth 3 \( -name '*.pem' -o -name '*.key' -o -name '.env' -o -name '*.sql' -o -name '*.tar.gz' \)
```

如果你后续要补充文档模板，可以写“变量名”和“文件路径”，但不要写真实值。

## 19. 当前仓库中的历史遗留说明

- `nginx_docker_old/` 是旧方案残留，且已被 `.gitignore` 忽略，不是当前现网配置来源。
- `www_old_backup/` 是旧静态站备份，不参与当前线上服务。

## 20. 建议的迁移顺序

如果要把现网迁到新服务器或新域名，建议严格按这个顺序：

1. 新服务器安装系统依赖
2. 创建 swap 并完成基础系统优化
3. 拉取仓库并准备目录
4. 创建 `/opt/bitfsae` 并复制 `.output/`、`ecosystem.config.cjs`
5. 写入 `/opt/bitfsae/.env`
6. 修改 `docker-compose.yml` 中与域名相关的 Grafana 配置
7. 启动 Docker 遥测与监控容器
8. 启动 PM2 并保存进程列表
9. 写入并启用 Nginx 配置
10. 检查 DNS 的 `A/AAAA`
11. 执行首次证书签发
12. 如需接 EdgeOne，先验证源站，再开启代理与缓存规则
13. 安装 cron 自动续签
14. 配置 PM2 开机自启
15. 完成整站验收后再正式切流

这个顺序的核心目的是：先让服务在新机器上完整跑起来，再签证书，最后再切换用户流量。这样问题定位最清晰，回滚也最容易。
