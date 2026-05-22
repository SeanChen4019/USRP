function [Carrier_select_desion,Anti_Jamming_Mode_desion,Power_gain_desion,Par_valid] = decision_making_AI(tcp_obj, Anti_Jamming_Mode, mod_selection, SNR, SNR_THR, SNR_valid, Carrier_select_cur, Power_gain_cur, Carrier_max_num, Power_gain_max_num, BER_test)

    % 默认兜底返回值（万一通信失败，保持现状）
    Carrier_select_desion = Carrier_select_cur;
    Power_gain_desion = Power_gain_cur;
    Anti_Jamming_Mode_desion = Anti_Jamming_Mode;
    Par_valid = 0;

    % 如果误码率测试开启，或 SNR 无效，或 TCP 没连上，则不决策
    if BER_test == 1 || SNR_valid == 0 || isempty(tcp_obj)
        return; 
    end

    % 1. 将当前状态打包为 MATLAB 结构体
    state_struct.SNR = SNR;
    state_struct.mod_selection = mod_selection;
    state_struct.Anti_Jamming_Mode = Anti_Jamming_Mode;
    state_struct.Carrier_select_cur = Carrier_select_cur;
    state_struct.Power_gain_cur = Power_gain_cur;
    
    % 2. 转为 JSON 字符串
    state_json = jsonencode(state_struct);
    
    try
        % 3. 发送给 Python
        write(tcp_obj, uint8(state_json));
        
        % 4. 接收 Python 的返回结果
        % 这里 read 会阻塞直到收到数据或超时（我们在上面设置了 1 秒超时）
        response_bytes = read(tcp_obj); 
        if ~isempty(response_bytes)
            response_json = char(response_bytes);
            action_struct = jsondecode(response_json);
            
            % 5. 解析 Python 发回的动作
            Carrier_select_desion = action_struct.Carrier_select_desion;
            Anti_Jamming_Mode_desion = action_struct.Anti_Jamming_Mode_desion;
            Power_gain_desion = action_struct.Power_gain_desion;
            Par_valid = action_struct.Par_valid;
        end
    catch ME
        warning('与 Python 通信出现异常: %s', ME.message);
    end
end