import time
import random
import paho.mqtt.client as mqtt
import fsae_telemetry_pb2 as pb  # 导入刚才生成的库

# ================= 配置区域 =================
# 阿里云服务器的公网 IP
SERVER_IP = "123.57.174.98" 
SERVER_PORT = 1883
TOPIC_TELEMETRY = "fsae/telemetry"
TOPIC_BMS = "fsae/bms"

# 发送频率设置
BASE_FREQ = 10.0           # 基础频率 10Hz
LOOP_INTERVAL = 1.0 / BASE_FREQ 
BMS_DIVIDER = 5            # 10Hz / 5 = 2Hz

# ===========================================

# 1. 定义一个全局变量记录启动时间
import time
START_TIMESTAMP = time.time()

def get_current_time_ms():
    # 2. 修改这里：计算当前时间与启动时间的差值 (模拟单片机的 HAL_GetTick)
    diff = time.time() - START_TIMESTAMP
    return int(diff * 1000)

class CarSimulator:
    def __init__(self):
        # 初始化车辆状态 (用于模拟连续变化的数值)
        self.rpm = 0
        self.speed = 0
        self.apps = 0 # 油门
        self.brake = 0 # 刹车
        self.hv_voltage = 380.0
        self.hv_current = 0
        self.motor_temp = 40.0
        self.state = "IDLE" # IDLE, ACCEL, BRAKE, COAST
        self.frame_count = 0

    def update_physics(self):
        """模拟物理变化，让曲线看起来真实"""
        # 1. 随机切换驾驶状态
        if random.random() < 0.05: # 5%概率改变状态
            self.state = random.choice(["ACCEL", "BRAKE", "COAST", "ACCEL"])
        
        # 2. 根据状态更新数据
        if self.state == "ACCEL":
            self.apps = min(self.apps + 5, 100)
            self.brake = max(self.brake - 10, 0)
            self.rpm = min(self.rpm + 200 + random.randint(-50, 50), 12000)
            self.hv_current = (self.apps / 100) * 200 # 电流跟油门走
        
        elif self.state == "BRAKE":
            self.apps = max(self.apps - 10, 0)
            self.brake = min(self.brake + 10, 80)
            self.rpm = max(self.rpm - 400, 0)
            self.hv_current = -20 # 动能回收模拟
            
        elif self.state == "COAST":
            self.apps = max(self.apps - 5, 0)
            self.brake = 0
            self.rpm = max(self.rpm - 100, 0)
            self.hv_current = 5 # 待机电流

        # 3. 模拟温度缓慢上升
        if self.rpm > 5000:
            self.motor_temp += 0.05
        else:
            self.motor_temp = max(self.motor_temp - 0.02, 30)

        # 4. 电压随负载波动
        self.hv_voltage = 380.0 - (self.hv_current * 0.05) + random.uniform(-0.1, 0.1)

    def generate_telemetry_frame(self):
        """生成 10Hz 基础遥测数据"""
        self.update_physics()
        self.frame_count += 1

        frame = pb.TelemetryFrame()
        
        # --- 10Hz 数据填充 ---
        frame.timestamp_ms = get_current_time_ms()
        frame.frame_id = self.frame_count
        frame.apps_position = self.apps
        frame.brake_pressure = self.brake
        frame.steering_angle = random.uniform(-45, 45) # 转向角随机摆动
        frame.motor_rpm = int(self.rpm)
        frame.hv_voltage = self.hv_voltage
        frame.hv_current = self.hv_current
        frame.motor_temp = self.motor_temp
        frame.inverter_temp = self.motor_temp - 5
        frame.ready_to_drive = 1  
        frame.vcu_status = 1 if self.rpm > 0 else 0 # 模拟一下：有转速时 VCU 才算开启

        return frame

    def generate_bms_frame(self):
        """生成 BMS 数据 (2Hz) - 使用扁平化字段"""
        frame = pb.TelemetryFrame()
        frame.timestamp_ms = get_current_time_ms()
        
        # --- 填充 BMS 数据 ---
        for i in range(6):  # 循环 6 次，生成 6 个模组
            module = frame.modules.add()
            module.module_id = i + 1  # ID: 1, 2, 3, 4, 5, 6
            
            # 模拟电压基准
            base_vol = 4000 + (i * 10)
            
            # --- 新写法：循环赋值给 v01, v02... v23 ---
            for j in range(1, 24):
                # 生成电压值
                val = int(base_vol + random.randint(-15, 15))
                # 动态设置属性：module.v01 = val
                field_name = f"v{j:02d}"  # 生成 v01, v02...
                setattr(module, field_name, val)
            
            # --- 新写法：循环赋值给 t1... t8 ---
            for k in range(1, 9):
                temp = 350 + i*5 + random.randint(-5, 5)
                field_name = f"t{k}"  # 生成 t1, t2...
                setattr(module, field_name, temp)

        return frame

def main():
    print(f"Connecting to MQTT Broker: {SERVER_IP}:{SERVER_PORT}...")
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    
    try:
        client.connect(SERVER_IP, SERVER_PORT, 60)
        print("Connected! Starting simulation...")
        print(f"Base Freq: {BASE_FREQ}Hz | BMS Freq: {BASE_FREQ/BMS_DIVIDER}Hz")
    except Exception as e:
        print(f"Connection Failed: {e}")
        print("请检查：1. 服务器IP是否正确 2. 阿里云防火墙是否开放 1883 端口")
        return

    sim = CarSimulator()

    try:
        while True:
            start_time = time.time()

            # === 1. 发送 10Hz 基础遥测数据 ===
            frame_telemetry = sim.generate_telemetry_frame()
            
            # 发送到基础主题
            client.publish(TOPIC_TELEMETRY, frame_telemetry.SerializeToString())

            # === 2. 发送 2Hz BMS 数据 (独立发送) ===
            if sim.frame_count % BMS_DIVIDER == 0:
                frame_bms = sim.generate_bms_frame()
                
                # 发送到 BMS 专用主题
                client.publish(TOPIC_BMS, frame_bms.SerializeToString())
                print(f"Sent FLAT BMS Data @ {frame_bms.timestamp_ms}")

            # 打印日志 (每 10 帧打印一次，避免刷屏)
            if sim.frame_count % 10 == 0:
                print(f"ID: {frame_telemetry.frame_id:05d} | State: {sim.state:5s} | RPM: {frame_telemetry.motor_rpm:5d}")

            # 精确控制频率
            elapsed = time.time() - start_time
            sleep_time = max(0, LOOP_INTERVAL - elapsed)
            time.sleep(sleep_time)

    except KeyboardInterrupt:
        print("\nSimulation stopped.")
        client.disconnect()

if __name__ == "__main__":
    main()
