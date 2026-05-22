function [str_rec, Rec_sig_afr, data_flag, err_valid, err_bit_num, total_num, frame_packets] = Data_Rece_sig_Gen(Anti_Jamming_Mode_select_rec, Trans_sig_data, PER_test, Threshold)
% 分块渐进式传输版：支持在一个接收 buffer 中解析多个块包

defs = link_phy_defs();

Rec_sig_afr = 1;
data_flag = 0;
err_valid = 0;
err_bit_num = 0;
total_num = 0;
str_rec = [];
frame_packets = struct('Session_ID', {}, 'Frame_num', {}, 'Total_frame_num', {}, ...
    'Payload_bytes', {}, 'ZeroPadding_num', {}, 'Payload_length_bits', {}, ...
    'block_row', {}, 'block_col', {}, 'block_total_rows', {}, 'block_total_cols', {}, ...
    'block_crc32', {}, 'block_type', {});

sps = 4;
rxfilter = comm.RaisedCosineReceiveFilter( ...
    'InputSamplesPerSymbol', sps, ...
    'DecimationFactor', 1, ...
    'RolloffFactor', 0.25);

pcmatrix = ldpcQuasiCyclicMatrix(defs.blockSize, defs.P);
cfgLDPCDec = ldpcDecoderConfig(pcmatrix);
crcdetector = comm.CRCDetector(defs.poly);

if Anti_Jamming_Mode_select_rec == 1
    M = 2;
    sf = 15;
    demodulator = comm.PSKDemodulator(M, 'BitOutput', true, 'DecisionMethod', 'Approximate log-likelihood ratio');
    demodulator.PhaseOffset = pi;
    data_frame_len = 648 / log2(M) * sf;
else
    M = 4;
    sf = 1;
    demodulator = comm.PSKDemodulator(M, 'BitOutput', true, 'DecisionMethod', 'Approximate log-likelihood ratio');
    demodulator.PhaseOffset = pi/4;
    data_frame_len = 648 / log2(M);
end

pay_load_length_num = 44;
Rec_sig = rxfilter(Trans_sig_data);

data_sys = [];
buffer_h = [];
index_val = zeros(1, sps);
index_loc_h = cell(1, sps);
syn_flag = 0;

for i = 1:sps
    data_sys(:, i) = Rec_sig(i:sps:end);
    buffer_h(:, i) = abs(conv(flip(defs.head_data), sign(data_sys(:, i))));
    cand = pick_sync_peaks(buffer_h(:, i), Threshold);

    if ~isempty(cand)
        syn_flag = 1;
        index_loc_h{i} = cand(:);
        index_val(i) = mean(buffer_h(cand, i));
    else
        index_loc_h{i} = [];
    end
end

if syn_flag == 0
    return;
end

[~, op_index] = max(index_val);
Rec_sig_afr_temp = data_sys(:, op_index);
index_start_temp = index_loc_h{op_index};

if isempty(index_start_temp)
    return;
end

if index_start_temp(end) + data_frame_len > length(Rec_sig_afr_temp)
    index_start_temp = index_start_temp(index_start_temp + data_frame_len <= length(Rec_sig_afr_temp));
end

if isempty(index_start_temp)
    return;
end

seen_frames = [];

