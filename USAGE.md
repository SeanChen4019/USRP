# USRP 无线多媒体传输演示平台 — 使用文档

## 环境要求

### 硬件

| 组件 | 数量 | 说明 |
|------|------|------|
| Ettus X310 USRP | 2 台 | 一台发送、一台接收 |
| 外部时钟源 | 1 个 | 两台 USRP 共享，保证同频同相 |
| 千兆网线 | 2 根 | PC 与 USRP 直连 |
| PC | 2 台 | Windows 10/11，安装 MATLAB 2025a |

### 软件

| 软件 | 版本 | 说明 |
|------|------|------|
| MATLAB | **2025a** | 开发与运行环境 |
| Communications Toolbox | 2025a | 调制解调、升余弦滤波、CRC |
| 5G Toolbox | 2025a | LDPC 编译码 (`ldpcQuasiCyclicMatrix` 等) |
| Communications Toolbox Support Package for USRP Radio | 2025a | USRP 硬件驱动 (`comm.SDRuTransmitter` 等) |
| Image Processing Toolbox | 2025a | 图像缩放 (`imresize`) |
| Parallel Computing Toolbox | 2025a | (可选) 后台 UI 数据发送，不影响主循环 |

### 安装附加工具

在 MATLAB 命令窗口运行：

```matlab
% 安装 USRP 硬件支持包
supportPackageInstaller

% 或通过命令行安装
matlab.addons.install('Communications Toolbox Support Package for USRP Radio')
```

在 MATLAB 附加功能管理器中确认以下已安装：
- **Communications Toolbox**
- **5G Toolbox**
- **Image Processing Toolbox**
- **Communications Toolbox Support Package for USRP Radio**

### USRP 网络配置

两台 PC 分别直连一台 X310，USRP 默认 IP 为 `192.168.10.2`。

**PC 端设置：**
- 控制面板 → 网络和共享中心 → 更改适配器设置
- 找到 USRP 连接的网络适配器
- IPv4 设置：`192.168.10.1`，子网掩码 `255.255.255.0`
- 关闭防火墙或添加 MATLAB 为例外

**验证连接：**
```matlab
% 在 MATLAB 中 ping USRP
!ping 192.168.10.2

% 或使用 USRP 查找工具
findsdru
```

## 项目文件部署

### 发射端 PC

```
工作目录/
├── 发射机/
│   ├── Transmitter_Main_UDPui0416.m
│   ├── Data_trans_sig_Gen.m
│   ├── Par_Rece_sig_Gen.m
│   ├── preprocess_image.m
│   ├── preprocess_video.m
│   ├── get_image_dims.m
│   ├── link_phy_defs.m
│   ├── p2.jpg          # 演示图片（必须）
│   └── 视频.mp4         # 演示视频（视频模式必须）
```

### 接收端 PC

```
工作目录/
├── 接收机/
│   ├── Receiver_main_UDPui0416.m
│   ├── Data_Rece_sig_Gen.m
│   ├── Par_trans_sig_Gen.m
│   ├── preprocess_image.m
│   ├── preprocess_video.m
│   ├── get_image_dims.m
│   ├── link_phy_defs.m
│   ├── snr_est.m
│   ├── decision_making.m
│   ├── p2.jpg          # 演示图片（图像模式必须，与 TX 相同文件）
│   └── 视频.mp4         # 演示视频（视频模式必须，与 TX 相同文件）
```

**重要：** 图像和视频模式下，TX 和 RX 必须使用**完全相同的** `p2.jpg` 和 `视频.mp4` 文件，否则 CRC 校验失败。

## 运行步骤

### 1. 选择传输模式

编辑发射端 `Transmitter_Main_UDPui0416.m` 第 35 行：

```matlab
TX_MODE = 1;  % 1=仅图像, 2=仅视频, 3=图像+视频, 4=文本
```

编辑接收端 `Receiver_main_UDPui0416.m` 第 28 行：

```matlab
RX_MODE = 1;  % 需与发射端一致
```

### 2. 启动接收端

在接收端 PC 的 MATLAB 中：

```matlab
cd 接收机
Receiver_main_UDPui0416
```

输出示例：
```
==================== 接收端（分块渐进式恢复）启动 ====================
[RX-INIT] 接收模式: 仅图像
[RX-INIT] 预存图片块数据...
[RX-INIT] 预存完成 | 图片 64块 | 视频 20帧
正在初始化 USRP 硬件，请稍候...
USRP 硬件初始化完成！
```

### 3. 启动发射端

在发射端 PC 的 MATLAB 中：

```matlab
cd 发射机
Transmitter_Main_UDPui0416
```

输出示例：
```
==================== 发射端（分块渐进式传输）启动 ====================
[TX-INIT] 发送模式: 仅图像
[TX-INIT] 预处理图片...
[TX-INIT] session=1 | 总块数=64 | CF=2.50 GHz | Gain=15 dB
```

### 4. 观察传输过程

发射端按 2 轮发送，每轮间有空闲帧。接收端实时显示恢复进度。

发射端完成输出：
```
[TX-ROUND] 完成第 2 轮发送
[TX-DONE] 全部 2 轮发送完成，停止发射
[TX] 传输结束，退出。
```

