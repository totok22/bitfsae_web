# 本地模拟与测试指南

`protobuf_doc/local_sim2.py` 用来验证服务器链路是否正常，作用是向 MQTT 连续发送两类数据：

- `fsae/telemetry`：10Hz 基础遥测
- `fsae/bms`：2Hz BMS 模组数据

## 1. 运行前提

需要的 Python 依赖：

```bash
pip install paho-mqtt protobuf
```

还需要一个由 `.proto` 生成的 Python 文件：

- `protobuf_doc/fsae_telemetry_pb2.py`

注意：`local_sim2.py` 直接 `import fsae_telemetry_pb2 as pb`，所以这个生成文件默认要放在 `protobuf_doc/` 目录下，和脚本同级。

如果没有这个文件，在 `protobuf_doc/` 目录执行：

```bash
protoc --proto_path=../protos --python_out=. ../protos/fsae_telemetry.proto
```

## 2. 脚本当前行为

### 2.1 基础遥测

脚本会构造一个 `TelemetryFrame`，并发送到 `fsae/telemetry`，包含这些主要字段：

- `timestamp_ms`
- `frame_id`
- `apps_position`
- `brake_pressure`
- `steering_angle`
- `motor_rpm`
- `hv_voltage`
- `hv_current`
- `motor_temp`
- `inverter_temp`
- `ready_to_drive`
- `vcu_status`

### 2.2 BMS 数据

脚本会单独构造另一个 `TelemetryFrame`，只填充 `modules`，并发送到 `fsae/bms`。

每个 `module` 当前包含：

- `module_id`
- `v01` 到 `v23`
- `t1` 到 `t8`

这和服务器里的第二段 `mqtt_consumer` 映射是一一对应的。

## 3. 配置项

脚本顶部可以修改这些参数：

```python
SERVER_IP = "123.57.174.98"
SERVER_PORT = 1883
TOPIC_TELEMETRY = "fsae/telemetry"
TOPIC_BMS = "fsae/bms"
BASE_FREQ = 10.0
BMS_DIVIDER = 5
```

含义：

- `BASE_FREQ = 10.0` 表示主循环 10Hz
- `BMS_DIVIDER = 5` 表示每 5 次主循环发一次 BMS，所以 BMS 频率是 2Hz

## 4. 推荐运行方式

在 `protobuf_doc/` 目录下运行：

```bash
python local_sim2.py
```

启动后如果连接成功，终端会打印：

- MQTT 连接信息
- 当前发送频率
- 每 10 帧一次的基础日志
- 每次发送 BMS 时的提示

## 5. 改了 `.proto` 以后这里要做什么

如果你修改了 `protos/fsae_telemetry.proto`，本地模拟至少要检查两件事：

1. 重新生成 `protobuf_doc/fsae_telemetry_pb2.py`
2. 如果新增字段需要被模拟发送，修改 `local_sim2.py` 的赋值逻辑

只改 `.proto` 不重新生成 `fsae_telemetry_pb2.py`，脚本通常会直接导入失败，或者发送的数据结构还是旧版本。

## 6. 常见问题

### 6.1 `ModuleNotFoundError: No module named 'fsae_telemetry_pb2'`

原因通常是还没生成 Python 代码，或者生成到了错误目录。

正确做法：在 `protobuf_doc/` 目录重新执行：

```bash
protoc --proto_path=../protos --python_out=. ../protos/fsae_telemetry.proto
```

### 6.2 能运行但服务器没数据

优先检查：

1. `SERVER_IP` 和端口是否正确
2. 云服务器 1883 端口是否开放
3. Telegraf 是否正在订阅 `fsae/telemetry` 和 `fsae/bms`
4. 如果刚改过 `.proto`，`telegraf/telegraf.conf` 是否同步改过

### 6.3 改了脚本字段但 Grafana 还是没有新曲线

这通常不是脚本问题，而是服务器侧没补 Telegraf 映射。新增字段后还要改 `telegraf/telegraf.conf` 并重启 Telegraf。
