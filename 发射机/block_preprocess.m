function [block_data, block_crc] = preprocess_image(img_path, grid_rows, grid_cols)
% 将图片切分为 grid_rows×grid_cols 块，每块独立压缩为JPEG并计算CRC32
img = imread(img_path);
[img_h, img_w, ~] = size(img);

block_h = floor(img_h / grid_rows);
block_w = floor(img_w / grid_cols);

block_data = cell(grid_rows, grid_cols);
block_crc = zeros(grid_rows, grid_cols, 'uint32');

for r = 1:grid_rows
    for c = 1:grid_cols
        y1 = (r-1)*block_h + 1;
        y2 = r*block_h;
        x1 = (c-1)*block_w + 1;
        x2 = c*block_w;
        block_img = img(y1:y2, x1:x2, :);

        tmp_name = [tempname, '.jpg'];
        imwrite(block_img, tmp_name, 'JPEG');
        fid = fopen(tmp_name, 'rb');
        block_jpeg = fread(fid, inf, 'uint8=>uint8');
        fclose(fid);
        delete(tmp_name);

        block_data{r, c} = block_jpeg;
        block_crc(r, c) = compute_crc32(block_jpeg);
    end
end
end

function [frame_data, frame_crc] = preprocess_video(video_path, frame_count)
% 从视频中提取 frame_count 个均匀间隔的帧，缩略图压缩为JPEG并计算CRC32
v = VideoReader(video_path);
total_frames = v.NumFrames;
if isinf(total_frames) || total_frames < 1
    total_frames = v.Duration * v.FrameRate;
end
total_frames = max(1, floor(total_frames));

frame_indices = round(linspace(1, total_frames, frame_count));

frame_data = cell(frame_count, 1);
frame_crc = zeros(frame_count, 1, 'uint32');

for i = 1:frame_count
    try
        v.CurrentTime = (frame_indices(i) - 1) / v.FrameRate;
        f = readFrame(v);
    catch
        f = zeros(120, 160, 3, 'uint8');
    end

    % 缩略图缩放到 160x120
    f = imresize(f, [120, 160]);

    tmp_name = [tempname, '.jpg'];
    imwrite(f, tmp_name, 'JPEG');
    fid = fopen(tmp_name, 'rb');
    frame_jpeg = fread(fid, inf, 'uint8=>uint8');
    fclose(fid);
    delete(tmp_name);

    frame_data{i} = frame_jpeg;
    frame_crc(i) = compute_crc32(frame_jpeg);
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

function [img_h, img_w] = get_image_dims(img_path)
info = imfinfo(img_path);
img_h = info.Height;
img_w = info.Width;
end
