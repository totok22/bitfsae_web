# STM32 车载发送端开发指南

STM32 侧使用的是 Nanopb，而不是标准 Protobuf 全量运行时。协议更新以后，STM32 端必须重新生成 `.pb.c/.pb.h`，不能只改 `.proto` 就结束。

## 1. 你需要关注的文件

仓库中和 STM32 生成直接相关的文件只有两个：

- `protos/fsae_telemetry.proto`
- `protos/fsae_telemetry.options`

其中：

- `.proto` 定义字段和 message 结构
- `.options` 控制 Nanopb 的静态内存分配方式

当前已配置的关键项是：

```text
fsae.TelemetryFrame.modules    max_count:6
```

这表示生成后的 C 结构体会为 `modules` 预留 6 个元素的空间。

## 2. 生成代码时的关键点

Nanopb 生成器必须在能同时看到这两个文件的目录下执行，最稳妥的方式就是直接进入 `protos/` 目录再生成。

推荐做法：

```bash
cd protos
nanopb_generator fsae_telemetry.proto
```

如果你使用 Python 方式调用，也建议在 `protos/` 目录内执行：

```bash
cd protos
python path/to/nanopb/generator/nanopb_generator.py fsae_telemetry.proto
```

这样生成器会自动读取同目录下的 `fsae_telemetry.options`。

## 3. 生成产物

执行成功后，会得到：

- `fsae_telemetry.pb.c`
- `fsae_telemetry.pb.h`

把这两个文件复制进 STM32 工程，替换旧版本。

不要手改这两个生成文件。下一次协议更新重新生成即可。

## 4. STM32 工程还需要哪些 Nanopb 文件

除了上面的协议生成文件，工程里还应包含 Nanopb 核心库：

- `pb.h`
- `pb_common.c`
- `pb_common.h`
- `pb_encode.c`
- `pb_encode.h`
- `pb_decode.c`
- `pb_decode.h`

如果车端只负责发送，通常实际编码路径只依赖 `pb_encode.*` 和 `pb_common.*`，但很多工程会把整套文件一起保留，便于后续扩展。

## 5. 当前协议下最容易踩的坑

### 5.1 `repeated` 字段要设置 `_count`

`TelemetryFrame.modules` 是 `repeated BatteryModule`，Nanopb 会生成数组和计数字段。

这意味着编码前必须设置：

```c
TelemetryFrame frame = TelemetryFrame_init_zero;
frame.modules_count = 6;
```

如果不设置 `modules_count`，即使你给数组元素赋了值，编码结果里也不会带上这些模块数据。

### 5.2 `modules_count` 不能超过 `.options` 里的上限

当前上限是 6，所以：

```c
frame.modules_count <= 6
```

如果以后电池模组数增加，必须先改：

1. `protos/fsae_telemetry.options`
2. 重新生成 `.pb.c/.pb.h`
3. 再修改 STM32 发送代码

### 5.3 改了 `.proto` 后不要继续沿用旧头文件

这是最常见问题之一。`.proto` 已更新，但 STM32 工程里还在用旧的 `fsae_telemetry.pb.h`，结果表现为：

- 编译阶段字段不存在
- 或者编码结构和服务器预期不一致

## 6. 发送主题约定

当前服务器按两个 MQTT topic 解析数据：

- `fsae/telemetry`：基础遥测
- `fsae/bms`：BMS 模组数据

如果 STM32 未来也要像本地模拟脚本一样拆成两路发送，需要确保：

- 基础字段发送到 `fsae/telemetry`
- `modules` 数据发送到 `fsae/bms`

否则服务器虽然能收到 MQTT，但现有 Telegraf 配置未必会按预期入库。

## 7. 示例代码

```c
#include "pb_encode.h"
#include "fsae_telemetry.pb.h"

void send_telemetry(void)
{
    uint8_t buffer[512];
    TelemetryFrame message = TelemetryFrame_init_zero;

    message.timestamp_ms = HAL_GetTick();
    message.frame_id = frame_counter++;
    message.apps_position = get_apps_pedal();
    message.motor_rpm = get_motor_rpm();

    pb_ostream_t stream = pb_ostream_from_buffer(buffer, sizeof(buffer));
    bool ok = pb_encode(&stream, TelemetryFrame_fields, &message);

    if (!ok) {
        printf("Encoding failed: %s\n", PB_GET_ERROR(&stream));
        return;
    }

    mqtt_publish("fsae/telemetry", buffer, stream.bytes_written);
}
```

如果要发送 BMS 数据，同样是编码 `TelemetryFrame`，但要填充 `modules` 和 `modules_count`，然后发布到 `fsae/bms`。
