% =========== 发射端：分块渐进式传输 + 空闲等待 + 固定轮次 ===========
clear
clc
close all force
warning('off', 'all');

fprintf('\n==================== 发射端（分块渐进式传输）启动 ====================\n');

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
BUS_SLOT_SAMPLES = 160000;
FB_RX_SAMPLES    = 60000;

BURST_PKTS    = 10;
GUARD_PRE     = 8000;
GUARD_BETWEEN = 1200;
GUARD_POST    = 8000;

% ---- 新增：固定轮次 + 空闲等待 ----
NUM_ROUNDS       = 2;
IDLE_SLOTS       = 3;
IMAGE_GRID_ROWS  = 8;
IMAGE_GRID_COLS  = 8;
VIDEO_FRAME_NUM  = 20;

TX_MODE = 1;  % 1=仅图像, 2=仅视频, 3=图像+视频

STATE_SENDING = 1;
STATE_IDLE    = 2;
STATE_DONE    = 3;

Carrier_set = 2e9 : 0.5e9 : 4e9;
Power_set = 2e-1 : 1e-1 : 8e-1;
Power_gain_set = 0 : 1 : 30;

Anti_Jamming_Mode = 0;
Carrier_select_rec = 3;
Trans_power_select_rec = 7;
Power_gain_select_rec = 15;

CenterFrequency = Carrier_set(Carrier_select_rec);
Power = Power_set(Trans_power_select_rec);
Power_gain = Power_gain_set(Power_gain_select_rec);

Carrier_select_rec_bef = Carrier_select_rec;
Power_gain_select_rec_bef = Power_gain_select_rec;
Anti_Jamming_Mode_bef = Anti_Jamming_Mode;

script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir)
    script_dir = pwd;
end
addpath(script_dir);

%% ================= 预处理媒体为块（按 TX_MODE） =================
mode_names = {'', '仅图像', '仅视频', '图像+视频'};
fprintf('[TX-INIT] 发送模式: %s\n', mode_names{TX_MODE});

block_meta = [];
img_path = fullfile(script_dir, 'p2.jpg');
video_path = fullfile(script_dir, '视频.mp4');

if ismember(TX_MODE, [1, 3])
    fprintf('[TX-INIT] 预处理图片...\n');
    [~, img_crc] = preprocess_image(img_path, IMAGE_GRID_ROWS, IMAGE_GRID_COLS);
    for r = 1:IMAGE_GRID_ROWS
        for c = 1:IMAGE_GRID_COLS
            blk.row = r - 1;
            blk.col = c - 1;
            blk.total_rows = IMAGE_GRID_ROWS;
            blk.total_cols = IMAGE_GRID_COLS;
            blk.crc32 = img_crc(r, c);
            blk.type = 0;
            block_meta = [block_meta, blk];
        end
    end
end

if ismember(TX_MODE, [2, 3])
    fprintf('[TX-INIT] 预处理视频...\n');
    [~, video_crc] = preprocess_video(video_path, VIDEO_FRAME_NUM);
    for f = 1:VIDEO_FRAME_NUM
        blk.row = f - 1;
        blk.col = 0;
        blk.total_rows = VIDEO_FRAME_NUM;
        blk.total_cols = 1;
        blk.crc32 = video_crc(f);
        blk.type = 1;
        block_meta = [block_meta, blk];
    end
end

session_id = 1;
[~, tx_cache] = Data_trans_sig_Gen(Anti_Jamming_Mode, block_meta, [], session_id);
total_pkts = tx_cache.total_pkt_num;

img_blocks_count = IMAGE_GRID_ROWS * IMAGE_GRID_COLS;
vid_blocks_count = VIDEO_FRAME_NUM;
fprintf('[TX-INIT] session=%d | 总块数=%d | CF=%.2f GHz | Gain=%d dB\n', ...
    session_id, total_pkts, CenterFrequency/1e9, Power_gain);

%% ================= 状态机初始化 =================
state = STATE_SENDING;
sweep_ptr = 1;
round_count = 1;
idle_cnt = 0;

%% ================= UI 配置（发射端） =================
tx_ui.enable = true;
tx_ui.url = 'http://127.0.0.1:5001';
tx_ui.health_endpoint = '/api/control';
tx_ui.post_period = 10;
tx_ui.ctrl_period = 20;
tx_ui.timeout = 0.03;
tx_ui = ui_init(tx_ui);

%% ================= SDR 初始化 =================
radio_tx = comm.SDRuTransmitter('Platform','X310','IPAddress','192.168.10.2');
radio_tx.ChannelMapping = 1;
radio_tx.CenterFrequency = CenterFrequency;
radio_tx.Gain = Power_gain;
radio_tx.MasterClockRate = 200e6;
radio_tx.InterpolationFactor = 512;
radio_tx.ClockSource = 'External';
radio_tx.UnderrunOutputPort = true;

