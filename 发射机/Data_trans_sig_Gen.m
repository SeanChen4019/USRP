function [Trans_sig_data, tx_cache] = Data_trans_sig_Gen(Anti_Jamming_Mode_select_rec, payload_bytes, pkt_select, session_id)
% 高速可靠传输版：将业务数据拆成很多 44B 物理包，并缓存每个包的独立波形
%
% 输入：
%   Anti_Jamming_Mode_select_rec : 0 常规QPSK；1 低速抗扰
%   payload_bytes                : uint8 字节流（图片/文本均可）
%   pkt_select                   : 需要拼接输出的包号列表，留空表示全部
%   session_id                   : 会话号，默认 1
%
% 输出：
%   Trans_sig_data               : 按 pkt_select 拼接后的复基带
%   tx_cache                     : 包缓存结构体

if nargin < 2
    error('Data_trans_sig_Gen: 输入参数不足。');
end
if nargin < 3 || isempty(pkt_select)
    pkt_select = [];
end
if nargin < 4 || isempty(session_id)
    session_id = 1;
end

defs = link_phy_defs();
sps = 4;

txfilter = comm.RaisedCosineTransmitFilter( ...
    'OutputSamplesPerSymbol', sps, ...
    'RolloffFactor', 0.25);

pcmatrix = ldpcQuasiCyclicMatrix(defs.blockSize, defs.P);
cfgLDPCEnc = ldpcEncoderConfig(pcmatrix);
crcgenerator = comm.CRCGenerator(defs.poly);

if Anti_Jamming_Mode_select_rec == 1
    M = 2;
    sf = 15;
    modulator = comm.PSKModulator(M, 'BitInput', true);
    modulator.PhaseOffset = pi;
else
    M = 4;
    sf = 1;
    modulator = comm.PSKModulator(M, 'BitInput', true);
    modulator.PhaseOffset = pi/4;
end

payload_bytes = uint8(payload_bytes(:));
payload_bytes_per_pkt = 44;
total_pkt_num = max(1, ceil(length(payload_bytes) / payload_bytes_per_pkt));
zero_padding_bytes = total_pkt_num * payload_bytes_per_pkt - length(payload_bytes);
zero_padding_bits = zero_padding_bytes * 8;

waveforms = cell(1, total_pkt_num);
wave_lens = zeros(1, total_pkt_num);
valid_bits_each = zeros(1, total_pkt_num);

for pkt_id = 1:total_pkt_num
    byte_st = (pkt_id - 1) * payload_bytes_per_pkt + 1;
    byte_ed = min(pkt_id * payload_bytes_per_pkt, length(payload_bytes));
    valid_bytes = max(0, byte_ed - byte_st + 1);

    payload_this = zeros(payload_bytes_per_pkt, 1, 'uint8');
    if valid_bytes > 0
        payload_this(1:valid_bytes) = payload_bytes(byte_st:byte_ed);
    end
    valid_bits_each(pkt_id) = valid_bytes * 8;

    payload_bits = bytes_to_bits(payload_this);

    frame_bits = [ ...
        defs.frame_head; ...
        defs.user_id; ...
        defs.data_frame_type; ...
        bits_from_int(session_id, 16); ...
        bits_from_int(total_pkt_num, 16); ...
        bits_from_int(pkt_id, 16); ...
        bits_from_int(valid_bytes * 8, 16); ...
        bits_from_int(zero_padding_bits, 9); ...
        payload_bits];

    % 449 bit + CRC32 = 481 bit，再补 5bit 变成 486 bit
    coded_in = [crcgenerator(frame_bits); defs.data_frame_end];

    scr_bits = scramble_bits(coded_in, defs.scr_seq);

    % 关键修正：这里也必须传列向量，不能转置
    enc_bits = ldpcEncode(scr_bits, cfgLDPCEnc);

    inter_matrix = reshape(enc_bits, 36, 18).';
    inter_bits = inter_matrix(:);

    if Anti_Jamming_Mode_select_rec == 1
        inter_polar = 2 * inter_bits - 1;
        spread_seq = zeros(length(inter_polar) * sf, 1);
        for ii = 1:length(inter_polar)
            spread_seq((ii-1)*sf+1 : ii*sf) = inter_polar(ii) * defs.pn_data;
        end
        mod_sig = modulator(0.5 * (spread_seq + 1));
    else
        mod_sig = modulator(inter_bits);
    end

    tx_in = [defs.head_data; mod_sig; zeros(sps * 10, 1)];
    one_wave = txfilter(tx_in);

    waveforms{pkt_id} = one_wave;
    wave_lens(pkt_id) = length(one_wave);
end

tx_cache = struct();
tx_cache.session_id = session_id;
tx_cache.total_pkt_num = total_pkt_num;
tx_cache.payload_bytes_per_pkt = payload_bytes_per_pkt;
tx_cache.zero_padding_bits = zero_padding_bits;
tx_cache.mode = Anti_Jamming_Mode_select_rec;
tx_cache.waveforms = waveforms;
tx_cache.wave_lens = wave_lens;
tx_cache.valid_bits_each = valid_bits_each;
tx_cache.payload_bytes = payload_bytes;

if isempty(pkt_select)
    pkt_select = 1:total_pkt_num;
end
pkt_select = unique(pkt_select(:).', 'stable');
pkt_select = pkt_select(pkt_select >= 1 & pkt_select <= total_pkt_num);

Trans_sig_data = [];
for kk = 1:length(pkt_select)
    Trans_sig_data = [Trans_sig_data; waveforms{pkt_select(kk)}];
end

end

function bits = bytes_to_bits(u8)
if isempty(u8)
    bits = zeros(0,1);
    return;
end
bin_chars = dec2bin(uint8(u8), 8);
bits = double(reshape(bin_chars.', [], 1) == '1');
end

function bits = bits_from_int(v, width)
bits = double(dec2bin(max(0, v), width) == '1').';
end

function out = scramble_bits(in, scr_seq)
out = zeros(size(in));
grp = length(scr_seq);
for ii = 1:length(in)/grp
    st = (ii-1)*grp + 1;
    ed = ii*grp;
    out(st:ed) = xor(in(st:ed), scr_seq);
end
end