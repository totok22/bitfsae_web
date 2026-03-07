# BITFSAE 线上遥测与部署仓库

本仓库用于维护 BITFSAE 线上环境相关的遥测链路、监控服务、证书续签脚本、服务器部署说明，以及 protobuf 协议与常用运维配置。

相关 Web/Nuxt 项目仓库：

- 公开仓库：`https://github.com/totok22/BITFSAE-team-portal`
- 车队自用仓库：`https://github.com/totok22/bitfsae-nuxt`
- 两个仓库当前代码保持一致

## 架构

- 宿主机 `nginx` 负责 `80/443` 入口与 TLS。
- 宿主机 `pm2` 运行站点服务（`bitfsae`，监听 `127.0.0.1:3000`）。
- `docker compose` 仅运行遥测与监控相关服务：
   - `mosquitto`
   - `influxdb`
   - `telegraf`
   - `grafana`（映射 `127.0.0.1:3001->3000`）
- Nginx 通过 `/monitor/` 反代到 Grafana。
- Web 运行目录位于服务器本地 `/opt/bitfsae`，不在本仓库内。

## 仓库目录说明

- `docker-compose.yml`: 遥测/监控容器编排（不包含现网 Web 容器）。
- `mosquitto/`, `telegraf/`, `protos/`: MQTT 接入、Telegraf 解析与 protobuf 协议定义等数据链路配置。
- `scripts/ssl_auto_renew.sh`: Let's Encrypt 自动申请/续签脚本（当前已适配宿主机 Nginx）。
- `DEPLOYMENT (server).md`: 当前线上架构对应的新服务器部署与域名迁移手册。

## 新服务器部署

如果要把系统迁到一台全新服务器，或更换到新的域名后缀，例如 `.site`，请参考 `DEPLOYMENT (server).md`。

## 日常运维命令

```bash
# 遥测容器状态
docker compose ps

# 查看某个容器日志
docker compose logs -f grafana

# PM2 站点状态
pm2 ls

# Nginx 状态
systemctl status nginx --no-pager
```

## TLS 证书自动续签

### 现网证书路径

- `/etc/nginx/ssl/bitfsae.xin.pem`
- `/etc/nginx/ssl/bitfsae.xin.key`
- 当前签发方：Let's Encrypt（`issuer=CN=E7`）
- 当前到期时间：`2026-06-05`

### 首次申请 / 手动执行一次

`ssl_auto_renew.sh` 使用 Docker 版 Certbot，默认会：

1. 读写 `/etc/letsencrypt`
2. 使用 `webroot=/var/www/certbot` 完成 HTTP-01 验证
3. 同步证书到 `/etc/nginx/ssl/`
4. 执行 `systemctl reload nginx`

示例（邮箱可放到 `/opt/bitfsae/.env` 的 `LETSENCRYPT_EMAIL`）：

```bash
sudo LETSENCRYPT_EMAIL=ops@bitfsae.xin /home/admin/fsae_project/scripts/ssl_auto_renew.sh
```

### 定时任务

- 文件：`/etc/cron.d/bitfsae-ssl-renew`
- 计划：每天 `03:17`
- 日志：`/var/log/bitfsae-ssl-renew.log`

## Nginx 关键配置

现网虚拟主机在 `/etc/nginx/sites-available/bitfsae`，HTTP/HTTPS 两个 server 块都已放行 ACME 挑战路径：

```nginx
location ^~ /.well-known/acme-challenge/ {
      root /var/www/certbot;
      default_type "text/plain";
      try_files $uri =404;
}
```

## 注意事项

- 若改动了 `/etc/nginx/sites-available/bitfsae`，务必先执行 `nginx -t` 再 reload。
- 本仓库中 `*_data/` 目录是运行数据，默认被 `.gitignore` 忽略，建议定期做离机备份。
- 当前仓库是公开仓库，不要提交真实证书、私钥、服务器 `.env`、数据库导出或任何第三方平台密钥。