% 反向链路接收（保留硬件初始化，但不依赖其数据做决策）
radio_rx = comm.SDRuReceiver( ...
    'Platform','X310', ...
    'IPAddress','192.168.10.2', ...
    'OutputDataType','double', ...
    'MasterClockRate',200e6, ...
    'DecimationFactor',512, ...
    'SamplesPerFrame',FB_RX_SAMPLES);
radio_rx.ClockSource = 'External';
radio_rx.ChannelMapping = 1;
radio_rx.CenterFrequency = 1.45e9;
radio_rx.Gain = 10;
radio_rx.OverrunOutputPort = true;

cleanupObj = onCleanup(@() safe_release_txrx(radio_tx, radio_rx));

%% ================= 主循环 =================
for idx = 1:200000
    burst_list = [];
    Par_Rec_signal = zeros(FB_RX_SAMPLES, 1);

    % ---------- 状态机 ----------
    switch state
        case STATE_SENDING
            burst_end = min(sweep_ptr + BURST_PKTS - 1, total_pkts);
            burst_list = sweep_ptr:burst_end;
            tx_sig = build_tx_slot(tx_cache, burst_list, BUS_SLOT_SAMPLES, GUARD_PRE, GUARD_BETWEEN, GUARD_POST);

            sweep_ptr = burst_end + 1;
            if sweep_ptr > total_pkts
                sweep_ptr = 1;
                round_count = round_count + 1;
                fprintf('[TX-ROUND] 完成第 %d 轮发送\n', round_count);

                if round_count > NUM_ROUNDS
                    state = STATE_DONE;
                    fprintf('[TX-DONE] 全部 %d 轮发送完成，停止发射\n', NUM_ROUNDS);
                else
                    state = STATE_IDLE;
                    idle_cnt = IDLE_SLOTS;
                end
            else
                state = STATE_IDLE;
                idle_cnt = IDLE_SLOTS;
            end

        case STATE_IDLE
            tx_sig = zeros(BUS_SLOT_SAMPLES, 1);
            idle_cnt = idle_cnt - 1;
            if idle_cnt <= 0
                state = STATE_SENDING;
            end

        case STATE_DONE
            tx_sig = zeros(BUS_SLOT_SAMPLES, 1);
    end

    tx_sig = sqrt(Power) * 0.1 * tx_sig;

    % ---------- 硬件收发 ----------
    try
        tx_underrun = radio_tx(tx_sig);
        [Par_Rec_signal, ~, rx_overrun] = radio_rx();

        if tx_underrun
            warning('[TX-WARN] Underrun');
        end
        if rx_overrun
            % 反向链路 overrun 不影响主链路，静默
        end
    catch ME
        warning('[TX-ERR] 硬件异常：%s', ME.message);
        continue;
    end

    % ---------- 反向链路解析（尽力而为，不依赖） ----------
    [Par_Datavalid, Carrier_select_new, Trans_power_select_new, Power_gain_select_new, Anti_Jamming_Mode_new, ~] = ...
        Par_Rece_sig_Gen(Par_Rec_signal);

    if Par_Datavalid == 1
        fprintf('[TX-PAR] 收到反向参数: Carrier=%d | Power=%d | Gain=%d | Mode=%d\n', ...
            Carrier_select_new, Trans_power_select_new, Power_gain_select_new, Anti_Jamming_Mode_new);

        if Anti_Jamming_Mode_bef ~= Anti_Jamming_Mode_new
            Anti_Jamming_Mode_bef = Anti_Jamming_Mode_new;
            [~, tx_cache] = Data_trans_sig_Gen(Anti_Jamming_Mode_bef, block_meta, [], session_id);
            total_pkts = tx_cache.total_pkt_num;
            fprintf('[TX-PAR] Anti_Jamming_Mode 已更新为 %d\n', Anti_Jamming_Mode_bef);
        end

        if Carrier_select_rec_bef ~= Carrier_select_new || ...
           Power_gain_select_rec_bef ~= Power_gain_select_new || ...
           Trans_power_select_rec ~= Trans_power_select_new

            Carrier_select_rec_bef = Carrier_select_new;
            Power_gain_select_rec_bef = Power_gain_select_new;
            Trans_power_select_rec = Trans_power_select_new;

            CenterFrequency = Carrier_set(Carrier_select_new);
            Power_gain = Power_gain_set(Power_gain_select_new);
            Power = Power_set(Trans_power_select_new);

            radio_tx.CenterFrequency = CenterFrequency;
            radio_tx.Gain = Power_gain;

            fprintf('[TX-PAR] 参数已应用 -> CF=%.2f GHz | Gain=%d dB | PowerIdx=%d\n', ...
                CenterFrequency/1e9, Power_gain, Trans_power_select_rec);
        end
    end

    % ---------- UI ----------
    if tx_ui.enable && mod(idx, tx_ui.post_period) == 0
        tx_payload_ui = build_tx_ui_payload( ...
            tx_sig, Par_Rec_signal, CenterFrequency, Power_gain, samp_rate, ...
            state, session_id, total_pkts, img_path, burst_list, round_count, ...
            Carrier_select_rec_bef, Trans_power_select_rec, Power_gain_select_rec_bef, Anti_Jamming_Mode_bef);
        tx_ui = ui_try_post(tx_ui, '/api/data', tx_payload_ui);
    end

    if mod(idx, 10) == 0
        state_names = {'SENDING', 'IDLE', 'DONE'};
        fprintf('[TX] idx=%d | %s | round=%d/%d | burst=%s | ptr=%d\n', ...
            idx, state_names{state}, round_count, NUM_ROUNDS, ...
            mat2str(burst_list), sweep_ptr);
    end

    if state == STATE_DONE
        % 发送完毕后等待一小段再退出，让接收机处理完最后的数据
        if idx > 100 && sweep_ptr == 1
            fprintf('[TX] 传输结束，退出。\n');
            break;
        end
    end
