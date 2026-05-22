% =========== 接收端：分块渐进式恢复 + 缺失填黑 + 预存块数据 ===========
clear
clc
close all force
warning('off', 'all');

fprintf('\n==================== 接收端（分块渐进式恢复）启动 ====================\n');

%% ================= 初始化 =================
if exist('radio_tx', 'var') && isvalid(radio_tx)
    release(radio_tx);
    clear radio_tx;
end
if exist('radio_rx', 'var') && isvalid(radio_rx)
    release(radio_rx);
    clear radio_rx;
end

samp_rate = 200e6 / 512;
Threshold = 240;
BUS_RX_SAMPLES = 160000;
FB_TX_SAMPLES  = 60000;

IMAGE_GRID_ROWS = 8;
IMAGE_GRID_COLS = 8;
VIDEO_FRAME_NUM = 20;

STATE_COLLECT  = 1;
STATE_COMPLETE = 2;

Carrier_set = 2e9 : 0.5e9 : 4e9;
Power_gain_set = 0 : 1 : 30;

Anti_Jamming_Mode_bef = 0;
Carrier_select_bef = 3;
Trans_power_select_bef = 7;
Power_gain_select_bef = 15;

CenterFrequency = Carrier_set(Carrier_select_bef);

CONTROL_TX_INTERVAL = 20;

%% ================= 预处理：预存图片和视频块数据 =================
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir)
    script_dir = pwd;
end

% 发射机目录下的媒体文件路径
tx_dir = fullfile(script_dir, '..', '发射机');
img_path = fullfile(tx_dir, 'p2.jpg');
video_path = fullfile(tx_dir, '视频.mp4');

fprintf('[RX-INIT] 预存图片和视频块数据...\n');

[img_blocks, img_crc] = preprocess_image(img_path, IMAGE_GRID_ROWS, IMAGE_GRID_COLS);
[info_h, info_w] = get_image_dims(img_path);
img_block_h = floor(info_h / IMAGE_GRID_ROWS);
img_block_w = floor(info_w / IMAGE_GRID_COLS);

[video_blocks_data, video_crc] = preprocess_video(video_path, VIDEO_FRAME_NUM);

% 块接收状态网格
img_received = false(IMAGE_GRID_ROWS, IMAGE_GRID_COLS);
img_grid_data = cell(IMAGE_GRID_ROWS, IMAGE_GRID_COLS);

video_received = false(VIDEO_FRAME_NUM, 1);
video_frame_data = cell(VIDEO_FRAME_NUM, 1);

fprintf('[RX-INIT] 预存完成: 图片 %dx%d=%d块 | 视频 %d帧\n', ...
    IMAGE_GRID_ROWS, IMAGE_GRID_COLS, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, VIDEO_FRAME_NUM);

%% ================= 接收缓存 =================
rx_session_id = 0;
rx_total_pkt_num = 0;
rx_pkt_valid = false(1, 10000);

img_rebuild_done = false;
rebuild_status_txt = '等待接收图片分块...';
preview_image_path = '';

state = STATE_COLLECT;
trans_sigs = zeros(FB_TX_SAMPLES, 1);

prev_img_recv = 0;
prev_vid_recv = 0;
dup_pkt_count = 0;

%% ================= UI 配置（接收端） =================
rx_ui.enable = true;
rx_ui.url = 'http://127.0.0.1:5000';
rx_ui.health_endpoint = '/api/health';
rx_ui.post_period = 10;
rx_ui.ctrl_period = 20;
rx_ui.timeout = 0.03;
rx_ui = ui_init(rx_ui);

%% ================= 显示窗口 =================
fig_main = figure('Name', '接收端 - 分块渐进式恢复', 'NumberTitle', 'off', ...
    'Position', [100, 100, 900, 500]);
colormap gray;

%% ================= SDR 初始化 =================
disp('正在初始化 USRP 硬件，请稍候...');

radio_tx = comm.SDRuTransmitter('Platform','X310','IPAddress','192.168.10.2');
radio_tx.ChannelMapping = 1;
radio_tx.CenterFrequency = 1.45e9;
radio_tx.Gain = 10;
radio_tx.MasterClockRate = 200e6;
radio_tx.InterpolationFactor = 512;
radio_tx.ClockSource = 'External';
radio_tx.UnderrunOutputPort = true;

