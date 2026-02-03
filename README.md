# BITFSAE Web & Telemetry System

北京理工大学纯电动方程式赛车队（BITFSAE）的官方网站和遥测监控系统。

## 项目概述

本项目是一个完整的FSAE电动赛车遥测系统，集成了数据采集、可视化监控和官方网站。系统使用现代容器化技术部署，提供实时车辆遥测数据的收集、存储和可视化展示。

## 架构组件

### 1. MQTT Broker (Mosquitto)
- **端口**: 1883 (MQTT), 9001 (WebSocket)
- **用途**: 接收来自赛车的数据包
- **配置**: `mosquitto/config/mosquitto.conf`

### 2. 时序数据库 (InfluxDB 1.8)
- **端口**: 8086
- **数据库**: fsae_db
- **用途**: 存储遥测数据

### 3. 数据收集器 (Telegraf)
- **配置**: `telegraf/telegraf.conf`
- **功能**:
  - 从MQTT订阅遥测数据
  - 解析Protobuf格式的数据
  - 将数据写入InfluxDB

### 4. 可视化平台 (Grafana)
- **端口**: 内部3000，通过Nginx反向代理访问
- **访问路径**: `https://bitfsae.xin/monitor/`
- **用途**: 实时监控车辆状态、电池数据等

### 5. Web服务器 (Nginx)
- **端口**: 80 (HTTP), 443 (HTTPS)
- **功能**:
  - 服务赛车队官方网站
  - 反向代理Grafana监控界面
  - SSL证书配置

### 6. 官方网站
- **技术栈**: Vue.js (前端SPA)
- **内容**: 车队介绍、赛事历史、赞助商、新闻等
- **路径**: `/`

## 数据格式

遥测数据使用Protocol Buffers定义，包含以下主要字段：

### TelemetryFrame
- **基础信息**: 时间戳、帧ID
- **驾驶员输入**: 油门位置、刹车压力、转向角度
- **高压系统**: 电压、电流、电池温度、故障码
- **动力系统**: 电机转速、电机温度、逆变器温度
- **车辆状态**: Ready-to-Drive状态、VCU状态
- **BMS数据**: 电池模块详细信息（23个电芯电压，8个温度传感器）

## 快速开始

### 前置要求
- Docker & Docker Compose
- SSL证书（放置在 `nginx/cert/` 目录）

### 部署步骤

1. **克隆仓库**
   ```bash
   git clone https://github.com/totok22/bitfsae_web.git
   cd bitfsae_web
   ```

2. **启动服务**
   ```bash
   docker-compose up -d
   ```

3. **访问网站**
   - 官方网站: `https://bitfsae.xin/`
   - 监控仪表板: `https://bitfsae.xin/monitor/`

### 服务管理

```bash
# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f [service_name]

# 停止服务
docker-compose down

# 重启特定服务
docker-compose restart [service_name]
```

## 配置说明

### 环境变量
- `GF_SERVER_DOMAIN`: Grafana域名
- `GF_SERVER_ROOT_URL`: Grafana根URL
- `GF_DASHBOARDS_MIN_REFRESH_INTERVAL`: 仪表板最小刷新间隔

### 数据流
1. 赛车通过MQTT发布Protobuf编码的遥测数据
2. Telegraf订阅MQTT主题，解析数据
3. 数据存储到InfluxDB
4. Grafana从InfluxDB查询数据进行可视化

### MQTT主题
- `fsae/telemetry`: 主要遥测数据
- `fsae/bms`: 电池管理系统数据

## 开发说明

### 本地开发
```bash
# 修改配置后重新构建
docker-compose up --build
```

### 数据备份
重要数据目录已通过 `.gitignore` 排除，但建议定期备份：
- `influxdb_1.8_data/`: 数据库数据
- `grafana_data/`: 仪表板配置
- `mosquitto/data/`: MQTT持久化数据

## 贡献

欢迎提交Issue和Pull Request！

## 许可证

[待定]

## 联系我们

北京理工大学纯电动方程式赛车队
- 网站: https://bitfsae.xin/
- 邮箱: [team_email]