接收端超时后自动保存：
```
[RX-TIMEOUT] 连续 50 轮无新数据，自动结束恢复
[RX-SAVE] 图片已保存: .../recovered/recovered_image.jpg (62/64 块)
[RX-SAVE] 恢复文件输出至: .../recovered
```

## 各模式详解

### 模式 1 — 仅图像

```matlab
TX_MODE = 1;  RX_MODE = 1;
```

- 图片 `p2.jpg` 切分为 8×8=64 块
- 接收端显示 8×8 网格，逐块点亮
- 缺失块保持黑色
- 保存为 `recovered/recovered_image.jpg`

### 模式 2 — 仅视频

```matlab
TX_MODE = 2;  RX_MODE = 2;
```

- 视频 `视频.mp4` 中提取 20 帧均匀间隔缩略图
- 接收端显示 4×5 帧网格
- 保存为 `recovered/recovered_video.avi` (5 fps)

### 模式 3 — 图像+视频

```matlab
TX_MODE = 3;  RX_MODE = 3;
```

- 同时发送 64 图像块 + 20 视频帧
- 接收端双栏显示：左图右视频
- 保存两份文件

### 模式 4 — 文本

```matlab
TX_MODE = 4;  RX_MODE = 4;
```

- 编辑 `TEXT_STRING` 为要发送的文本（支持中文）
- 接收端在终端直接打印

```matlab
TEXT_STRING = 'Hello World! 这是一段通过USRP无线传输的测试文本。';
```

接收端输出：
```
===== 接收到的文本 =====
Hello World! 这是一段通过USRP无线传输的测试文本。
========================
[RX-TEXT] 文本接收完成 (3/3 包)
```

- 文本模式不弹图形窗口
- 每个物理包承载 35 字节 UTF-8 文本

## 可调参数

所有参数都在两个主文件顶部附近：

| 参数 | 默认值 | 位置 | 说明 |
|------|--------|------|------|
| `TX_MODE` / `RX_MODE` | 1 | 两文件 | 传输模式 (1-4) |
| `NUM_ROUNDS` | 2 | TX | 发送轮数 |
| `IDLE_SLOTS` | 3 | TX | 每突发后空闲帧数 |
| `IMAGE_GRID_ROWS` | 8 | 两文件 | 图片分块行数 |
| `IMAGE_GRID_COLS` | 8 | 两文件 | 图片分块列数 |
| `VIDEO_FRAME_NUM` | 20 | 两文件 | 视频提取帧数 |
| `TIMEOUT_IDLE` | 50 | RX | 无新数据超时轮数 |
| `BURST_PKTS` | 10 | TX | 每突发包数 |
| `Threshold` | 240 | RX | 同步检测门限 |
| `CONTROL_TX_INTERVAL` | 20 | RX | 反向链路发送间隔 |
| `TEXT_STRING` | — | TX | 模式 4 发送的文本 |

### 调参建议

- **丢包多**：增大 `NUM_ROUNDS` (3-4)，减小 `IDLE_SLOTS` (1-2)
- **接收端处理慢**：增大 `IDLE_SLOTS` (5-8)，增大 `TIMEOUT_IDLE`
- **图片块太粗/太细**：调整 `IMAGE_GRID_ROWS` × `IMAGE_GRID_COLS`（需两端一致）
- **同步困难**：降低 `Threshold`（如 200），提高 `radio_rx.Gain`（如 15-20）

## 反向链路

接收端每 20 轮通过反向链路（1.45 GHz）向发射端发送：
- 当前载频索引
- SNR 估计值 (dB)

发射端解析后在控制台显示：
```
[TX-REV] 反向链路状态: 载频索引=3 | SNR≈12 dB | 模式=0
```

此功能为预留，当前不自动调整发射参数。

## 输出文件

接收端运行结束后，在 `接收机/recovered/` 目录下生成：

```
recovered/
├── recovered_image.jpg    # 恢复的图片（缺失块=黑色）
└── recovered_video.avi    # 恢复的视频（缺失帧=黑色，5fps）
```

文本模式不产生文件，直接在终端打印。

## 故障排查

| 现象 | 可能原因 | 解决方法 |
|------|----------|----------|
| `Undefined function 'comm.SDRuTransmitter'` | USRP 支持包未安装 | 安装 Communications Toolbox Support Package for USRP Radio |
| `Undefined function 'ldpcQuasiCyclicMatrix'` | 5G Toolbox 未安装 | 安装 5G Toolbox |
| USRP 初始化失败 | 网络不通 / IP 错误 | 检查 PC IP 为 `192.168.10.1`，ping `192.168.10.2` |
| Underrun / Overrun 频繁 | 时钟源问题 | 检查外部时钟源连接 |
| 所有块 CRC mismatch | 图像/视频文件不一致 | 确保 TX 和 RX 使用相同的媒体文件 |
| 反链 SNR 为负或 NaN | 信号太弱 | 增大发射功率，缩短天线距离 |
| 接收端无任何数据包 | 频点不一致 | 检查两端 `Carrier_set` 配置 |
| 文本乱码 | 编码问题 | 确保 `TEXT_STRING` 为有效的 UTF-8 文本 |