radio_rx = comm.SDRuReceiver( ...
    'Platform','X310', ...
    'IPAddress','192.168.10.2', ...
    'OutputDataType','double', ...
    'MasterClockRate',200e6, ...
    'DecimationFactor',512, ...
    'SamplesPerFrame',BUS_RX_SAMPLES);
radio_rx.ClockSource = 'External';
radio_rx.ChannelMapping = 1;
radio_rx.CenterFrequency = CenterFrequency;
radio_rx.Gain = 10;
radio_rx.OverrunOutputPort = true;

cleanupObj = onCleanup(@() safe_release_rx(radio_tx, radio_rx, fig_main));
disp('USRP 硬件初始化完成！');

%% ================= 主循环 =================
for idx = 1:100000
    % ---------- UI / 决策输入 ----------
    if rx_ui.enable && mod(idx, rx_ui.ctrl_period) == 0
        dec = ui_try_get_decision(rx_ui);
        if isfield(dec, 'needs_update') && dec.needs_update
            changed = false;

            if isfield(dec, 'anti_jamming_mode')
                Anti_Jamming_Mode_bef = dec.anti_jamming_mode;
                changed = true;
            end
            if isfield(dec, 'carrier_select')
                Carrier_select_bef = dec.carrier_select;
                CenterFrequency = Carrier_set(Carrier_select_bef);
                radio_rx.CenterFrequency = CenterFrequency;
                changed = true;
            end
            if isfield(dec, 'power_gain_select')
                Power_gain_select_bef = dec.power_gain_select;
                changed = true;
            end
            if isfield(dec, 'trans_power_select')
                Trans_power_select_bef = dec.trans_power_select;
                changed = true;
            end

            if changed
                fprintf('[RX-UI] 参数更新 -> Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d\n', ...
                    Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
            end
        end
    end

    % ---------- 周期性参数反馈（尽力而为） ----------
    if state == STATE_COMPLETE
        trans_sigs = zeros(FB_TX_SAMPLES, 1);
    else
        if mod(idx, CONTROL_TX_INTERVAL) == 0
            Par_Trans_sig = Par_trans_sig_Gen( ...
                Anti_Jamming_Mode_bef, ...
                Carrier_select_bef, ...
                Trans_power_select_bef, ...
                Power_gain_select_bef);

            trans_sigs_sample_num = FB_TX_SAMPLES;
            zero_pad_num_par = trans_sigs_sample_num - length(Par_Trans_sig) - 2000;
            zero_pad_num_par = max(zero_pad_num_par, 0);
            trans_sigs = [zeros(zero_pad_num_par,1); Par_Trans_sig; zeros(2000,1)];
        else
            trans_sigs = zeros(FB_TX_SAMPLES, 1);
        end
    end

    % ---------- 硬件收发 ----------
    try
        [Data_Rec_signal, ~, rx_overrun] = radio_rx();
        tx_underrun = radio_tx(trans_sigs);

        if rx_overrun
            % 静默处理
        end
        if tx_underrun
            % 静默处理
        end
    catch ME
        warning('[RX-ERR] 硬件异常：%s', ME.message);
        continue;
    end

    % ---------- 动态调门限 / 增益 ----------
    total_blocks = IMAGE_GRID_ROWS * IMAGE_GRID_COLS + VIDEO_FRAME_NUM;
    recv_num = sum(img_received(:)) + sum(video_received(:));
    missing_num = total_blocks - recv_num;

    if missing_num <= 8
        Threshold = 195;
        radio_rx.Gain = 18;
    elseif missing_num <= 32
        Threshold = 210;
        radio_rx.Gain = 16;
    else
        Threshold = 240;
        radio_rx.Gain = 10;
    end

    % ---------- 数据接收解析 ----------
    [~, ~, ~, ~, ~, ~, frame_packets] = Data_Rece_sig_Gen( ...
        Anti_Jamming_Mode_bef, Data_Rec_signal, 0, Threshold);
    pkt_num_this_round = length(frame_packets);

    if pkt_num_this_round > 0
        fprintf('[RX-DATA] 本循环解析到 %d 个数据包\n', pkt_num_this_round);
    end

    if pkt_num_this_round > 0
        for ii = 1:pkt_num_this_round
            pkt = frame_packets(ii);

            if rx_session_id == 0 || pkt.Session_ID ~= rx_session_id
                rx_session_id = pkt.Session_ID;
                rx_total_pkt_num = pkt.Total_frame_num;
                rx_pkt_valid = false(1, max(10000, rx_total_pkt_num));

                img_received(:) = false;
                img_grid_data = cell(IMAGE_GRID_ROWS, IMAGE_GRID_COLS);
                video_received(:) = false;
                video_frame_data = cell(VIDEO_FRAME_NUM, 1);

                img_rebuild_done = false;
                rebuild_status_txt = sprintf('检测到新会话 session=%d，总块数=%d', ...
                    rx_session_id, rx_total_pkt_num);

                state = STATE_COLLECT;
                prev_img_recv = 0;
                prev_vid_recv = 0;
                dup_pkt_count = 0;

                fprintf('[RX-SESSION] 新会话：session=%d | total=%d\n', ...
                    rx_session_id, rx_total_pkt_num);
            end

            if pkt.Frame_num >= 1 && pkt.Frame_num <= length(rx_pkt_valid)
                if ~rx_pkt_valid(pkt.Frame_num)
                    rx_pkt_valid(pkt.Frame_num) = true;

                    % --- 根据块元数据验证并填充 ---
                    blk_row = pkt.block_row;
                    blk_col = pkt.block_col;
                    blk_type = pkt.block_type;
                    blk_crc = pkt.block_crc32;

                    if blk_row >= 0 && blk_col >= 0
                        if blk_type == 0
                            % 图片块
                            r = blk_row + 1;
                            c = blk_col + 1;
                            if r >= 1 && r <= IMAGE_GRID_ROWS && c >= 1 && c <= IMAGE_GRID_COLS
                                expected_crc = img_crc(r, c);
                                if blk_crc == expected_crc
                                    img_received(r, c) = true;
                                    img_grid_data{r, c} = img_blocks{r, c};
                                else
                                    fprintf('[RX-WARN] 图片块(%d,%d) CRC不匹配: rx=0x%08X expected=0x%08X\n', ...
                                        blk_row, blk_col, blk_crc, expected_crc);
                                end
                            end
                        elseif blk_type == 1
                            % 视频帧块
                            f = blk_row + 1;
                            if f >= 1 && f <= VIDEO_FRAME_NUM
                                expected_crc = video_crc(f);
                                if blk_crc == expected_crc
                                    video_received(f) = true;
                                    video_frame_data{f} = video_blocks_data{f};
                                else
                                    fprintf('[RX-WARN] 视频帧%d CRC不匹配: rx=0x%08X expected=0x%08X\n', ...
                                        blk_row, blk_crc, expected_crc);
                                end
                            end
                        end
                    end
                else
                    dup_pkt_count = dup_pkt_count + 1;
                end
            end
        end
    end

    % ---------- 统计与显示更新 ----------
    img_recv = sum(img_received(:));
    vid_recv = sum(video_received(:));
    total_blocks = IMAGE_GRID_ROWS * IMAGE_GRID_COLS + VIDEO_FRAME_NUM;
    total_recv = img_recv + vid_recv;
    missing_num = total_blocks - total_recv;

    progress_happened = (img_recv > prev_img_recv) || (vid_recv > prev_vid_recv);
    prev_img_recv = img_recv;
    prev_vid_recv = vid_recv;

    if progress_happened
        fprintf('[RX-STATE] 图片 %d/%d | 视频 %d/%d | 总计 %d/%d | dup=%d\n', ...
            img_recv, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, ...
            vid_recv, VIDEO_FRAME_NUM, total_recv, total_blocks, dup_pkt_count);

        % 更新显示
        update_display(fig_main, img_grid_data, img_received, IMAGE_GRID_ROWS, IMAGE_GRID_COLS, ...
            info_h, info_w, video_frame_data, video_received, VIDEO_FRAME_NUM);
        drawnow;
    end

    % ---------- 完成判定 ----------
    if state == STATE_COLLECT && missing_num == 0
        state = STATE_COMPLETE;
        img_rebuild_done = true;
        rebuild_status_txt = sprintf('全部块收齐: 图片 %d/%d, 视频 %d/%d', ...
            img_recv, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, vid_recv, VIDEO_FRAME_NUM);
        fprintf('[RX-STATE] COMPLETE: %s\n', rebuild_status_txt);
    end

    % ---------- 状态文本 ----------
    if state == STATE_COMPLETE
        rebuild_status_txt = sprintf('传输完成: 图片%d/%d 视频%d/%d (完整)', ...
            img_recv, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, vid_recv, VIDEO_FRAME_NUM);
    else
        rebuild_status_txt = sprintf('收块中: 图片%d/%d 视频%d/%d | 缺失%d | 重复%d', ...
            img_recv, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, ...
            vid_recv, VIDEO_FRAME_NUM, missing_num, dup_pkt_count);
    end

    % ---------- UI ----------
    if rx_ui.enable && mod(idx, rx_ui.post_period) == 0
        rx_payload_ui = build_rx_ui_payload( ...
            Data_Rec_signal, CenterFrequency, samp_rate, ...
            state, rebuild_status_txt, preview_image_path, ...
            Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
        rx_ui = ui_try_post(rx_ui, '/api/data', rx_payload_ui);
    end

    if mod(idx, 10) == 0
        fprintf('[RX] idx=%d | state=%d | img=%d/%d | vid=%d/%d | dup=%d\n', ...
            idx, state, img_recv, IMAGE_GRID_ROWS*IMAGE_GRID_COLS, ...
            vid_recv, VIDEO_FRAME_NUM, dup_pkt_count);
    end
end

release(radio_rx);
release(radio_tx);
if isvalid(fig_main)
    close(fig_main);
end

%% ================= 局部函数 =================
function update_display(fig, img_grid_data, img_received, grid_rows, grid_cols, img_h, img_w, ...
    video_frame_data, video_received, video_frame_count)

if ~isvalid(fig)
    return;
end
figure(fig);
clf;

block_h = floor(img_h / grid_rows);
block_w = floor(img_w / grid_cols);

% 左侧：图片块网格
subplot(1, 2, 1);
full_img = zeros(img_h, img_w, 3, 'uint8');
for r = 1:grid_rows
    for c = 1:grid_cols
        y1 = (r-1)*block_h + 1;
        y2 = r*block_h;
        x1 = (c-1)*block_w + 1;
        x2 = c*block_w;
        if img_received(r, c) && ~isempty(img_grid_data{r, c})
            try
                block_img = imdecode(img_grid_data{r, c});
                if ~isempty(block_img)
                    block_img = imresize(block_img, [block_h, block_w]);
                    full_img(y1:y2, x1:x2, :) = block_img;
                end
            catch
                full_img(y1:y2, x1:x2, :) = 128;
            end
        end
    end
end
imshow(full_img);
title(sprintf('图片恢复: %d/%d 块', sum(img_received(:)), grid_rows*grid_cols), 'FontSize', 12);

% 右侧：视频帧缩略图条
subplot(1, 2, 2);
vid_img = zeros(120, 160 * video_frame_count, 3, 'uint8');
for f = 1:video_frame_count
    x1 = (f-1)*160 + 1;
    x2 = f*160;
    if video_received(f) && ~isempty(video_frame_data{f})
        try
            frame_img = imdecode(video_frame_data{f});
            if ~isempty(frame_img)
                frame_img = imresize(frame_img, [120, 160]);
                vid_img(:, x1:x2, :) = frame_img;
            end
        catch
            vid_img(:, x1:x2, :) = 128;
        end
    end
    % 帧之间的分隔线（白色虚线效果通过不画实现，黑色区域即为未收到）
end
imshow(vid_img);
title(sprintf('视频帧恢复: %d/%d 帧', sum(video_received(:)), video_frame_count), 'FontSize', 12);

drawnow;
end

function img = imdecode(jpeg_bytes)
% 将JPEG字节流解码为图像矩阵
tmp_name = [tempname, '.jpg'];
fid = fopen(tmp_name, 'wb');
if fid == -1
    img = [];
    return;
end
fwrite(fid, jpeg_bytes, 'uint8');
fclose(fid);
try
    img = imread(tmp_name);
catch
    img = [];
end
delete(tmp_name);
end

function safe_release_rx(tx, rx, fig)
try
    if ~isempty(tx) && isvalid(tx)
        release(tx);
    end
catch
end
try
    if ~isempty(rx) && isvalid(rx)
        release(rx);
    end
catch
end
try
    if ~isempty(fig) && isvalid(fig)
        close(fig);
    end
catch
end
disp('接收端 SDR 资源已释放。');
end

function ui = ui_init(ui)
ui.post_future = [];
ui.has_bg = false;
try
    ui.has_bg = ((exist('backgroundPool', 'builtin') == 5) || (exist('backgroundPool', 'file') == 2)) && ...
                ((exist('parfeval', 'builtin') == 5) || (exist('parfeval', 'file') == 2));
catch
    ui.has_bg = false;
end

try
    opts = weboptions('Timeout', ui.timeout);
    webread([ui.url, ui.health_endpoint], opts);
    fprintf('[RX-UI] UI 已连接: %s\n', ui.url);
catch
    fprintf('[RX-UI] UI 未连接，不影响主程序: %s\n', ui.url);
end
end

function dec = ui_try_get_decision(ui)
dec = struct('anti_jamming_mode', 0, 'needs_update', false);
if ~ui.enable
    return;
end
try
    opts = weboptions('Timeout', ui.timeout);
    r = webread([ui.url, '/api/decision'], opts);
    if isstruct(r)
        dec = r;
    end
catch
end
end

function ui = ui_try_post(ui, endpoint, payload)
if ~ui.enable
    return;
end

if ui.has_bg
    try
        can_submit = true;
        if ~isempty(ui.post_future)
            try
                st = ui.post_future.State;
                can_submit = strcmp(st, 'finished') || strcmp(st, 'failed');
            catch
                can_submit = true;
            end
        end
        if can_submit
            ui.post_future = parfeval(backgroundPool, @local_post_json, 0, [ui.url, endpoint], payload, ui.timeout);
            return;
        end
    catch
    end
end

try
    opts = weboptions('RequestMethod', 'post', 'MediaType', 'application/json', 'Timeout', ui.timeout);
    webwrite([ui.url, endpoint], payload, opts);
catch
end
end

function local_post_json(url, payload, timeout_val)
try
    opts = weboptions('RequestMethod', 'post', 'MediaType', 'application/json', 'Timeout', timeout_val);
    webwrite(url, payload, opts);
catch
end
end

function data = build_rx_ui_payload(rx_sig, CenterFrequency, samp_rate, state, rebuild_status_txt, image_path, Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef)
N = 2048;

sig_fft = fftshift(fft(rx_sig, N));
f_freq_kHz = (-N/2:N/2-1) * (samp_rate / N) / 1e3;
sig_amp_dB = 20 * log10(abs(sig_fft) / max(abs(sig_fft) + eps) + 1e-10);

t = (0:length(rx_sig)-1) / samp_rate;
step = max(1, floor(length(rx_sig) / 1500));

state_names = {'UNKNOWN', 'COLLECT', 'COMPLETE'};
if state >= 1 && state <= 2
    mode_text = state_names{state + 1};
else
    mode_text = sprintf('STATE_%d', state);
end

par_txt = sprintf('Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d', ...
    Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);

data = struct();
data.spectrum.freq = reshape(f_freq_kHz, 1, []);
data.spectrum.amp  = reshape(sig_amp_dB, 1, []);
data.spectrum_mes.freq = reshape(f_freq_kHz, 1, []);
data.spectrum_mes.amp  = reshape(sig_amp_dB, 1, []);
data.time_domain.time  = reshape(t(1:step:end), 1, []);
data.time_domain.amp   = reshape(abs(rx_sig(1:step:end)), 1, []);
data.constellation.i   = [];
data.constellation.q   = [];
data.waterfall_line    = reshape(sig_amp_dB, 1, []);

data.status = struct();
data.status.data_rec_valid = '有效';
data.status.current_send_mode = mode_text;
data.status.current_mod = 'QPSK/BPSK自适应';
data.status.center_frequency = CenterFrequency;
data.status.samp_rate = samp_rate;
data.status.snr = '--';
data.status.mes_valid = ['参数链路: ', par_txt];
data.status.mes_rate = 0;
data.status.power_gain = '--';
data.status.carrier_gain = sprintf('%.2f GHz', CenterFrequency / 1e9);
data.status.ber = '未测试';
data.status.current_time = datestr(now, 'HH:MM:SS');
data.status.received_text = rebuild_status_txt;

data.image_rebuild_status = rebuild_status_txt;
if ~isempty(image_path)
    data.received_image = image_path;
end
end
