% =========== 接收端：UDP被动拼包 + 原始参数反向链路复原版 + UI ===========
clear
clc
close all force
warning('off', 'all');

fprintf('\n==================== 接收端（UDP被动拼包 + 原始参数反向链路）启动 ====================\n');

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
FB_TX_SAMPLES  = 60000;   % 按原始基准版反向链路长度复原

STATE_COLLECT  = 1;
STATE_COMPLETE = 2;

Carrier_set = 2e9 : 0.5e9 : 4e9;
Power_gain_set = 0 : 1 : 30;

Anti_Jamming_Mode_bef = 0;
Carrier_select_bef = 3;
Trans_power_select_bef = 7;
Power_gain_select_bef = 15;

CenterFrequency = Carrier_set(Carrier_select_bef);

CONTROL_TX_INTERVAL = 10;   % 周期性发送参数信令

%% ================= UI 配置（接收端） =================
rx_ui.enable = true;
rx_ui.url = 'http://127.0.0.1:5000';
rx_ui.health_endpoint = '/api/health';
rx_ui.post_period = 10;
rx_ui.ctrl_period = 20;
rx_ui.timeout = 0.03;
rx_ui = ui_init(rx_ui);

%% ================= SDR 初始化 =================
disp('正在初始化 USRP 硬件，请稍候...');

radio_tx = comm.SDRuTransmitter('Platform','X310','IPAddress','192.168.10.2');
radio_tx.ChannelMapping = 1;
radio_tx.CenterFrequency = 1.45e9;   % 反向参数链路
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

cleanupObj = onCleanup(@() safe_release_rx(radio_tx, radio_rx));
disp('USRP 硬件初始化完成！');

%% ================= 接收缓存 =================
rx_session_id = 0;
rx_total_pkt_num = 0;
rx_zero_padding_bits = 0;
rx_pkt_store = cell(1, 10000);
rx_pkt_valid = false(1, 10000);

img_rebuild_done = false;
recovered_image_path = '';
recovered_file_path = '';
preview_image_path = '';
rebuild_status_txt = '等待接收图片分包...';

state = STATE_COLLECT;
trans_sigs = zeros(FB_TX_SAMPLES, 1);

