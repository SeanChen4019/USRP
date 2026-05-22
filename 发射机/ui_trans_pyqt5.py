import sys
import os
import numpy as np
import threading
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QGridLayout, QLabel, QGroupBox, QPushButton, QLineEdit, QSplitter)
from PyQt5.QtCore import Qt, pyqtSignal, QThread, QMutex
from PyQt5.QtGui import QPixmap
import pyqtgraph as pg
from flask import Flask, request, jsonify
from flask_cors import CORS
import logging

app = Flask(__name__)
CORS(app)
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

data_mutex = QMutex()
control_mutex = QMutex()

# 数据存储
data_store = {
    'has_data': False,
    'tx_spec': {'freq': [], 'amp': []},
    'tx_time': {'time': [], 'amp': []},
    'rx_const': {'i': [], 'q': []},
    'rx_time': {'time': [], 'amp': []},
    'status': {},
    'sending_image': None
}

# 控制指令存储 (发给 MATLAB)
control_store = {
    'apply': False,
    'new_str': ''
}

@app.route('/api/data', methods=['POST'])
def receive_data():
    data = request.json
    data_mutex.lock()
    try:
        data_store['has_data'] = True
        if 'tx_spec' in data: data_store['tx_spec'] = data['tx_spec']
        if 'tx_time' in data: data_store['tx_time'] = data['tx_time']
        if 'rx_const' in data: data_store['rx_const'] = data['rx_const']
        if 'rx_time' in data: data_store['rx_time'] = data['rx_time']
        if 'status' in data: data_store['status'] = data['status']
        if 'sending_image' in data: data_store['sending_image'] = data['sending_image']
    finally:
        data_mutex.unlock()
    return jsonify({'status': 'success'})

@app.route('/api/control', methods=['GET'])
def get_control():
    control_mutex.lock()
    try:
        res = {'apply': control_store['apply'], 'str': control_store['new_str']}
        control_store['apply'] = False # MATLAB读完就复位
        return jsonify(res)
    finally:
        control_mutex.unlock()

def run_flask():
    app.run(host='127.0.0.1', port=5001, debug=False, use_reloader=False)

class DataUpdateThread(QThread):
    data_ready = pyqtSignal(dict)
    def run(self):
        while True:
            data_mutex.lock()
            if data_store['has_data']:
                copy = {
                    'tx_spec': data_store['tx_spec'].copy(),
                    'tx_time': data_store['tx_time'].copy(),
                    'rx_const': data_store['rx_const'].copy(),
                    'rx_time': data_store['rx_time'].copy(),
                    'status': data_store['status'].copy(),
                    'sending_image': data_store['sending_image']
                }
                data_store['has_data'] = False
                data_mutex.unlock()
                self.data_ready.emit(copy)
            else:
                data_mutex.unlock()
            self.msleep(100)

class TransMainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('全双工 SDR 发射机控制系统')
        self.setGeometry(100, 100, 1400, 900)
        # 开启无边框
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint)
        pg.setConfigOptions(antialias=True, background='#0f172a', foreground='#94a3b8')
        self.setStyleSheet("""
            QMainWindow { background-color: #0f172a; }
            QWidget { color: #e2e8f0; font-family: 'Microsoft YaHei'; font-size: 10pt; }
            QGroupBox { border: 1px solid #334155; border-radius: 8px; margin-top: 15px; font-weight: bold; color: #f472b6; }
            QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px; }
            QLineEdit { background-color: #1e293b; border: 1px solid #475569; padding: 5px; color: white; }
            QPushButton { background-color: #f472b6; color: black; font-weight: bold; padding: 8px; border-radius: 4px; }
            QPushButton:hover { background-color: #fbcfe8; }
            QSplitter::handle { background-color: #334155; width: 2px; }
        """)
        self.init_ui()
        self.data_thread = DataUpdateThread()
        self.data_thread.data_ready.connect(self.update_ui)
        self.data_thread.start()
        threading.Thread(target=run_flask, daemon=True).start()

    def create_plot(self, title, xl, yl):
        p = pg.PlotWidget(title=title)
        p.showGrid(x=True, y=True, alpha=0.3)
        p.setLabel('bottom', xl)
        p.setLabel('left', yl)
        return p

    def init_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # 1. 顶端自定义标题栏 (完全对齐接收端样式)
        self.title_bar = QWidget()
        self.title_bar.setFixedHeight(40)
        self.title_bar.setStyleSheet("background-color: #1e293b; border-bottom: 1px solid #334155;")
        title_bar_layout = QHBoxLayout(self.title_bar)
        title_bar_layout.setContentsMargins(10, 0, 10, 0)
        
        self.title_label = QLabel('全双工 SDR 发射机控制系统')
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

        # 2. 业务内容区
        content_widget = QWidget()
        layout = QHBoxLayout(content_widget)

        # === 左侧面板 ===
        left = QWidget()
        vbox = QVBoxLayout(left)

        # 动态控制
        ctrl_gp = QGroupBox('发射机动态控制')
        cv = QVBoxLayout()
        self.str_edit = QLineEdit()
        self.str_edit.setPlaceholderText("在此输入修改文本...")
        btn = QPushButton('应用新文本并生成信号')
        btn.clicked.connect(self.apply_text)
        cv.addWidget(QLabel('修改文本:'))
        cv.addWidget(self.str_edit)
        cv.addWidget(btn)
        ctrl_gp.setLayout(cv)
        vbox.addWidget(ctrl_gp)

        # 发送端配置信息
        tx_gp = QGroupBox('发送端配置信息')
        tx_grid = QGridLayout()
        self.tx_labels = {}
        tx_items = [('发送有效指示:', 'tx_valid'), ('系统调制方式:', 'tx_mod'), ('发送模式:', 'tx_mode'),
                    ('当前载波频率:', 'tx_carrier'), ('基带采样率:', 'tx_samp'), ('当前发射增益:', 'tx_gain')]
        for r, (l, k) in enumerate(tx_items):
            tx_grid.addWidget(QLabel(l), r, 0)
            val = QLabel('--')
            val.setStyleSheet("color: #38bdf8; font-weight: bold;")
            tx_grid.addWidget(val, r, 1)
            self.tx_labels[k] = val
        tx_gp.setLayout(tx_grid)
        vbox.addWidget(tx_gp)

        # 接收信令配置信息
        rx_gp = QGroupBox('接收信令配置信息')
        rx_grid = QGridLayout()
        self.rx_labels = {}
        rx_items = [('信令链路状态:', 'rx_state'), ('信令载波频率:', 'rx_carrier'),
                    ('发射增益配置:', 'rx_tx_gain'), ('发送载频配置:', 'rx_tx_carrier')]
        for r, (l, k) in enumerate(rx_items):
            rx_grid.addWidget(QLabel(l), r, 0)
            val = QLabel('--')
            val.setStyleSheet("color: #4ade80; font-weight: bold;")
            rx_grid.addWidget(val, r, 1)
            self.rx_labels[k] = val
        rx_gp.setLayout(rx_grid)
        vbox.addWidget(rx_gp)

        # 系统状态
        sys_gp = QGroupBox('系统状态')
        sv = QVBoxLayout()
        self.time_label = QLabel('--:--:--')
        sv.addWidget(self.time_label)
        sys_gp.setLayout(sv)
        vbox.addWidget(sys_gp)
        
        # 正在发送的图像载荷 (显示在左下角)
        img_gp = QGroupBox('正在发送的图像载荷')
        self.img_label = QLabel('等待加载图片...')
        self.img_label.setMinimumSize(250, 180)
        self.img_label.setStyleSheet("background-color: #0f172a; border-radius: 8px;")
        self.img_label.setAlignment(Qt.AlignCenter)
        iv = QVBoxLayout()
        iv.addWidget(self.img_label)
        img_gp.setLayout(iv)
        vbox.addWidget(img_gp)
        
        vbox.addStretch()

        # === 右侧绘图区 ===
        right = QWidget()
        grid_plots = QGridLayout(right)
        
        self.p_spec = self.create_plot('发端信号频谱', '频率 (kHz)', '幅度 (dB)')
        self.c_spec = self.p_spec.plot(pen='#38bdf8')
        
        self.p_time = self.create_plot('发射端时域信号波形', '时间 (ms)', '幅值 (V)')
        self.c_time = self.p_time.plot(pen='#f472b6')
        
        self.p_const = self.create_plot('信令信号星座图', 'I', 'Q')
        self.s_const = pg.ScatterPlotItem(size=6, brush=pg.mkBrush('#fbbf24'))
        self.p_const.addItem(self.s_const)
        
        self.p_time_mes = self.create_plot('信令时域信号波形', '时间 (ms)', '幅值 (V)')
        self.c_time_mes = self.p_time_mes.plot(pen='#a78bfa')

        grid_plots.addWidget(self.p_spec, 0, 0)
        grid_plots.addWidget(self.p_time, 0, 1)
        grid_plots.addWidget(self.p_const, 1, 0)
        grid_plots.addWidget(self.p_time_mes, 1, 1)

        split = QSplitter(Qt.Horizontal)
        split.addWidget(left)
        split.addWidget(right)
        split.setSizes([300, 1100])
        layout.addWidget(split)

        main_layout.addWidget(content_widget)

    def apply_text(self):
        control_mutex.lock()
        control_store['apply'] = True
        control_store['new_str'] = self.str_edit.text()
        control_mutex.unlock()

    def update_ui(self, d):
        # 更新图表
        if d['tx_spec']['freq']: self.c_spec.setData(d['tx_spec']['freq'], d['tx_spec']['amp'])
        if d['tx_time']['time']: self.c_time.setData(d['tx_time']['time'], d['tx_time']['amp'])
        if d['rx_const']['i']: self.s_const.setData(x=d['rx_const']['i'], y=d['rx_const']['q'])
        else: self.s_const.clear()
        if d['rx_time']['time']: self.c_time_mes.setData(d['rx_time']['time'], d['rx_time']['amp'])

        # 更新状态文本
        s = d['status']
        for k in self.tx_labels:
            if k in s: self.tx_labels[k].setText(str(s[k]))
        for k in self.rx_labels:
            if k in s: self.rx_labels[k].setText(str(s[k]))
        if 'time' in s: self.time_label.setText(s['time'])
            
        # 更新左下角图片
        img_p = d.get('sending_image')
        if img_p and getattr(self, 'last_img', '') != img_p:
            if os.path.exists(img_p):
                pix = QPixmap(img_p)
                self.img_label.setPixmap(pix.scaled(self.img_label.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation))
                self.last_img = img_p

    # 最大化切换逻辑
    def toggle_maximize(self):
        if self.isMaximized():
            self.showNormal()
            self.maximize_btn.setText('□')
        else:
            self.showMaximized()
            self.maximize_btn.setText('−')

    # 无边框窗口拖拽支持 (判定高度设为 40)
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and event.y() <= 40:
            self.drag_pos = event.globalPos() - self.frameGeometry().topLeft()
            event.accept()

    def mouseMoveEvent(self, event):
        if event.buttons() == Qt.LeftButton:
            self.move(event.globalPos() - self.drag_pos)
            event.accept()

if __name__ == '__main__':
    aq = QApplication(sys.argv)
    window = TransMainWindow()
    window.show()
    sys.exit(aq.exec_())