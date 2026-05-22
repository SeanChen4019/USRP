function [frame_data, frame_crc] = preprocess_video(video_path, frame_count)
% 从视频中顺序读取并均匀抽取 frame_count 帧，缩略图压缩为JPEG并计算CRC32
v = VideoReader(video_path);
total_frames = v.NumFrames;
if isinf(total_frames) || total_frames < 1
    total_frames = v.Duration * v.FrameRate;
end
total_frames = max(1, floor(total_frames));

% 均匀间隔的帧索引
frame_indices = round(linspace(1, total_frames, frame_count));

frame_data = cell(frame_count, 1);
frame_crc = zeros(frame_count, 1, 'uint32');

idx = 1;
frame_read = 0;
while hasFrame(v) && idx <= frame_count
    f = readFrame(v);
    frame_read = frame_read + 1;

    if frame_read == frame_indices(idx)
        f = imresize(f, [120, 160]);

        tmp_name = [tempname, '.jpg'];
        imwrite(f, tmp_name, 'JPEG');
        fid = fopen(tmp_name, 'rb');
        frame_jpeg = fread(fid, inf, 'uint8=>uint8');
        fclose(fid);
        delete(tmp_name);

        frame_data{idx} = frame_jpeg;
        frame_crc(idx) = compute_crc32(frame_jpeg);
        idx = idx + 1;
    end
end

% 如果到视频末尾还没取够帧，用黑帧填充
while idx <= frame_count
    f = zeros(120, 160, 3, 'uint8');
    tmp_name = [tempname, '.jpg'];
    imwrite(f, tmp_name, 'JPEG');
    fid = fopen(tmp_name, 'rb');
    frame_jpeg = fread(fid, inf, 'uint8=>uint8');
    fclose(fid);
    delete(tmp_name);

    frame_data{idx} = frame_jpeg;
    frame_crc(idx) = compute_crc32(frame_jpeg);
    idx = idx + 1;
end
end

function crc_val = compute_crc32(data_bytes)
poly = uint32(hex2dec('EDB88320'));
crc = uint32(hex2dec('FFFFFFFF'));
for i = 1:length(data_bytes)
    crc = bitxor(crc, uint32(data_bytes(i)));
    for j = 1:8
        if bitand(crc, 1)
            crc = bitxor(bitshift(crc, -1), poly);
        else
            crc = bitshift(crc, -1);
        end
    end
end
crc_val = bitxor(crc, uint32(hex2dec('FFFFFFFF')));
end