prev_recv_num = 0;
dup_pkt_count = 0;
last_preview_contig_num = -1;

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
                fprintf('[RX-UI] 反向链路参数更新 -> Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d\n', ...
                    Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
            end
        end
    end

    % ---------- 周期性生成原始参数反馈信令 ----------
    if state == STATE_COMPLETE
        % COMPLETE 后不再发参数，避免干扰
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

            fprintf('[RX-PAR] 发送参数信令 -> Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d\n', ...
                Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
        else
            trans_sigs = zeros(FB_TX_SAMPLES, 1);
        end
    end

    % ---------- 硬件收发 ----------
    try
        [Data_Rec_signal, ~, rx_overrun] = radio_rx();
        tx_underrun = radio_tx(trans_sigs);

        if rx_overrun
            warning('[RX-WARN] Overrun');
        end
        if tx_underrun
            warning('[RX-WARN] 参数链路 Underrun');
        end
    catch ME
        warning('[RX-ERR] 硬件异常：%s', ME.message);
        continue;
    end

    % ---------- 动态调门限 / 增益 ----------
    if rx_total_pkt_num > 0
        recv_num_tmp = sum(rx_pkt_valid(1:rx_total_pkt_num));
        missing_num_tmp = rx_total_pkt_num - recv_num_tmp;

        if missing_num_tmp <= 32
            Threshold = 195;
            radio_rx.Gain = 18;
        elseif missing_num_tmp <= 96
            Threshold = 210;
            radio_rx.Gain = 16;
        else
            Threshold = 240;
            radio_rx.Gain = 10;
        end
    end

    % ---------- 被动拼包接收 ----------
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
                rx_zero_padding_bits = pkt.ZeroPadding_num;
                rx_pkt_store = cell(1, max(10000, rx_total_pkt_num));
                rx_pkt_valid = false(1, max(10000, rx_total_pkt_num));

                img_rebuild_done = false;
                recovered_image_path = '';
                recovered_file_path = '';
                preview_image_path = '';
                rebuild_status_txt = sprintf('检测到新会话 session=%d，总包数=%d', ...
                    rx_session_id, rx_total_pkt_num);

                state = STATE_COLLECT;
                prev_recv_num = 0;
                dup_pkt_count = 0;
                last_preview_contig_num = -1;

                fprintf('[RX-SESSION] 新会话开始：session=%d | total_pkt=%d\n', ...
                    rx_session_id, rx_total_pkt_num);
            end

            if pkt.Frame_num >= 1 && pkt.Frame_num <= length(rx_pkt_store)
                if ~rx_pkt_valid(pkt.Frame_num)
                    rx_pkt_store{pkt.Frame_num} = pkt.Payload_bytes(:);
                    rx_pkt_valid(pkt.Frame_num) = true;
                else
                    dup_pkt_count = dup_pkt_count + 1;
                end
            end
        end
    end

    if rx_total_pkt_num > 0
        recv_num = sum(rx_pkt_valid(1:rx_total_pkt_num));
        missing_num = rx_total_pkt_num - recv_num;
        progress_happened = recv_num > prev_recv_num;
        prev_recv_num = recv_num;

        if progress_happened
            fprintf('[RX-STATE] COLLECT: 新增包后 recv=%d/%d，missing=%d，dup=%d\n', ...
                recv_num, rx_total_pkt_num, missing_num, dup_pkt_count);
        end

        % ---------- 预览图 ----------
        [preview_ok, preview_path_new, ~, contig_num] = ...
            try_rebuild_image_preview(rx_pkt_store, rx_pkt_valid, rx_total_pkt_num, pwd);
        if preview_ok
            if contig_num ~= last_preview_contig_num || isempty(preview_image_path)
                preview_image_path = preview_path_new;
                last_preview_contig_num = contig_num;
                fprintf('[RX-PREVIEW] 连续前缀=%d，预览图更新：%s\n', contig_num, preview_image_path);
            end
        end

        % ---------- 包收齐后恢复 ----------
        if state == STATE_COLLECT && missing_num == 0
            fprintf('[RX-STATE] 所有分包已收齐，开始恢复最终图片...\n');

            [recovered_image_path, rebuild_status_txt] = rebuild_received_file( ...
                rx_pkt_store, rx_total_pkt_num, rx_zero_padding_bits, pwd);
            img_rebuild_done = ~isempty(recovered_image_path);

            if img_rebuild_done
                state = STATE_COMPLETE;
                fprintf('[RX-STATE] COMPLETE: 图片恢复成功 -> %s\n', recovered_image_path);
            else
                rebuild_status_txt = '包已收齐，但恢复失败';
                fprintf('[RX-STATE] 包已收齐，但恢复失败\n');
            end
        end

        % ---------- 状态文本 ----------
        if state == STATE_COMPLETE
            if ~isempty(recovered_image_path)
                rebuild_status_txt = ['图片已完整恢复: ', recovered_image_path];
            else
                rebuild_status_txt = '图片已完整恢复';
            end
        else
            if ~isempty(preview_image_path)
                preview_prefix = sprintf('当前预览图: %s | ', preview_image_path);
            else
                preview_prefix = '';
            end

            rebuild_status_txt = sprintf('%s已收包 %d/%d，缺失 %d，重复包 %d，参数链路已复原...', ...
                preview_prefix, recv_num, rx_total_pkt_num, missing_num, dup_pkt_count);
        end
    end

    % ---------- UI ----------
    if rx_ui.enable && mod(idx, rx_ui.post_period) == 0
        image_to_show = '';
        if ~isempty(recovered_image_path)
            image_to_show = recovered_image_path;
        elseif ~isempty(preview_image_path)
            image_to_show = preview_image_path;
        end

        rx_payload_ui = build_rx_ui_payload( ...
            Data_Rec_signal, CenterFrequency, samp_rate, ...
            state, rebuild_status_txt, image_to_show, ...
            Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
        rx_ui = ui_try_post(rx_ui, '/api/data', rx_payload_ui);
    end

    if mod(idx, 10) == 0
        fprintf('[RX] idx=%d | state=%d | pkt=%d | recv=%d/%d | dup=%d | Carrier=%d | PowerIdx=%d | GainIdx=%d | Mode=%d\n', ...
            idx, state, pkt_num_this_round, ...
            max(0, min(prev_recv_num, rx_total_pkt_num)), rx_total_pkt_num, ...
            dup_pkt_count, Carrier_select_bef, Trans_power_select_bef, Power_gain_select_bef, Anti_Jamming_Mode_bef);
    end
end

release(radio_rx);
release(radio_tx);

%% ================= 局部函数 =================
function [preview_ok, preview_path, status_txt, contig_num] = try_rebuild_image_preview(rx_pkt_store, rx_pkt_valid, total_pkt_num, save_dir)
preview_ok = false;
preview_path = '';
status_txt = '';
contig_num = 0;

loc = find(~rx_pkt_valid(1:total_pkt_num), 1, 'first');
if isempty(loc)
    contig_num = total_pkt_num;
else
    contig_num = loc - 1;
end

if contig_num <= 0
    return;
end

all_bytes = [];
for pkt_id = 1:contig_num
    all_bytes = [all_bytes; rx_pkt_store{pkt_id}(:)];
end

if isempty(all_bytes)
    return;
end

img_ext_len = double(all_bytes(1));
if length(all_bytes) < 1 + img_ext_len
    return;
end

img_ext = lower(char(all_bytes(2:1 + img_ext_len)).');
img_payload = uint8(all_bytes(2 + img_ext_len:end));

if isempty(img_payload)
    return;
end

payload_cut = [];

switch img_ext
    case {'.jpg', '.jpeg'}
        idx = find(img_payload(1:end-1) == 255 & img_payload(2:end) == 217, 1, 'last');
        if isempty(idx)
            return;
        end
        payload_cut = img_payload(1:idx+1);

    case '.png'
        marker = uint8([73 69 78 68 174 66 96 130]);
        pos = find_subseq(img_payload(:).', marker(:).');
        if isempty(pos)
            return;
        end
        cut_end = pos(end) + length(marker) - 1;
        payload_cut = img_payload(1:cut_end);

    case '.bmp'
        if length(img_payload) < 6
            return;
        end
        file_size = double(img_payload(3)) + 256*double(img_payload(4)) + ...
                    65536*double(img_payload(5)) + 16777216*double(img_payload(6));
        if length(img_payload) < file_size
            return;
        end
        payload_cut = img_payload(1:file_size);

    otherwise
        return;
end

preview_name = fullfile(save_dir, ['recovered_image_preview', img_ext]);
fid = fopen(preview_name, 'wb');
if fid == -1
    return;
end
fwrite(fid, payload_cut, 'uint8');
fclose(fid);

try
    imfinfo(preview_name);
    preview_ok = true;
    preview_path = preview_name;
    status_txt = ['当前预览图已更新: ', preview_name];
catch
    preview_ok = false;
end
end

function pos = find_subseq(data_vec, pat_vec)
pos = [];
if isempty(data_vec) || isempty(pat_vec)
    return;
end
N = length(data_vec);
M = length(pat_vec);
if N < M
    return;
end
for i = 1:(N - M + 1)
    if all(data_vec(i:i+M-1) == pat_vec)
        pos(end+1) = i; %#ok<AGROW>
    end
end
end

function [recovered_image_path, status_txt] = rebuild_received_file(rx_pkt_store, total_pkt_num, zero_padding_bits, save_dir)
recovered_image_path = '';
status_txt = '图片重建失败';

all_bytes = [];
for pkt_id = 1:total_pkt_num
    all_bytes = [all_bytes; rx_pkt_store{pkt_id}(:)];
end

zero_padding_bytes = floor(zero_padding_bits / 8);
if zero_padding_bytes > 0 && length(all_bytes) > zero_padding_bytes
    all_bytes = all_bytes(1:end - zero_padding_bytes);
end

if isempty(all_bytes)
    status_txt = '图片重建失败：数据为空';
    return;
end

img_ext_len = double(all_bytes(1));
if length(all_bytes) < 1 + img_ext_len
    status_txt = '图片重建失败：文件头不完整';
    return;
end

img_ext = char(all_bytes(2:1 + img_ext_len)).';
img_payload = uint8(all_bytes(2 + img_ext_len:end));
recovered_file_name = ['recovered_image', img_ext];

fid_img = fopen(fullfile(save_dir, recovered_file_name), 'wb');
if fid_img == -1
    status_txt = '图片重建失败：无法创建文件';
    return;
end
fwrite(fid_img, img_payload, 'uint8');
fclose(fid_img);

recovered_image_path = fullfile(save_dir, recovered_file_name);
status_txt = ['图片重建完成: ', recovered_file_name];
end

function safe_release_rx(tx, rx)
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
data.status.mes_valid = ['参数链路已复原: ', par_txt];
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
