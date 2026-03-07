# Protobuf 协议维护指南

本项目的通信核心定义在 `D:\Protobuf\server_config\protos` 目录下的 `.proto` 文件中。
为了保证服务器端（Telegraf -> InfluxDB）的数据解析正常，**请严格遵守以下规范进行修改**。

## 1. 核心文件

*   `fsae_telemetry.proto`: 定义数据结构（Message）。
*   `fsae_telemetry.options`: 定义 Nanopb（STM32使用）的特定选项，如数组最大长度。

## 2. 修改规范 (CRITICAL)

服务器端的 Telegraf 配置文件 (`telegraf.conf`) 使用了 XPath 来提取 Protobuf 数据。这意味着：

1.  **禁止修改现有字段的名称和类型**：
    *   例如：`uint32 module_id = 1;` 中的 `module_id` 被写入在 `telegraf.conf` 中。如果你把它改名为 `id`，服务器将无法解析该字段，数据会丢失。
    *   如果必须修改，你**必须**同步修改服务器上 `telegraf.conf` 中的 `xpath` 映射，并重启 Telegraf 容器。

2.  **禁止修改现有字段的 ID**：
    *   Protobuf 依赖 ID (`= 1`, `= 2`) 来序列化。修改 ID 会导致新旧版本不兼容。

3.  **新增字段**：
    *   可以直接在 Message 末尾添加新字段，使用新的 ID。
    *   例如：`float tire_pressure = 40;`
    *   **注意**：新增字段后，如果能在服务器数据库看到它，还需要手动修改服务器的 `telegraf.conf`，添加对应的 XML Path 映射。否则服务器只会忽略这个新数据，虽然不会报错。

4.  **数组长度控制**：
    *   如果有 `repeated` 字段，必须在 `fsae_telemetry.options` 中指定 `max_count`。这是为了让 STM32 (C语言) 能够静态分配内存。

## 3. 现有结构参考

**fsae_telemetry.proto:**

```protobuf
syntax = "proto3";
package fsae;

message BatteryModule {
    uint32 module_id = 1;
    // 23 节电芯电压
    uint32 v01 = 2;
    ...
    // 8 个温度
    sint32 t1 = 30;
    ...
}

message TelemetryFrame {
    // 基础信息
    uint32 timestamp_ms = 1;
    uint32 frame_id = 2;
    
    // 驾驶员输入
    float apps_position = 3;
    ...
    
    // BMS 详细数据
    repeated BatteryModule modules = 15;
}
```

**fsae_telemetry.options (Nanopb):**

```plaintext
fsae.TelemetryFrame.modules    max_count:6
```

## 4. 常见操作流程

### 场景：我想加一个“胎压”数据

1.  **修改 Proto**: 在 `fsae_telemetry.proto` 的 `TelemetryFrame` 中添加：
    ```protobuf
    float tire_pressure_fl = 20; // Front Left
    ```
2.  **生成代码**:
    *   **Python (本地模拟)**: 运行 `protoc --python_out=. fsae_telemetry.proto`
    *   **STM32 (车载)**: 运行 Nanopb 生成器，更新 STM32 工程中的 `.c/.h` 文件。
3.  **修改服务器配置 (重要)**:
    *   登录服务器，编辑 `server_config/telegraf/telegraf.conf`。
    *   在 `[[inputs.mqtt_consumer.xpath.fields]]` 下添加：
        ```toml
        tire_pressure_fl = "number(//tire_pressure_fl)"
        ```
    *   重启 Telegraf: `docker-compose restart telegraf`