end

release(radio_rx);
release(radio_tx);

%% ================= 局部函数 =================
function sig_out = build_tx_slot(tx_cache, pkt_list, slot_len, guard_pre, guard_between, guard_post)
sig_out = zeros(slot_len, 1);
wr = guard_pre + 1;
for ii = 1:length(pkt_list)
    k = pkt_list(ii);
    one_wave = tx_cache.waveforms{k};
    L = length(one_wave);
    if wr + L - 1 > slot_len - guard_post
        break;
    end
    sig_out(wr:wr + L - 1) = one_wave;
    wr = wr + L + guard_between;
end
end

function safe_release_txrx(tx, rx)
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
disp('发射端 SDR 资源已释放。');
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
    fprintf('[TX-UI] UI 已连接: %s\n', ui.url);
catch
    fprintf('[TX-UI] UI 未连接，不影响主程序: %s\n', ui.url);
end
end

function ctrl = ui_try_get_control(ui)
ctrl = struct('apply', false, 'str', '');
if ~ui.enable
    return;
end
try
    opts = weboptions('Timeout', ui.timeout);
    r = webread([ui.url, '/api/control'], opts);
    if isstruct(r)
        ctrl = r;
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

function data = build_tx_ui_payload(tx_sig, fb_sig, CenterFrequency, Power_gain, samp_rate, ...
    state, session_id, total_pkts, img_file_name, burst_list, round_count, ...
    Carrier_select_rec, Trans_power_select_rec, Power_gain_select_rec, Anti_Jamming_Mode_rec)

N = 2048;
sig_fft = fftshift(fft(tx_sig, N));
f_freq = linspace(-samp_rate / 2, samp_rate / 2, length(sig_fft));
sig_amp_dB = 20 * log10(abs(sig_fft) / max(abs(sig_fft) + eps) + 1e-10);

step_tx = max(1, floor(length(tx_sig) / 1500));
time_tx = (0:step_tx:length(tx_sig)-1) / samp_rate * 1000;
amp_tx = abs(tx_sig(1:step_tx:end));

time_len_fb = min(3000, length(fb_sig));
time_fb = (0:time_len_fb-1) / samp_rate * 1000;
amp_fb = abs(fb_sig(1:time_len_fb));

if isempty(burst_list)
    burst_text = '[]';
else
    burst_text = mat2str(burst_list);
end

state_names = {'SENDING', 'IDLE', 'DONE'};
state_text = 'UNKNOWN';
if state >= 1 && state <= 3
    state_text = state_names{state};
end

par_txt = sprintf('Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d', ...
    Carrier_select_rec, Trans_power_select_rec, Power_gain_select_rec, Anti_Jamming_Mode_rec);

data = struct();
data.tx_spec.freq = reshape(f_freq / 1e3, 1, []);
data.tx_spec.amp  = reshape(sig_amp_dB, 1, []);
data.tx_time.time = reshape(time_tx, 1, []);
data.tx_time.amp  = reshape(amp_tx, 1, []);
data.rx_const.i   = [];
data.rx_const.q   = [];
data.rx_time.time = reshape(time_fb, 1, []);
data.rx_time.amp  = reshape(amp_fb, 1, []);

data.status = struct();
data.status.tx_valid = '有效';
data.status.tx_mod = 'QPSK/BPSK自适应';
data.status.tx_mode = sprintf('分块渐进 | %s | session=%d | total=%d | round=%d/%d | burst=%s', ...
    state_text, session_id, total_pkts, round_count, 999, burst_text);
data.status.tx_carrier = sprintf('%.2f GHz', CenterFrequency / 1e9);
data.status.tx_samp = sprintf('%.2f kHz', samp_rate / 1e3);
data.status.tx_gain = sprintf('%d dB', Power_gain);
data.status.rx_state = ['反向参数链路: ', par_txt];
data.status.rx_carrier = '1.45 GHz';
data.status.rx_tx_gain = '--';
data.status.rx_tx_carrier = '--';
data.status.time = ['更新时间: ', datestr(now, 'HH:MM:SS')];

data.sending_image = img_file_name;
data.sending_file = img_file_name;
end
