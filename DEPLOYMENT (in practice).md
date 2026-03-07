# BITFSAE 线上部署手册（按当前服务器实况）

本文档基于当前线上机器实际运行状态整理，可直接作为运维基线。

## 1. 当前线上拓扑（实况）

- 入口层：宿主机 `nginx`（`80/443`）
- Web 应用：宿主机 `pm2` 管理的 `bitfsae` 进程，监听 `127.0.0.1:3000`
- 遥测与监控：`docker compose` 运行
  - `mosquitto`
  - `influxdb`
  - `telegraf`
  - `grafana`（`127.0.0.1:3001->3000`）
- Nginx 路由：
  - `/` -> `127.0.0.1:3000`（Nuxt/Node）
  - `/monitor/` -> `127.0.0.1:3001`（Grafana）

## 2. 配置与文件基线

### 2.1 生效配置位置（宿主机）

- Nginx 站点配置：`/etc/nginx/sites-available/bitfsae`
- Nginx 证书路径：
  - `/etc/nginx/ssl/bitfsae.xin.pem`
  - `/etc/nginx/ssl/bitfsae.xin.key`
- 当前证书签发方：Let's Encrypt（`CN=E7`）
- 当前证书到期：`2026-06-05`
- PM2 进程：`bitfsae`

### 2.2 本仓库作用

- `docker-compose.yml`：仅管理遥测/监控容器
- `scripts/ssl_auto_renew.sh`：证书申请与续签脚本（已适配宿主机 nginx）
- `nginx_docker_old/`：历史遗留（已在 `.gitignore` 忽略，不作为线上配置）
- `www_old_backup/`：历史备份（已忽略）

## 3. 服务检查与日常命令

```bash
# 遥测容器状态
docker compose ps

# 某容器日志
docker compose logs -f grafana

# PM2 状态
pm2 ls
pm2 logs bitfsae

# Nginx 状态
systemctl status nginx --no-pager
```

## 4. Nginx 生效配置（当前）

以下为当前生效配置结构（重点是 ACME 挑战路径与反向代理）：

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
    server_name bitfsae.xin www.bitfsae.xin;

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
    server_name bitfsae.xin www.bitfsae.xin;

    ssl_certificate     /etc/nginx/ssl/bitfsae.xin.pem;
    ssl_certificate_key /etc/nginx/ssl/bitfsae.xin.key;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        proxy_pass http://nuxt_app;
    }

    location /monitor/ {
        proxy_pass http://grafana_app;
    }
}
```

修改 Nginx 后固定流程：

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 5. SSL 自动申请与续签

### 5.1 脚本位置

- `/home/admin/fsae_project/scripts/ssl_auto_renew.sh`

### 5.2 脚本默认行为

- 使用 Docker 镜像 `certbot/certbot:latest`
- Let's Encrypt 数据目录：`/etc/letsencrypt`
- HTTP-01 验证目录：`/var/www/certbot`
- 证书输出目录：`/etc/nginx/ssl`
- 同步结果：
  - `/etc/nginx/ssl/bitfsae.xin.pem`
  - `/etc/nginx/ssl/bitfsae.xin.key`
- 成功后自动执行 `systemctl reload nginx`

### 5.3 首次申请（手动）

```bash
sudo LETSENCRYPT_EMAIL=ops@bitfsae.xin /home/admin/fsae_project/scripts/ssl_auto_renew.sh
```

也可把 `LETSENCRYPT_EMAIL` 放在 `/opt/bitfsae/.env`。

### 5.4 定时续签（已配置）

系统级 cron 文件：`/etc/cron.d/bitfsae-ssl-renew`

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /bin/bash -lc 'set -a; [ -f /opt/bitfsae/.env ] && . /opt/bitfsae/.env; set +a; /home/admin/fsae_project/scripts/ssl_auto_renew.sh >> /var/log/bitfsae-ssl-renew.log 2>&1'
```

续签日志：`/var/log/bitfsae-ssl-renew.log`

## 6. 发布与更新建议流程

### 6.1 遥测链路（Docker）

```bash
cd /home/admin/fsae_project
docker compose pull
docker compose up -d
docker compose ps
```

### 6.2 Web 应用（PM2）

Web 应用不是本仓库内通过 compose 启动的，按当前服务器 PM2 流程更新并重启：

```bash
pm2 reload bitfsae
pm2 save
```

## 7. 故障排查

### 7.1 HTTPS 证书问题

```bash
# 看证书文件时间
ls -l /etc/nginx/ssl/bitfsae.xin.pem /etc/nginx/ssl/bitfsae.xin.key

# 看续签日志
tail -n 200 /var/log/bitfsae-ssl-renew.log

# 手动跑一遍脚本
sudo /home/admin/fsae_project/scripts/ssl_auto_renew.sh
```

### 7.2 Nginx 无法重载

```bash
sudo nginx -t
sudo journalctl -u nginx -n 200 --no-pager
```

### 7.3 Grafana 404 或空白

```bash
docker compose ps
docker compose logs -f grafana
```

## 8. 重要说明

- `nginx_docker_old/` 为旧方案残留，不要再作为线上配置来源。
- 线上真实配置以 `/etc/nginx/sites-available/bitfsae` 与 `pm2 ls` 为准。
- `influxdb_1.8_data/`、`grafana_data/`、`mosquitto/data/` 等运行数据目录建议定期备份。
