function Trans_sig = Par_trans_sig_Gen(Frame_type_temp, session_id_temp, ack_base_temp, ack_bitmap_temp, Anti_Jamming_Mode_select_temp)
% 高速可靠传输版反馈帧
% 反馈净载荷固定 96bit：
%   FrameHead(8) + UserID(8) + FrameType(8) + SessionID(16) + AckBase(16)
%   + AckBitmapHi(16) + AckBitmapLo(16) + Mode(8)

if nargin < 1, Frame_type_temp = 10; end
if nargin < 2, session_id_temp = 1; end
if nargin < 3, ack_base_temp = 1; end
if nargin < 4, ack_bitmap_temp = uint32(0); end
if nargin < 5, Anti_Jamming_Mode_select_temp = 0; end

defs = link_phy_defs();
sps = 4;

pcmatrix = ldpcQuasiCyclicMatrix(defs.blockSize, defs.P);
cfgLDPCEnc = ldpcEncoderConfig(pcmatrix);
crcgenerator = comm.CRCGenerator(defs.poly);

qpskmod = comm.PSKModulator(2, 'BitInput', true);
qpskmod.PhaseOffset = pi/4;

txfilter = comm.RaisedCosineTransmitFilter( ...
    'OutputSamplesPerSymbol', sps, ...
    'RolloffFactor', 0.25);

ack_bitmap_temp = uint32(ack_bitmap_temp);
bitmap_hi = bitand(bitshift(ack_bitmap_temp, -16), uint32(65535));
bitmap_lo = bitand(ack_bitmap_temp, uint32(65535));

payload_bits = [ ...
    defs.frame_head; ...
    defs.user_id; ...
    bits_from_int(Frame_type_temp, 8); ...
    bits_from_int(session_id_temp, 16); ...
    bits_from_int(ack_base_temp, 16); ...
    bits_from_int(double(bitmap_hi), 16); ...
    bits_from_int(double(bitmap_lo), 16); ...
    bits_from_int(Anti_Jamming_Mode_select_temp, 8)];

% 96bit + CRC32 = 128bit，再补 358bit 变成 486bit
coded_in = [crcgenerator(payload_bits); defs.fb_frame_end];

scr_bits = scramble_bits(coded_in, defs.scr_seq);

% 关键修正：这里必须直接传列向量，不能转置
enc_bits = ldpcEncode(scr_bits, cfgLDPCEnc);

inter_matrix = reshape(enc_bits, 36, 18).';
inter_bits = inter_matrix(:);

inter_polar = 2 * inter_bits - 1;
spread_seq = zeros(length(inter_polar) * 15, 1);
for ii = 1:length(inter_polar)
    spread_seq((ii-1)*15+1 : ii*15) = inter_polar(ii) * defs.pn_fb;
end

mod_signal = qpskmod(0.5 * (spread_seq + 1));
tx_in = [defs.head_fb; mod_signal; zeros(sps*10,1)];
Trans_sig = txfilter(tx_in);
Trans_sig = [zeros(2000,1); Trans_sig];

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