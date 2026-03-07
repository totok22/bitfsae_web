# Protobuf 协议维护指南

本项目的协议定义在仓库根目录的 `protos/` 下。只要改了 `.proto`，就要同时考虑三端是否需要同步：

1. Python 本地模拟脚本
2. STM32 车载发送端（Nanopb 生成代码）
3. 服务器侧 Telegraf 的 Protobuf 映射

## 1. 核心文件

- `protos/fsae_telemetry.proto`：协议结构定义
- `protos/fsae_telemetry.options`：Nanopb 选项，目前只约束 `modules` 的最大数量
- `telegraf/telegraf.conf`：服务器侧字段提取规则
- `protobuf_doc/local_sim2.py`：本地模拟发送脚本

## 2. 修改规则

### 2.1 不要改已有字段的编号

像 `timestamp_ms = 1`、`modules = 15` 这种字段编号一旦投入使用，就不要再改。

原因：Protobuf 编解码依赖字段编号，不依赖字段顺序。改编号会直接破坏新旧兼容。

### 2.2 不要随意改已有字段名或类型

当前服务器使用 `telegraf/telegraf.conf` 里的 `xpath_protobuf` 配置按字段名取值。

这意味着：

- 改字段名，Telegraf 的 XPath 映射就会失效
- 改字段类型，Telegraf 对应的 `fields` 或 `fields_int` 也可能要一起改

例如：

- `motor_rpm` 目前在 `fields_int` 中提取
- `hv_voltage` 目前在 `fields` 中通过 `number(...)` 提取

如果必须改名或改类型，必须同步修改 `telegraf/telegraf.conf`，然后重启 Telegraf 容器。

### 2.3 新增字段只能追加，不能复用旧编号

新增字段时：

- 在对应 message 末尾追加
- 使用从未使用过的新编号
- 不要占用保留给旧字段的编号

### 2.4 `repeated` 字段要同步更新 `.options`

当前协议里：

```text
fsae.TelemetryFrame.modules    max_count:6
```

## 3. 服务器侧的真实解析方式

当前服务器不是只解析一个 topic，而是两条独立链路：

- `fsae/telemetry`：基础遥测字段
- `fsae/bms`：从同一个 `TelemetryFrame` 里提取 `modules`

### 3.1 基础遥测 topic

Topic：`fsae/telemetry`

主要映射位置：

- `[[inputs.mqtt_consumer]]` 第一段
- `[inputs.mqtt_consumer.xpath.fields_int]`
- `[inputs.mqtt_consumer.xpath.fields]`

适用于这些字段：

- `timestamp_ms`
- `frame_id`
- `apps_position`
- `brake_pressure`
- `steering_angle`
- `hv_voltage`
- `hv_current`
- `battery_temp_max`
- `fault_code`
- `motor_rpm`
- `motor_temp`
- `inverter_temp`
- `ready_to_drive`
- `vcu_status`

### 3.2 BMS topic

Topic：`fsae/bms`

主要映射位置：

- `[[inputs.mqtt_consumer]]` 第二段
- `metric_selection = "//modules"`
- `[inputs.mqtt_consumer.xpath.tags]`
- `[inputs.mqtt_consumer.xpath.fields_int]`

这里当前提取的是每个 `BatteryModule` 的：

- `module_id`
- `v01` 到 `v23`
- `t1` 到 `t8`

因此：

- 如果你给 `TelemetryFrame` 新增基础字段，改第一段映射
- 如果你给 `BatteryModule` 新增字段，改第二段映射

## 4. 推荐操作流程

### 场景：给 `TelemetryFrame` 新增一个基础字段

例如新增：

```protobuf
float tire_pressure_fl = 16;
```

建议顺序：

1. 修改 `protos/fsae_telemetry.proto`
2. 重新生成 Python 用的 `fsae_telemetry_pb2.py`
3. 重新生成 STM32 的 `.pb.c/.pb.h`
4. 修改 `telegraf/telegraf.conf` 第一段映射
5. 重启 Telegraf：`docker compose restart telegraf`

Telegraf 中应补一行：

```toml
tire_pressure_fl = "number(//tire_pressure_fl)"
```

### 场景：给 `BatteryModule` 新增一个字段

例如新增：

```protobuf
uint32 balance_state = 38;
```

建议顺序：

1. 修改 `protos/fsae_telemetry.proto`
2. 如果 STM32 会发送这个字段，重新生成 Nanopb 代码
3. 如果本地模拟脚本也要发这个字段，重新生成 Python 文件并更新脚本赋值逻辑
4. 修改 `telegraf/telegraf.conf` 第二段 BMS 映射
5. 重启 Telegraf

例如新增整数字段时，可在第二段里增加：

```toml
balance_state = "balance_state"
```

## 5. 生成命令

### 5.1 Python 本地模拟

在 `protobuf_doc/` 目录下运行：

```bash
protoc --proto_path=../protos --python_out=. ../protos/fsae_telemetry.proto
```

执行后，`protobuf_doc/` 下应出现或更新：

- `fsae_telemetry_pb2.py`

### 5.2 STM32 / Nanopb

在 `protos/` 目录下运行 Nanopb 生成器，确保它能同时读取：

- `fsae_telemetry.proto`
- 同目录下的 `fsae_telemetry.options`

## 6. 修改完成后的最小检查项

每次改完协议，至少检查这四件事：

1. 新字段编号是否唯一
2. 本地模拟或 STM32 是否真的开始发送这个字段
3. `telegraf/telegraf.conf` 是否已补映射
4. `docker compose restart telegraf` 后 InfluxDB 是否出现新字段