for j = 1:length(index_start_temp)
    index_start = index_start_temp(j);
    if index_start + data_frame_len > length(Rec_sig_afr_temp)
        continue;
    end

    train_len = min(511, index_start);
    receive_train_seq_tem = Rec_sig_afr_temp(index_start-train_len+1:index_start);
    desire_seq = defs.head_data(end-train_len+1:end);
    temp = conj(desire_seq) .* receive_train_seq_tem;
    phase_est = -angle(mean(temp));

    Rec_sig_afr = Rec_sig_afr_temp(index_start+1:index_start+data_frame_len) .* exp(1j * phase_est);
    demod_signal = demodulator(Rec_sig_afr);

    if Anti_Jamming_Mode_select_rec == 1
        data_desp = zeros(length(demod_signal)/sf, 1);
        for ii = 1:length(demod_signal)/sf
            data_desp(ii) = sum(demod_signal((ii-1)*sf+1:ii*sf) .* defs.pn_data);
        end
    else
        data_desp = demod_signal;
    end

    deinter_matrix = reshape(data_desp, 18, 36).';
    de_interleaved_data = deinter_matrix(:);

    received_bits = ldpcDecode(de_interleaved_data, cfgLDPCDec, 10);
    de_scr_data = descramble_bits(received_bits, defs.scr_seq);

    [data_rec, err] = crcdetector(de_scr_data(1:end-length(defs.data_frame_end)));

    if err ~= 0
        continue;
    end

    session_id = bits_to_int(data_rec(8+8+8+1 : 8+8+8+16));
    total_frame_num_rec = bits_to_int(data_rec(8+8+8+16+1 : 8+8+8+16+16));
    frame_num_rec = bits_to_int(data_rec(8+8+8+16+16+1 : 8+8+8+16+16+16));
    payload_length_rec = bits_to_int(data_rec(8+8+8+16+16+16+1 : 8+8+8+16+16+16+16));
    zero_padding_num_rec = bits_to_int(data_rec(8+8+8+16+16+16+16+1 : 8+8+8+16+16+16+16+9));

    payload_bits_all = data_rec(8+8+8+16+16+16+16+9+1 : 8+8+8+16+16+16+16+9+pay_load_length_num*8);
    payload_bits = payload_bits_all(1:payload_length_rec);

    if isempty(payload_bits) || mod(length(payload_bits), 8) ~= 0
        continue;
    end

    payload_bytes = bits_to_bytes(payload_bits);

    if any(seen_frames == frame_num_rec)
        continue;
    end
    seen_frames(end+1) = frame_num_rec; %#ok<AGROW>

    one_pkt = struct();
    one_pkt.Session_ID = session_id;
    one_pkt.Frame_num = frame_num_rec;
    one_pkt.Total_frame_num = total_frame_num_rec;
    one_pkt.Payload_bytes = payload_bytes;
    one_pkt.ZeroPadding_num = zero_padding_num_rec;
    one_pkt.Payload_length_bits = payload_length_rec;

    % 解析块元数据: row(1) col(1) total_rows(1) total_cols(1) type(1) crc32(4)
    if length(payload_bytes) >= 9
        one_pkt.block_row = double(payload_bytes(1));
        one_pkt.block_col = double(payload_bytes(2));
        one_pkt.block_total_rows = double(payload_bytes(3));
        one_pkt.block_total_cols = double(payload_bytes(4));
        one_pkt.block_type = double(payload_bytes(5));
        one_pkt.block_crc32 = typecast(payload_bytes(6:9), 'uint32');
    else
        one_pkt.block_row = -1;
        one_pkt.block_col = -1;
        one_pkt.block_total_rows = 0;
        one_pkt.block_total_cols = 0;
        one_pkt.block_type = -1;
        one_pkt.block_crc32 = uint32(0);
    end

    frame_packets(end+1) = one_pkt; %#ok<AGROW>
    str_rec = payload_bytes;
    data_flag = 1;
end

if PER_test == 1 && data_flag == 1
    total_num = 1;
    err_valid = 0;
    err_bit_num = 0;
end

end

function cand = pick_sync_peaks(metric, thr)
raw_idx = find(metric >= thr);
cand = [];
if isempty(raw_idx)
    return;
end

group_gap = 20;
st = 1;
while st <= length(raw_idx)
    ed = st;
    while ed < length(raw_idx) && (raw_idx(ed+1) - raw_idx(ed)) <= group_gap
        ed = ed + 1;
    end
    group = raw_idx(st:ed);
    [~, loc] = max(metric(group));
    cand(end+1,1) = group(loc); %#ok<AGROW>
    st = ed + 1;
end
end

function out = descramble_bits(in, scr_seq)
out = zeros(size(in));
grp = length(scr_seq);
for ii = 1:length(in)/grp
    st = (ii-1)*grp + 1;
    ed = ii*grp;
    out(st:ed) = xor(in(st:ed), scr_seq);
end
end

function v = bits_to_int(bits)
v = (2.^(length(bits)-1:-1:0)) * bits(:);
end

function u8 = bits_to_bytes(bits)
bit_str = char(bits(:).' + '0');
bin_chars = reshape(bit_str, 8, []).';
u8 = uint8(bin2dec(bin_chars));
end
