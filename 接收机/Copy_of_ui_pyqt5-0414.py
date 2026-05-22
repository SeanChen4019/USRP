import sys
import os
import numpy as np
from datetime import datetime
import threading

# 导入 PyQt5 组件
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QGridLayout, QLabel, QGroupBox, QPushButton, QButtonGroup,
                             QRadioButton, QScrollArea, QSplitter, QSizePolicy)
from PyQt5.QtCore import Qt, QTimer, pyqtSignal, QThread, QMutex, QSize
from PyQt5.QtGui import QFont, QPixmap

# 导入高性能绘图库 PyQtGraph
import pyqtgraph as pg

# 导入 Flask
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

data_mutex = QMutex()
decision_mutex = QMutex()
data_store = {
    'has_data': False,
    'spectrum': {'freq': [], 'amp': []},
    'spectrum_mes': {'freq': [], 'amp': []},
    'time_domain': {'time': [], 'amp': []},
    'constellation': {'i': [], 'q': []},
    'waterfall': np.full((80, 2048), -60.0),
    'status': {
        'data_rec_valid': '无效',
        'current_send_mode': '等待接收',
        'current_mod': '未知',
        'center_frequency': 0,
        'samp_rate': 0,
        'snr': '信噪比无效',
        'mes_valid': '无效',
        'mes_rate': 0,
        'power_gain': '0 dB',
        'carrier_gain': '0 GHz',
        'ber': '未测试',
        'current_time': '--:--:--',
        'received_text': '等待接收数据...'
    },
    'received_image': None,
    'image_rebuild_status': '等待接收图片数据'
}

decision_store = {
    'anti_jamming_mode': 0,
    'needs_update': False
}

