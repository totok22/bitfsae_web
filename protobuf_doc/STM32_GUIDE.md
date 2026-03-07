# STM32 车载发送端开发指南

负责这一部分的同学，请仔细阅读。

我们的遥测系统使用 **Google Protobuf** 协议对数据进行序列化，但在单片机（STM32）上，我们使用 **Nanopb** 这个轻量级库。

## 1. 文件位置

你需要关注的文件在当前仓库的 `protos/` 目录下：
*   `fsae_telemetry.proto`: 数据定义
*   `fsae_telemetry.options`: Nanopb 配置文件（定义了数组最大长度等）

## 2. 如何生成 STM32 代码

你需要使用 Nanopb 提供的生成器脚本，将上述两个文件转换为 C 代码 (`.c` 和 `.h`)。

### 准备环境
确保你下载了 [Nanopb](https://jpa.kapsi.fi/nanopb/) (通常是 `nanopb-0.x.x-windows.zip`)，解压后将其 `generator-bin` 目录加入 PATH，或者直接调用其中的 `nanopb_generator`。

### 生成命令
在 `protos` 目录下运行命令行：

```bash
# 假设你已经安装了 nanopb_generator
nanopb_generator fsae_telemetry.proto
```

或者使用 Python 运行（如果你有 Python 环境和 protobuf 库）：

```bash
python path/to/nanopb/generator/nanopb_generator.py fsae_telemetry.proto
```

### 产物
执行成功后，你会得到：
*   `fsae_telemetry.pb.c`
*   `fsae_telemetry.pb.h`

**请将这两个文件复制到你的 STM32 工程中，替换旧文件。**

## 3. 工程依赖

除了上述生成的两个文件，你的 STM32 工程还需要 Nanopb 的核心库文件（这些文件一般不需要更新，除非升级 Nanopb 版本）：
*   `pb.h`
*   `pb_common.c`
*   `pb_common.h`
*   `pb_encode.c`
*   `pb_encode.h`
*   `pb_decode.c` (如果车上也需要接收指令，则需要这个；如果只发送，可以不需要)
*   `pb_decode.h`

## 4. 编程注意事项 (Critical)

1.  **数组长度**:
    在 `.proto` 中定义的 `repeated` 字段（如 `modules`），在 C 语言中会被生成为结构体数组。
    Nanopb 会使用 `.options` 文件中的 `max_count` 来静态分配内存。
    *   例如：`fsae.TelemetryFrame.modules max_count:6`
    *   代码中必须设置 `frame.modules_count` 来告诉编码器实际有多少个有效数据。
    ```c
    TelemetryFrame frame = TelemetryFrame_init_zero;
    frame.modules_count = 6; // 必须设置！不能超过 6
    ```

2.  **字符串**:
    如果有 string 类型，Nanopb 也会生成 `char array[SIZE]`。同样需要在 `.options` 中指定 `max_size`。目前我们的定义里似乎没有 string，主要是数值。

3.  **不要手动修改生成的 .c/.h**:
    每次 `.proto` 更新，都应该重新生成，而不是手动去改 C 代码，否则下次更新会被覆盖。

## 5. 示例代码片段

```c
#include "pb_encode.h"
#include "fsae_telemetry.pb.h"

void send_telemetry() {
    uint8_t buffer[512];
    TelemetryFrame message = TelemetryFrame_init_zero;

    // 1. 填充数据
    message.timestamp_ms = HAL_GetTick();
    message.frame_id = frame_counter++;
    message.apps_position = get_apps_pedal(); // float
    message.motor_rpm = get_motor_rpm();      // int32
    
    // ... 填充其他 ...

    // 2. 序列化
    pb_ostream_t stream = pb_ostream_from_buffer(buffer, sizeof(buffer));
    bool status = pb_encode(&stream, TelemetryFrame_fields, &message);

    if (!status) {
        // encoding failed
        printf("Encoding failed: %s\n", PB_GET_ERROR(&stream));
        return;
    }

    // 3. 发送 (buffer, stream.bytes_written)
    mqtt_publish("fsae/telemetry", buffer, stream.bytes_written);
}
```
