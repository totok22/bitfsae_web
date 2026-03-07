# 本地模拟与测试指南 (local_sim2.py)

`local_sim2.py` 是一个用于测试服务器数据接收链路的 Python 脚本。它模拟赛车发送遥测数据（Telemetry）和电池管理系统数据（BMS）到 MQTT 服务器。

## 1. 环境准备

确保你已经安装了 Python 以及必要的依赖库。

```bash
pip install paho-mqtt protobuf
```

注意：你需要确保当前目录下有 `fsae_telemetry_pb2.py`文件。这个文件是由 `protoc` 编译器根据 `.proto` 文件生成的。如果缺失，请参考 `PROTO_GUIDE.md` 进行生成。

## 2. 脚本功能

这个脚本的主要功能是：
1.  **连接 MQTT 服务器**：连接到配置的公网 IP 和端口。
2.  **模拟物理数据**：模拟车辆的加速、刹车、滑行状态，并生成相应的 RPM、电压、电流、温度等数据，使其看起来像真实的赛车数据（有物理惯性，不是纯随机）。
3.  **发送数据**：
    *   `fsae/telemetry` Topic: 发送 `TelemetryFrame`，包含车辆基本信息（10Hz）。
    *   `fsae/bms` Topic: 发送 BMS 详细数据（2Hz）。

## 3. 配置修改

在 `local_sim2.py` 的头部，你可以修改服务器配置：

```python
# ================= 配置区域 =================
# 阿里云服务器的公网 IP
SERVER_IP = "123.57.174.98"   # 修改为你实际的服务器 IP
SERVER_PORT = 1883
TOPIC_TELEMETRY = "fsae/telemetry"
TOPIC_BMS = "fsae/bms"
```

## 4. 运行模拟

直接在终端运行：

```bash
python local_sim2.py
```

## 5. 常见问题

*   **缺少模块错误**：如果提示 `ModuleNotFoundError: No module named 'fsae_telemetry_pb2'`，说明你还没生成 Python 的 Protobuf 库文件。请运行 `protoc --python_out=. fsae_telemetry.proto`（确保你安装了 protoc 编译器）。
*   **连接失败**：检查 `SERVER_IP` 是否正确，以及服务器的 1883 端口是否开放（防火墙/安全组）。