@app.route('/api/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'ok'})

@app.route('/api/data', methods=['POST'])
def receive_data():
    try:
        data = request.json
        data_mutex.lock()
        try:
            data_store['has_data'] = True
            if 'spectrum' in data: data_store['spectrum'] = data['spectrum']
            if 'spectrum_mes' in data: data_store['spectrum_mes'] = data['spectrum_mes']
            if 'time_domain' in data: data_store['time_domain'] = data['time_domain']
            if 'constellation' in data: data_store['constellation'] = data['constellation']
            
            if 'waterfall_line' in data:
                line_data = np.array(data['waterfall_line'])
                if line_data.size == 2048:
                    # 将整个矩阵往下平移一行 (丢弃最旧的一行)
                    data_store['waterfall'][1:] = data_store['waterfall'][:-1]
                    # 将接收到的最新数据放在第一行 (最上方)
                    data_store['waterfall'][0] = line_data
            
            if 'status' in data: data_store['status'].update(data['status'])
            if 'received_image' in data: data_store['received_image'] = data['received_image']
            if 'image_rebuild_status' in data: data_store['image_rebuild_status'] = data['image_rebuild_status']
        finally:
            data_mutex.unlock()
        return jsonify({'status': 'success'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 400

@app.route('/api/decision', methods=['GET'])
def get_decision():
    decision_mutex.lock()
    try:
        decision = {'anti_jamming_mode': decision_store['anti_jamming_mode'], 'needs_update': decision_store['needs_update']}
        decision_store['needs_update'] = False
        return jsonify(decision)
    finally:
        decision_mutex.unlock()

def run_flask():
    # 禁用 werkzeug 的请求日志，防止控制台刷屏影响性能
    import logging
    log = logging.getLogger('werkzeug')
    log.setLevel(logging.ERROR)
    app.run(host='127.0.0.1', port=5000, debug=False, use_reloader=False)

class DataUpdateThread(QThread):
    data_ready = pyqtSignal(dict)
    def __init__(self):
        super().__init__()
        self.running = True
    
    def run(self):
        while self.running:
            data_mutex.lock()
            has_new_data = data_store['has_data']
            if has_new_data:
                data_copy = {
                    'spectrum': data_store['spectrum'].copy(),
                    'spectrum_mes': data_store['spectrum_mes'].copy(),
                    'time_domain': data_store['time_domain'].copy(),
                    'constellation': data_store['constellation'].copy(),
                    'waterfall': data_store['waterfall'].copy(),
                    'status': data_store['status'].copy(),
                    'received_image': data_store['received_image'],
                    'image_rebuild_status': data_store['image_rebuild_status']
                }
                data_store['has_data'] = False
            data_mutex.unlock()

            if has_new_data:
                self.data_ready.emit(data_copy)
            
            self.msleep(100) # 将刷新率提高到最高 10FPS (100ms)，PyQtGraph完全扛得住
    
    def stop(self):
        self.running = False
        self.wait()

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('接收机监控系统')
        self.setGeometry(100, 100, 1200, 900)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint)
        
        self.last_image_path = None
        
        # ====== 配置 PyQtGraph 全局主题 ======
        pg.setConfigOptions(antialias=True) # 开启抗锯齿
        pg.setConfigOption('background', '#0f172a')
        pg.setConfigOption('foreground', '#94a3b8')
        
        self.setup_theme()
        self.init_ui()
        
        self.data_thread = DataUpdateThread()
        self.data_thread.data_ready.connect(self.update_ui)
        self.data_thread.start()
        
        flask_thread = threading.Thread(target=run_flask, daemon=True)
        flask_thread.start()
        print('Flask服务器已启动: http://127.0.0.1:5000')

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and event.y() <= 40:
            self.drag_pos = event.globalPos() - self.frameGeometry().topLeft()
            event.accept()
    
    def mouseMoveEvent(self, event):
        if event.buttons() == Qt.LeftButton:
            self.move(event.globalPos() - self.drag_pos)
            event.accept()
    
    def toggle_maximize(self):
        if self.isMaximized():
            self.showNormal()
            self.maximize_btn.setText('□')
        else:
            self.showMaximized()
            self.maximize_btn.setText('−')
    
    def setup_theme(self):
        self.setStyleSheet("""
            QMainWindow { background-color: #0f172a; }
            QWidget { color: #e2e8f0; font-family: 'Microsoft YaHei', 'SimHei', Arial; font-size: 10pt; }
            QGroupBox { border: 1px solid #475569; border-radius: 10px; margin-top: 16px; padding-top: 20px; font-weight: 600; color: #60a5fa; background-color: #1e293b; }
            QGroupBox::title { subcontrol-origin: margin; left: 20px; padding: 0 10px; }
            QLabel { color: #cbd5e1; }
            QRadioButton { color: #e2e8f0; spacing: 10px; }
            QRadioButton::indicator { width: 18px; height: 18px; border: 2px solid #475569; border-radius: 9px; background-color: #334155; }
            QRadioButton::indicator:checked { background-color: #3b82f6; border-color: #3b82f6; }
            QScrollArea { border: 1px solid #475569; border-radius: 8px; background-color: #1e293b; }
                           
            /* ====== 新增：美化垂直滚动条 ====== */
            QScrollBar:vertical {
                border: none;
                background-color: #0f172a; /* 滚动条底色 */
                width: 10px;               /* 滚动条宽度变窄 */
                margin: 0px 0px 0px 0px;
            }
            QScrollBar::handle:vertical {
                background-color: #475569; /* 滚动块颜色 */
                min-height: 30px;
                border-radius: 5px;        /* 圆角设计 */
            }
            QScrollBar::handle:vertical:hover {
                background-color: #64748b; /* 鼠标悬停时变亮 */
            }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
                height: 0px;               /* 隐藏上下箭头 */
                background: none;
            }
            QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
                background: none;          /* 隐藏滚动块上下的背景颜色 */
            }
            /* ====== 新增：美化左右拖拽分割线 (隐藏白条) ====== */
            QSplitter::handle {
                background-color: #334155; /* 使用深灰色作为分割线 */
                width: 2px;                /* 把粗白条变成 2 像素的细线 */
            }

        """)
    
    def closeEvent(self, event):
        if hasattr(self, 'data_thread'):
            self.data_thread.stop()
        event.accept()
    
    def set_mode(self, mode):
        decision_mutex.lock()
        try:
            decision_store['anti_jamming_mode'] = mode
            decision_store['needs_update'] = True
        finally:
            decision_mutex.unlock()
    
    def create_custom_plot(self, title, x_label, y_label):
        plot = pg.PlotWidget(title=title)
        plot.showGrid(x=True, y=True, alpha=0.3)
        plot.setLabel('bottom', x_label)
        plot.setLabel('left', y_label)
        plot.getAxis('bottom').setPen(pg.mkPen(color='#475569'))
        plot.getAxis('left').setPen(pg.mkPen(color='#475569'))
        return plot

    def init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)
        
        # ======== 标题栏 ========
        self.title_bar = QWidget()
        self.title_bar.setFixedHeight(40)
        self.title_bar.setStyleSheet("background-color: #1e293b; border-bottom: 1px solid #334155;")
        title_bar_layout = QHBoxLayout(self.title_bar)
        title_bar_layout.setContentsMargins(10, 0, 10, 0)
        self.title_label = QLabel('全双工 SDR 接收机监控系统 (PyQtGraph加速版)')
        self.title_label.setStyleSheet("color: #e2e8f0; font-weight: bold;")
        title_bar_layout.addWidget(self.title_label)
        title_bar_layout.addStretch()
        
        self.minimize_btn = QPushButton('−')
        self.minimize_btn.setFixedSize(30, 30)
        self.minimize_btn.setStyleSheet("QPushButton { background-color: #f59e0b; color: white; border-radius: 5px; font-weight: bold; }")
        self.minimize_btn.clicked.connect(self.showMinimized)
        title_bar_layout.addWidget(self.minimize_btn)
        
        self.maximize_btn = QPushButton('□')
        self.maximize_btn.setFixedSize(30, 30)
        self.maximize_btn.setStyleSheet("QPushButton { background-color: #10b981; color: white; border-radius: 5px; font-weight: bold; }")
        self.maximize_btn.clicked.connect(self.toggle_maximize)
        title_bar_layout.addWidget(self.maximize_btn)
        
        self.close_btn = QPushButton('✕')
        self.close_btn.setFixedSize(30, 30)
        self.close_btn.setStyleSheet("QPushButton { background-color: #ef4444; color: white; border-radius: 5px; font-weight: bold; }")
        self.close_btn.clicked.connect(self.close)
        title_bar_layout.addWidget(self.close_btn)
        
        main_layout.addWidget(self.title_bar)
        
        # ======== 内容区 ========
        content_widget = QWidget()
        content_layout = QHBoxLayout(content_widget)
        content_layout.setContentsMargins(8, 8, 8, 8)
        
        # 左侧面板
        left_widget = QWidget()
        left_widget.setStyleSheet("background-color: #1e293b;")
        left_layout = QVBoxLayout(left_widget)
        
        # 模式选择
        mode_group = QGroupBox('抗干扰模式切换')
        mode_layout = QVBoxLayout()
        self.radio_regular = QRadioButton('常规模式')
        self.radio_regular.setChecked(True)
        self.radio_regular.toggled.connect(lambda: self.set_mode(0) if self.radio_regular.isChecked() else None)
        self.radio_low_speed = QRadioButton('低速抗扰模式')
        self.radio_low_speed.toggled.connect(lambda: self.set_mode(1) if self.radio_low_speed.isChecked() else None)
        self.radio_freq_hop = QRadioButton('切频模式')
        self.radio_freq_hop.toggled.connect(lambda: self.set_mode(2) if self.radio_freq_hop.isChecked() else None)
        mode_layout.addWidget(self.radio_regular)
        mode_layout.addWidget(self.radio_low_speed)
        mode_layout.addWidget(self.radio_freq_hop)
        mode_group.setLayout(mode_layout)
        left_layout.addWidget(mode_group)
        
        # 状态面板
        status_group = QGroupBox('实时链路状态')
        status_layout = QGridLayout()
        self.status_labels = {}
        status_items = [
            ('数据接收', 'data_rec_valid'), ('发送模式', 'current_send_mode'),
            ('调制方式', 'current_mod'), ('中心频率', 'center_frequency'),
            ('采样率', 'samp_rate'), ('信噪比', 'snr'),
            ('消息状态', 'mes_valid'), ('消息速率', 'mes_rate'),
            ('功率增益', 'power_gain'), ('载波增益', 'carrier_gain'),
            ('当前时间', 'current_time')
        ]
        for row, (label_text, key) in enumerate(status_items):
            label = QLabel(f'{label_text}:')
            label.setStyleSheet('color: #94a3b8;')
            value_label = QLabel('--')
            value_label.setStyleSheet('color: #38bdf8; font-weight: bold;')
            status_layout.addWidget(label, row, 0)
            status_layout.addWidget(value_label, row, 1)
            self.status_labels[key] = value_label
        status_group.setLayout(status_layout)
        left_layout.addWidget(status_group)
        
        # 文本和图片显示区域保持不变
        text_group = QGroupBox('解码文本与状态')
        text_layout = QVBoxLayout()
        self.received_text_label = QLabel('等待接收数据...')
        self.received_text_label.setWordWrap(True)
        self.received_text_label.setStyleSheet("background-color: #0f172a; padding: 10px; border-radius: 5px;")
        text_layout.addWidget(self.received_text_label)
        text_group.setLayout(text_layout)
        left_layout.addWidget(text_group)
        
        image_group = QGroupBox('重组业务图像')
        image_layout = QVBoxLayout()
        self.image_status_label = QLabel('等待接收图片数据...')
        image_layout.addWidget(self.image_status_label)
        self.image_label = QLabel()
        self.image_label.setAlignment(Qt.AlignCenter)
        self.image_label.setStyleSheet("background-color: #0f172a; border-radius: 5px;")
        self.image_label.setMinimumSize(250, 180)
        image_layout.addWidget(self.image_label)
        image_group.setLayout(image_layout)
        left_layout.addWidget(image_group)
        left_layout.addStretch()
        
        left_scroll = QScrollArea()
        left_scroll.setWidget(left_widget)
        left_scroll.setWidgetResizable(True)
        left_scroll.setMinimumWidth(320)
        
        # ================= 右侧高性能绘图区 (PyQtGraph) =================
        right_widget = QWidget()
        right_layout = QVBoxLayout(right_widget)
        right_layout.setContentsMargins(0, 0, 0, 0)
        
        # 上半部分：频谱图
        charts_top = QWidget()
        charts_top_layout = QHBoxLayout(charts_top)
        charts_top_layout.setContentsMargins(0, 0, 0, 0)
        
        self.plot_spectrum = self.create_custom_plot('收端信号频谱', '频率 (kHz)', '幅度 (dB)')
        self.curve_spectrum = self.plot_spectrum.plot(pen=pg.mkPen('#60a5fa', width=1.5))
        charts_top_layout.addWidget(self.plot_spectrum)
        
        self.plot_constellation = self.create_custom_plot('收端信号星座图', 'I', 'Q')
        self.scatter_constellation = pg.ScatterPlotItem(size=4, pen=pg.mkPen(None), brush=pg.mkBrush('#a78bfa90'))
        self.plot_constellation.addItem(self.scatter_constellation)
        charts_top_layout.addWidget(self.plot_constellation)
        right_layout.addWidget(charts_top)
        
        # 中间部分：时域与星座图
        charts_mid = QWidget()
        charts_mid_layout = QHBoxLayout(charts_mid)
        charts_mid_layout.setContentsMargins(0, 0, 0, 0)
        
        self.plot_time = self.create_custom_plot('收端时域信号波形', '时间 (ms)', '幅度')
        self.curve_time = self.plot_time.plot(pen=pg.mkPen('#4ade80', width=1))
        charts_mid_layout.addWidget(self.plot_time)
        
        # 【新增图表】10信道占用决策热力图
        self.plot_channel = pg.PlotWidget(title="信道占用决策状态 (10信道)")
        self.plot_channel.setLabel('bottom', '信道编号 (1-10)')
        self.plot_channel.setLabel('left', '时间历史')
        
        # 1. 关闭默认模糊网格
        self.plot_channel.showGrid(x=False, y=False)
        
        self.channel_im = pg.ImageItem()
        self.plot_channel.addItem(self.channel_im)
        self.channel_history = np.full((20, 10), -60.0)
        
        # 2. 绘制纯黑边框，切分 10x40 的标准方格
        black_pen = pg.mkPen(color='black', width=2)
        for x in range(1, 10):
            self.plot_channel.addItem(pg.InfiniteLine(pos=x, angle=90, pen=black_pen))
        for y in range(1, 20):
            self.plot_channel.addItem(pg.InfiniteLine(pos=y, angle=0, pen=black_pen))

        # 自定义红绿 Colormap：绿(空闲) -> 黄(过渡) -> 红(占用)
        # 将区间严格三等分: [0~33%]为绿, [33%~66%]为黄, [66%~100%]为红
        pos = np.array([0.0, 0.33, 0.33001, 0.66, 0.66001, 1.0])
        colors = np.array([
            [34, 197, 94, 255],   # 纯绿 
            [34, 197, 94, 255],   # 纯绿 (边界)
            [234, 179, 8, 255],   # 纯黄 
            [234, 179, 8, 255],   # 纯黄 (边界)
            [239, 68, 68, 255],   # 纯红 
            [239, 68, 68, 255]    # 纯红 (边界)
        ], dtype=np.ubyte)
        cmap = pg.ColorMap(pos, colors)
        self.channel_im.setLookupTable(cmap.getLookupTable())
        
        # 能量阈值设定：低于 -45dB 显绿，高于 -15dB 显红 (请根据你的底噪微调)
        self.channel_im.setLevels([-30, -5]) 
        
        # 让X轴刻度居中显示 1 到 10
        x_axis = self.plot_channel.getAxis('bottom')
        x_axis.setTicks([[(i + 0.5, str(i + 1)) for i in range(10)]])
        
        self.plot_channel.invertY(True) # 最新数据从上往下流
        charts_mid_layout.addWidget(self.plot_channel)
        right_layout.addWidget(charts_mid)


        # 下半部分：高刷瀑布图
        self.plot_waterfall = pg.PlotWidget(title="收端时频瀑布图 (-40dB 到 0dB)")
        self.plot_waterfall.setLabel('bottom', '频段索引 (X)')
        self.plot_waterfall.setLabel('left', '时间历史 (Y)')
        
        # 使用 ImageItem 渲染矩阵
        self.waterfall_im = pg.ImageItem()
        self.plot_waterfall.addItem(self.waterfall_im)
        
        # 设置瀑布图的伪彩色 (类似 matplotlib 的 plasma)
        colormap = pg.colormap.get('turbo')
        self.waterfall_im.setLookupTable(colormap.getLookupTable())
        self.waterfall_im.setLevels([-40, 0]) # 固定色彩映射范围，防止画面闪烁
        
        # 翻转Y轴，让最新的数据从上方往下流
        self.plot_waterfall.invertY(True)
        
        right_layout.addWidget(self.plot_waterfall)
        
        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(left_scroll)
        splitter.addWidget(right_widget)
        splitter.setSizes([350, 850])
        content_layout.addWidget(splitter)
        
        main_layout.addWidget(content_widget)
    
    def update_ui(self, data_copy):
        # 1. 刷新频谱
        spectrum = data_copy.get('spectrum')
        if spectrum and len(spectrum['freq']) > 0:
            self.curve_spectrum.setData(spectrum['freq'], spectrum['amp'])
            
            # 【核心逻辑】将 2048 个频点切分为 10 份，计算每个信道的能量均值
            amp_array = np.array(spectrum['amp'])
            splits = np.array_split(amp_array, 10)
            channel_energy = np.array([np.max(s) for s in splits])
            
            # 滚动更新 40x10 的历史矩阵
            self.channel_history[1:] = self.channel_history[:-1]
            self.channel_history[0] = channel_energy
            
            # 渲染信道热力图 (注意 .T 转置)
            self.channel_im.setImage(self.channel_history.T, autoLevels=False)
            
        # 2. 刷新时域 (降采样以节省性能)
        time_domain = data_copy.get('time_domain')
        if time_domain and len(time_domain['time']) > 0:
            step = max(1, len(time_domain['time']) // 1000)
            t = [x * 1000 for x in time_domain['time'][::step]]
            amp = time_domain['amp'][::step]
            self.curve_time.setData(t, amp)
            
        # 3. 刷新星座图
        constellation = data_copy.get('constellation')
        if constellation and len(constellation['i']) > 0:
            i_data = np.array(constellation['i'])
            q_data = np.array(constellation['q'])
            step = max(1, len(i_data) // 1000)
            # ScatterPlotItem 的 setData 效率很高
            self.scatter_constellation.setData(x=i_data[::step], y=q_data[::step])
        else:
            self.scatter_constellation.clear() # 没信号时清空星座图
            
        # 4. 刷新瀑布图 (极其流畅！)
        wf = data_copy.get('waterfall')
        if wf is not None:
            self.waterfall_im.setImage(wf.T, autoLevels=False)
            
            # 【新增】将横坐标映射为真实的物理频率 (MHz)
            st = data_copy.get('status', {})
            cf = st.get('center_frequency', 0) / 1e6  # 中心频率 (MHz)
            sr = st.get('samp_rate', 0) / 1e6         # 采样率/带宽 (MHz)
            
            if cf > 0 and sr > 0:
                # setRect 参数: (X轴起点, Y轴起点, X轴总宽度, Y轴总高度)
                # X轴范围: 中心频率 - 带宽/2  到  中心频率 + 带宽/2
                self.waterfall_im.setRect(pg.QtCore.QRectF(cf - sr/2, 0, sr, 80))
                self.plot_waterfall.setLabel('bottom', f'物理频率 (MHz)')

            
        # 5. 刷新状态文本与切频清屏逻辑
        status = data_copy.get('status')
        if status:
            cf = status.get('center_frequency', 0)
            
            # 【新增：检测切频并瞬间清空历史瀑布图】
            if hasattr(self, 'current_cf') and cf != 0 and self.current_cf != 0:
                if abs(cf - self.current_cf) > 100e3: # 如果频率跳变超过 100kHz
                    print(f"⚡ 检测到切频！从 {self.current_cf/1e9:.3f}GHz 切换至 {cf/1e9:.3f}GHz，清空历史记录...")
                    # 1. 清空 10 信道决策图历史
                    self.channel_history.fill(-60.0)
                    self.channel_im.setImage(self.channel_history.T, autoLevels=False)
                    # 2. 清空底层数据源的瀑布图历史
                    data_mutex.lock()
                    data_store['waterfall'].fill(-60.0)
                    data_mutex.unlock()
                    # 3. 清空当前正在渲染的瀑布图残留
                    if wf is not None:
                        wf.fill(-60.0)
                        self.waterfall_im.setImage(wf.T, autoLevels=False)
            
            # 记录当前频率供下一帧对比
            if cf != 0:
                self.current_cf = cf

            # 原有的文本更新逻辑
            self.status_labels['data_rec_valid'].setText(status.get('data_rec_valid', '无效'))
            self.status_labels['current_send_mode'].setText(status.get('current_send_mode', '等待接收'))
            self.status_labels['current_mod'].setText(status.get('current_mod', '未知'))
            
            self.status_labels['center_frequency'].setText(f'{cf / 1e9:.2f} GHz' if cf else '0 GHz')
            
            sr = status.get('samp_rate', 0)
            self.status_labels['samp_rate'].setText(f'{sr / 1e3:.2f} kHz' if sr else '0 kHz')
            
            self.status_labels['snr'].setText(status.get('snr', '信噪比无效'))
            self.status_labels['mes_valid'].setText(status.get('mes_valid', '无效'))
            self.status_labels['mes_rate'].setText(f"{status.get('mes_rate', 0):.2f} bps")
            self.status_labels['power_gain'].setText(status.get('power_gain', '0 dB'))
            self.status_labels['carrier_gain'].setText(status.get('carrier_gain', '0 GHz'))
            self.status_labels['current_time'].setText(status.get('current_time', '--:--:--'))
            
            self.received_text_label.setText(status.get('received_text', '等待接收数据...'))
        
        # 6. 刷新图片
        self.image_status_label.setText(data_copy.get('image_rebuild_status', '等待接收图片数据...'))
        image_file = data_copy.get('received_image')
        if image_file and image_file != self.last_image_path and os.path.exists(image_file):
            try:
                pixmap = QPixmap(image_file)
                if not pixmap.isNull():
                    scaled_pixmap = pixmap.scaled(self.image_label.size().expandedTo(QSize(250, 180)),
                                                  Qt.KeepAspectRatio, Qt.SmoothTransformation)
                    self.image_label.setPixmap(scaled_pixmap)
                    self.last_image_path = image_file
            except Exception as e:
                print(f'加载图片错误: {str(e)}')

if __name__ == '__main__':
    app_qt = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app_qt.exec_())