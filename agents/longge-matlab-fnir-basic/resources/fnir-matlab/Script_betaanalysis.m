%% Kelong Lu Wenzhou Medical University & ChatGPT & DeepSeek
%% 2025/04/28


%% ==================第一步 数据文件批量命名 ==================（需注意备份原文件，否则会覆盖）
%% --------------- 参数设置 ---------------
folderPath = 'C:\Users\lkl\Desktop\Folder\New Folder';  % 原始文件路径
filePattern = '*-mark.mat';     % 原始文件通配符
prefix      = 'G';              % 新文件名前缀
suffix      = '_mark.mat';      % 新文件名后缀
digits      = 2;                % 序号占位位数，比如 2 则 1→01，3→03
startIndex  = 1;                % 起始编号

%% --------------- 主处理流程  (无需修改) ---------------
% 读取目标文件夹下所有匹配的文件
files = dir(fullfile(folderPath, filePattern));
n     = numel(files);
if n == 0
    fprintf('目录 [%s] 中未找到匹配 "%s" 的文件。\n', folderPath, filePattern);
else
    for k = 1:n
        oldName = fullfile(folderPath, files(k).name);
        idx     = k + startIndex - 1;
        newFile = sprintf('%s%0*d%s', prefix, digits, idx, suffix);
        newName = fullfile(folderPath, newFile);
        movefile(oldName, newName);
        fprintf('重命名: %s → %s\n', files(k).name, newFile);
    end
    fprintf('批量重命名完成，共 %d 个文件。\n', n);
end


%% ==================第二步 NIRS_SPM数据格式构建工具 ==================
%% --------------- 参数设置 ---------------
clc, clear
% 文件命名参数
prefix      = 'G';               % 文件名前缀
suffix1      = '_data.mat';      % 标记文件后缀1 data
suffix2      = '_mark.mat';      % 标记文件后缀2 mark
digits      = 2;                % 序号位数 (2表示01,02,...) @不用改
startIndex  = 1;                % 起始编号                  @不用改
endIndex    = 3;                % 结束编号 → 样本数量（如果是多人组，则为组数）

% 数据处理参数
fs          = 11;               % NIRS采样频率 (Hz)
tolerance   = 0.08;             % 事件标记时间容差 (秒)。慧创机子的两个数据点之间的间隔为0.0909，取一个小于间隔值的数。
%由于浮点数的精度问题，直接比较两个浮点数可能不总是返回预期的结果。
%如果数据包含浮点数，并且想找到一个接近但由于计算精度不完全相等的值，你应该使用一个小的公差来进行比较。
%所以不用 == 功能，而用 <
sclConc     = 1e6;              % 浓度数据缩放因子 慧创的数据要改变浓度单位 （一般来说，如果发现机子的血氧数据很小，那一般是没有转换单位）

% 通道配置参数
total_channels  = 105;          % 设备总通道数
active_ranges   = {[1:35], [71:105]}; % 工作通道范围(单元格数组) ！！！因为：通道36:70处于待机状态！！！有个帽子没有用到。需要视实验情况而定。
channel_map_file = 'raw_NumofCh.mat'; % 通道映射文件

%% --------------- 主处理流程 (无需修改) ---------------
% 准备通道选择索引
channel_idx = [active_ranges{:}]; % 合并所有有效通道范围
num_ch = length(channel_idx);    % 计算实际工作通道数

for isub = startIndex:endIndex
    %% a. 构建文件名并加载数据
    sub_str = num2str(isub, ['%0' num2str(digits) 'd']);
    data_file = [prefix sub_str suffix1];
    mark_file = [prefix sub_str suffix2];
    
    if ~exist(data_file, 'file') || ~exist(mark_file, 'file')
        warning('文件 %s 或 %s 不存在，跳过', data_file, mark_file);
        continue;
    end
    
    load(data_file);
    load(mark_file);
    
    %% b. 构建事件标记向量
    vector_onset = zeros(length(dataSave.HbO), 1);
    time_mark = cell2mat(onsets);
    
    Loc_mark = zeros(length(time_mark), 1);
    for num_mark = 1:length(time_mark)
        Loc_mark(num_mark) = find(abs(dataSave.tHRF - time_mark(num_mark)) < tolerance, 1);
    end
    vector_onset(sort(Loc_mark)) = 1;
    
    %% c. 通道处理
    % 加载通道映射
    load(channel_map_file);
    
    % 初始化并重新排序通道数据
    n_hbo = zeros(size(dataSave.HbO, 1), total_channels);
    n_hb  = zeros(size(dataSave.HbR, 1), total_channels);
    
    for nch = 1:total_channels
        n_hbo(:, nch) = dataSave.HbO(:, ch(nch, 1));
        n_hb(:, nch)  = dataSave.HbR(:, ch(nch, 1));
    end
    
    % 选择工作通道
    fin_hbo = n_hbo(:, channel_idx);
    fin_hb  = n_hb(:, channel_idx);
    
    %% d. 构建NIRS_SPM数据结构
    nirs_data = struct(...
        'oxyData', fin_hbo * sclConc, ...
        'dxyData', fin_hb * sclConc, ...
        'vector_onset', vector_onset, ...
        'fs', fs, ...
        'nch', num_ch);
    
    %% e. 保存结果
    output_file = [prefix sub_str '.mat'];
    save(output_file, 'nirs_data');
    fprintf('已完成 %s 的数据处理\n', output_file);
end
disp('==== 所有数据处理完成 ====');


%% ==================第三步 CBSI预处理 修正运动伪迹 ==================
%1）抑制生理噪声
%fNIRS信号常受心跳（~1 Hz）、呼吸（~0.3 Hz）等生理活动干扰，这些噪声与神经活动无关但幅度较大。
%2）修正运动伪迹
% 头部运动会导致信号骤变（如尖峰或基线漂移）。
%3）增强神经激活信号的特异性
%通过抑制非神经相关的全局性信号波动，提高检测大脑激活区域的灵敏度。
% Citation: Cui, X., Bray, S., & Reiss, A. L. (2010). Functional near-infrared spectroscopy (NIRS) signal improvement based on negative correlation between oxygenated and deoxygenated hemoglobin dynamics. NeuroImage, 49(4), 3039-3046.
%% --------------- 用户可配置参数 ---------------
clc, clear

% 文件命名参数
prefix      = 'G';              % 输入文件前缀（转录处理后的文件）
suffix      = '.mat';           % 输入文件后缀
digits      = 2;                % 序号位数
startIndex  = 1;                % 起始编号
endIndex    = 95;               % 结束编号

% CBSI参数
output_prefix = 'cbsi_';        % 输出文件前缀（自动添加）                         @ 不改
alpha_mode  = 'channel-wise';   % 'global'使用全局alpha，'channel-wise'按通道计算  @ 不改

%% --------------- 主处理流程 ---------------
for isub = startIndex:endIndex
    %% a. 构建文件名并加载数据
    sub_str = num2str(isub, ['%0' num2str(digits) 'd']);
    input_file = [prefix sub_str suffix];
    
    if ~exist(input_file, 'file')
        warning('文件 %s 不存在，跳过', input_file);
        continue;
    end
    
    load(input_file);
    oxy = nirs_data.oxyData;
    deoxy = nirs_data.dxyData;
    
    %% b. CBSI处理
    oxy_processed = zeros(size(oxy));
    num_ch = nirs_data.nch;
    
    switch alpha_mode
        case 'global'
            % 全局alpha（所有通道共用）
            alpha = std(oxy(:)) / std(deoxy(:));
            oxy_processed = (oxy - alpha * deoxy) / 2;
            
        case 'channel-wise'
            % 通道独立alpha（默认方式）
            for ch = 1:num_ch
                alpha = std(oxy(:, ch)) / std(deoxy(:, ch));
                oxy_processed(:, ch) = (oxy(:, ch) - alpha * deoxy(:, ch)) / 2;
            end
    end
    
    %% c. 更新数据结构
    nirs_data = struct(...
        'oxyData', oxy_processed, ...  % 仅更新处理后的oxyData
        'dxyData', deoxy, ...          % 保持原始dxyData
        'vector_onset', nirs_data.vector_onset, ...
        'fs', nirs_data.fs, ...
        'nch', num_ch);
    
    %% d. 保存结果
    output_file = [output_prefix prefix sub_str suffix];
    save(output_file, 'nirs_data');
    
    fprintf('已完成 %s 的CBSI处理 → %s\n', input_file, output_file);
end

disp('==== CBSI预处理完成 ====');




%% ================== 第四步 小波去噪预处理流程  wavelet-based_denoise 去除global noise 如 心跳、呼吸、血管活动、梅耶波（~0.1Hz）等==================
% Script of the Wavelet-based method for removing fNIRS global physiological noise
% Please cite the paper: Duan et al., BOE, 2018, Wavelet-based method for removing global physiological noise in functional near-infrared spectroscopy 
% Input: data
% Output: denoised_data
%% --------------- 用户可配置参数 ---------------
clc, clear
% 文件命名参数
input_prefix = 'cbsi_';         % 输入文件前缀（CBSI处理后的文件）
output_prefix = 'wtccbsi_';     % 输出文件前缀
base_prefix = 'G';              % 文件名基础前缀
digits = 2;                     % 序号位数
startIndex = 1;                 % 起始编号
endIndex = 95;                  % 结束编号
%% --------------- 主处理流程 ---------------
for isub = startIndex:endIndex
    %% a. 构建文件名并加载数据
    sub_str = num2str(isub, ['%0' num2str(digits) 'd']);
    input_file = [input_prefix base_prefix sub_str '.mat'];
    
    if ~exist(input_file, 'file')
        warning('文件 %s 不存在，跳过', input_file);
        continue;
    end
    load(input_file);
    
    %% b. 执行小波去噪（使用默认参数）
    try
        denoised_data = par_wtc_denoise(nirs_data.oxyData); % 不修改函数默认参数
    catch ME
        warning('被试 %s 小波去噪失败: %s', sub_str, ME.message);
        continue;
    end
    
    %% c. 更新并保存数据
    nirs_data.oxyData = denoised_data;
    output_file = [output_prefix base_prefix sub_str '.mat'];
    save(output_file, 'nirs_data');
    
    fprintf('已完成 %s → %s\n', input_file, output_file);
end
disp('==== 小波去噪完成 ====');



%% ================== 第五步 基于GLM计算脑激活beta值 ==================
%% ================== 1. NIRS模型指定流程 ==================
%% --------------- 用户可配置参数 ---------------
clc; clear;

% 运行范围
start_sub = 119;                  % 起始被试编号
end_sub = 119;                  % 结束被试编号                                                          @@修改 

% 文件参数
input_prefix = 'wtccbsi_';      % 输入文件前缀
output_prefix = '';             % 输出SPM文件前缀（若需要）
base_prefix = 'G';                % 文件名基础前缀
dir_save = 'D:\Research data\Study_AI_hyperscanning\Raw data\'; % 保存路径         @@修改 

% 实验设计参数
sampling_rate = 11;             % 采样率 (Hz)
num_expected_onsets = 9;        % 预期每个文件的事件标记数                                              @@修改  几个mark 
trial_names = {'Rest1','Crea1','Dis1','Rest2','Creat2','Dis2','Rest3','Creat3','Dis3'}; % 条件名称     @@修改 
trial_durations = [120, 300, 120, 120, 300, 120, 120, 300, 120]; % 各条件持续时间(s)                   @@修改 

% 模型参数
hb_type = 'hbo';                % 血红蛋白类型 ('hbo'/'hbr')        
HPF = 'wavelet';                % 高通滤波类型
LPF = 'hrf';                    % 低通滤波类型
method_cor = 0;                 % 相关性处理方法
flag_window = 0;                % 时间窗标记
hrf_type = 0;                   % HRF函数类型
units = 0;                      % 时间单位

%% --------------- 初始化日志系统 ---------------
error_log = {};
warning_log = {};
mkdir(dir_save); % 确保保存目录存在

%% --------------- 主处理流程 ---------------
for isub = start_sub:end_sub
        %% a. 文件加载与检查
        try
            fname = sprintf('%s%s%02d.mat', input_prefix, base_prefix, isub);
            
            if ~isfile(fname)
                msg = sprintf('文件 %s 不存在', fname);
                warning_log{end+1} = msg;
                continue;
            end
            
            load(fname); % 加载nirs_data
            
            %% b. 事件标记验证
            mark = find(nirs_data.vector_onset > 0);
            if numel(mark) < num_expected_onsets
                msg = sprintf('被试 %02d 标记不足 (需%d个，实%d个)', ...
                             isub, num_expected_onsets, numel(mark));
                error_log{end+1} = msg;
                continue;
            end
            
            %% c. 实验设计配置
            % 转换为采样点单位
            durations_samples = num2cell(trial_durations * sampling_rate);
            onsets_samples = num2cell(mark(1:num_expected_onsets));
            
            %% d. 模型指定

            SPM_nirs = specification_batch(fname, hb_type, HPF, LPF, ...
                                         method_cor, dir_save, flag_window, ...
                                         hrf_type, units, trial_names,onsets_samples, durations_samples);
            
            
            %% e. 输出文件管理
            old_file = 'SPM_indiv_HbO.mat';
            new_file = sprintf('%s%02d_SPM_indiv_HbO.mat', base_prefix, isub);
            
            if isfile(old_file)
                movefile(old_file, fullfile(dir_save, new_file));
            else
                warning_log{end+1} = sprintf('被试 %02d 未生成SPM文件', isub);
            end
            
        catch ME
            error_log{end+1} = sprintf('被试 %02d 错误: %s (行%d)', ...
                                      isub, ME.message, ME.stack(1).line);
        end
end

%% --------------- 输出日志报告 ---------------
fprintf('\n==== 处理完成 ====\n');
fprintf('成功处理: %d/%d\n', end_sub - length(error_log), end_sub);

if ~isempty(warning_log)
    fprintf('\n==== 警告记录 ====\n');
    disp(unique(warning_log));
end

if ~isempty(error_log)
    fprintf('\n==== 错误记录 ====\n');
    disp(unique(error_log));
end
save(fullfile(dir_save, 'processing_log.mat'), 'error_log', 'warning_log');


%% ================== 2. NIRS模型估计流程 计算beta值==================
%% --------------- 用户可配置参数 ---------------
clc; clear;

% 文件路径参数
data_dir = 'D:\Research data\Study_AI_hyperscanning\Raw data\NIRS_SPARK\New Folder\'; % 数据目录 Specify导出的数据和Wavelet denoise预处理的数据要放在同一个文件夹，
                                                                                      %因为需要同时处理这两个文件      @@修改 
spm_prefix = 'G';                % SPM文件前缀
input_prefix = 'wtccbsi_G';      % 输入数据文件前缀
output_prefix = 'G';             % 输出beta文件前缀     

% 运行范围
start_sub = 1;                   % 起始被试编号
end_sub = 2;                   % 结束被试编号        @@修改             

%% --------------- 初始化日志系统 ---------------
error_log = {};
warning_log = {};

%% --------------- 主处理流程 ---------------
for isub = start_sub:end_sub
    try
        %% a. 文件检查
        sub_str = num2str(isub, '%02d');
        
        % 构建SPM和输入数据文件名
        fname_SPM = fullfile(data_dir, [spm_prefix sub_str '_SPM_indiv_HbO.mat']);
        fname_nirs = fullfile(data_dir, [input_prefix sub_str '.mat']);
        
        if ~isfile(fname_SPM)
            msg = sprintf('SPM文件不存在: %s', fname_SPM);
            warning_log{end+1} = msg;
            continue;
        end
        
        if ~isfile(fname_nirs)
            msg = sprintf('输入数据文件不存在: %s', fname_nirs);
            warning_log{end+1} = msg;
            continue;
        end
        
        %% b. 模型估计
        SPM_nirs = estimation_batch(fname_SPM, fname_nirs);
        
        %% c. 输出文件处理
        old_file = 'SPM_indiv_HbO.mat';
        new_file = fullfile(data_dir, [output_prefix sub_str '_beta.mat']);
        
        if isfile(old_file)
            movefile(old_file, new_file);
            fprintf('被试 %02d 完成 → %s\n', isub, new_file);
        else
            msg = sprintf('被试 %02d 未生成估计结果', isub);
            warning_log{end+1} = msg;
        end
        
    catch ME
        error_log{end+1} = sprintf('被试 %02d 错误: %s (行%d)', ...
                                  isub, ME.message, ME.stack(1).line);
    end
end

%% --------------- 日志报告 ---------------
fprintf('\n==== 处理完成 ====\n');
fprintf('成功处理: %d/%d\n', end_sub - length(error_log), end_sub);

% 保存警告日志
if ~isempty(warning_log)
    fprintf('\n==== 警告记录 (%d条) ====\n', length(unique(warning_log)));
    disp(unique(warning_log));
end

% 保存错误日志
if ~isempty(error_log)
    log_file = fullfile(data_dir, 'estimation_error_log.txt');
    fid = fopen(log_file, 'w');
    fprintf(fid, '=== 模型估计错误日志 ===\n');
    fprintf(fid, '%s\n', unique(error_log));
    fclose(fid);
    fprintf('\n错误日志已保存至: %s\n', log_file);
else
    fprintf('\n所有被试处理成功，未发生错误\n');
end






%% ================== 第六步 提取第五步计算出来的beta值，用于统计检验 ==================
%% --------------- 用户可配置参数 ---------------
clc; clear;
%% 参数设置部分 - 请根据实际情况修改这些参数
clear, clc;
% 1. 文件路径和模式设置
filePath = 'D:\Research data\Study_AI_hyperscanning\Raw data\';       % @改beta文件所在路径：
filePattern = 'G*_beta.mat';  % 匹配所有以G开头、以_beta.mat结尾的文件  % 不用改，命名源于第五步的output：
% 2. 实验阶段设置
phaseNames = {'休息1', '任务1', '讨论1', '休息2', '任务2', '讨论2','休息3', '任务3', '讨论3'};  % @改： 根据实际情况修改阶段名称和数量
numPhases = length(phaseNames);  % 阶段数量

% 3. 输出文件名
outputFileName = 'BetaforStatistics.mat';    %保存出来的文件名

% 4. 被试编号范围设置
subjectRange = 1:120;  % 被试编号从01到120
expectedNumSubjects = length(subjectRange);

%% 主程序部分 - 一般不需要修改
% 初始化文件列表
fileList = struct('name', {}, 'folder', {});
validSubjects = [];

% 检查每个编号对应的文件是否存在
fprintf('正在检查文件...\n');
for subjNum = subjectRange
    % 生成带前导零的文件名格式 (G01_beta.mat 到 G120_beta.mat)
    formattedNum = sprintf('G%02d_beta.mat', subjNum);
    fullFileName = fullfile(filePath, formattedNum);
    
    if exist(fullFileName, 'file')
        fileList(end+1).name = formattedNum;
        fileList(end).folder = filePath;
        validSubjects(end+1) = subjNum;
    else
        warning('文件不存在: %s', fullFileName);
    end
end

numSubjects = length(fileList);
if numSubjects == 0
    error('没有找到匹配的文件，请检查路径和文件模式设置！');
else
    fprintf('找到%d/%d个匹配的文件\n', numSubjects, expectedNumSubjects);
    fprintf('缺失的文件编号: %s\n', num2str(setdiff(subjectRange, validSubjects)));
end

% 预分配三维矩阵
% 首先检查第一个有效文件以确定通道数量
firstValidFile = load(fullfile(filePath, fileList(1).name));
numChannels = size(firstValidFile.SPM_nirs.nirs.beta, 2);
betaMatrix = zeros(expectedNumSubjects, numChannels, numPhases); % 预分配完整大小
betaMatrix(:,:,:) = NaN; % 初始化为NaN，缺失文件将保持NaN

% 进度条设置
hWaitBar = waitbar(0, '正在处理文件...', 'Name', '数据处理进度');
cleanupObj = onCleanup(@() close(hWaitBar)); % 确保进度条关闭

% 逐个处理文件
for i = 1:numSubjects
    subjNum = validSubjects(i); % 获取实际被试编号
    currentFile = fullfile(filePath, fileList(i).name);
    
    % 更新进度条
    waitbar(i/numSubjects, hWaitBar, sprintf('正在处理文件 %02d/%02d: %s', ...
        subjNum, subjectRange(end), fileList(i).name));
    
    try
        % 加载文件
        fileData = load(currentFile);
        
        % 检查nirs结构体和beta字段是否存在
        if ~isfield(fileData.SPM_nirs, 'nirs') || ~isfield(fileData.SPM_nirs.nirs, 'beta')
            error('文件%s中缺少nirs结构体或beta字段', currentFile);
        end
        
        % 提取beta值
        currentBeta = fileData.SPM_nirs.nirs.beta;
        
        % 检查数据维度是否匹配
        if size(currentBeta, 1) < numPhases
            error('文件%s中的阶段数(%d)小于预期的阶段数(%d)', ...
                currentFile, size(currentBeta, 1), numPhases);
        end
        
        % 存储数据到三维矩阵(忽略最后一行常数项)
        betaMatrix(subjNum, :, :) = currentBeta(1:numPhases, :)';
        
    catch ME
        warning('处理文件%s时出错: %s', currentFile, ME.message);
        betaMatrix(subjNum, :, :) = NaN;  % 标记为NaN以便后续处理
    end
end

%% 保存结果
save(outputFileName, 'betaMatrix', 'phaseNames', 'subjectRange', 'validSubjects', 'numChannels', '-v7.3');

%% 显示汇总信息
fprintf('\n数据处理完成！\n');
fprintf('预期被试数量: %d\n', expectedNumSubjects);
fprintf('有效被试数量: %d\n', numSubjects);
fprintf('缺失被试编号: %s\n', num2str(setdiff(subjectRange, validSubjects)));
fprintf('通道数量: %d\n', numChannels);
fprintf('实验阶段: %s\n', strjoin(phaseNames, ', '));
fprintf('结果已保存到: %s\n', outputFileName);

% 显示数据预览
disp('三维矩阵预览(第一个有效被试的前5个通道在所有阶段的值):');
firstValidIdx = find(~all(isnan(betaMatrix(:,:,1)), 1)); % 找到第一个非全NaN的被试
if ~isempty(firstValidIdx)
    disp(squeeze(betaMatrix(firstValidIdx, 1:5, :)));
else
    disp('没有有效数据可供预览');
end

% 生成缺失文件报告
missingFiles = setdiff(subjectRange, validSubjects);
if ~isempty(missingFiles)
    fprintf('\n=== 缺失文件报告 ===\n');
    fprintf('总缺失文件数: %d\n', length(missingFiles));
    fprintf('缺失文件编号: %s\n', num2str(missingFiles));
    
    % 将缺失编号保存到文本文件
    missingFileReport = fullfile(filePath, 'missing_files_report.txt');
    fid = fopen(missingFileReport, 'w');
    fprintf(fid, '缺失文件报告 - 生成时间: %s\n', datestr(now));
    fprintf(fid, '总缺失文件数: %d\n', length(missingFiles));
    fprintf(fid, '缺失文件编号:\n');
    fprintf(fid, '%d ', missingFiles);
    fclose(fid);
    fprintf('缺失文件报告已保存到: %s\n', missingFileReport);
end
% 注意：
% 这一步也可以用于检验第五步中有多少组的数据没有成功执行specify和estimation，翻看命令行窗口可以确定具体是哪几个文件。
%一般来说，是因为mark出现问题，所以没有成功执行specify和estimation，此时，就需要人工去检查mark和根据前期记录附上对应mark





%% ================== 第七步 按需求对第六步提取的beta值进行统计检验 ==================






%% ================== 第八步 对统计检验所得结果的所有p值进行FDR矫正 ==================

[pthr,pcor,padj] = fdr(pvals);  % 脚本见fdr

%或复制以下代码，新建函数脚本，保存到matlab的目录下如toolbox2，并添加到子文件夹路径

function varargout = fdr(varargin)
% Computes the FDR-threshold for a vector of p-values.
%
% Usage:
% [pthr,pcor,padj] = fdr(pvals)
%                    fdr(pval,q)
%                    fdr(pval,q,cV)
%
% Inputs:
% pvals  = Vector of p-values.
% q      = Allowed proportion of false positives (q-value).
%          Default = 0.05.
% cV     = If 0, uses an harmonic sum for c(V). Otherwise uses c(V)=1.
%          Default = 1.
%
% Outputs:
% pthr   = FDR threshold.
% pcor   = FDR corrected p-values.
% padj   = FDR adjusted p-values.
%
% Note that the corrected and adjusted p-values do **not** depend
% on the supplied q-value, but they do depend on the choice of c(V).
%
% References:
% * Benjamini & Hochberg. Controlling the false discovery
%   rate: a practical and powerful approach to multiple testing.
%   J. R. Statist. Soc. B (1995) 57(1):289-300.
% * Yekutieli & Benjamini. Resampling-based false discovery rate
%   controlling multiple test procedures for multiple testing
%   procedures. J. Stat. Plan. Inf. (1999) 82:171-96.
%
% ________________________________
% Anderson M. Winkler
% Research Imaging Center/UTHSCSA
% Dec/2007 (first version)
% Nov/2012 (this version)
% http://brainder.org
 
% Accept arguments
switch nargin,
    case 0,
        error('Error: Not enough arguments.');
    case 1,
        pval = varargin{1};
        qval = 0.05;
        cV   = 1;
    case 2,
        pval = varargin{1};
        qval = varargin{2};
        cV   = 1;
    case 3,
        pval = varargin{1};
        qval = varargin{2};
        if varargin{3}, cV = 1;
        else cV = sum(1./(1:numel(pval))) ;
        end
    otherwise
        error('Error: Too many arguments.')
end
 
% Check if pval is a vector
if numel(pval) ~= length(pval),
    error('p-values should be a row or column vector, not an array.')
end
 
% Check if pvals are within the interval
if min(pval) < 0 || max(pval) > 1,
    error('Values out of range (0-1).')
end
 
% Check if qval is within the interval
if qval < 0 || qval > 1,
    error('q-value out of range (0-1).')
end
 
% ========[PART 1: FDR THRESHOLD]========================================
 
% Sort p-values
[pval,oidx] = sort(pval);
 
% Number of observations
V = numel(pval);
 
% Order (indices), in the same size as the pvalues
idx = reshape(1:V,size(pval));
 
% Line to be used as cutoff
thrline = idx*qval/(V*cV);
 
% Find the largest pval, still under the line
thr = max(pval(pval<=thrline));
 
% Deal with the case when all the points under the line
% are equal to zero, and other points are above the line
if thr == 0,
    thr = max(thrline(pval<=thrline));
end
 
% Case when it does not cross
if isempty(thr), thr = 0; end
 
% Returns the result
varargout{1} = thr;
 
% ========[PART 2: FDR CORRECTED]========================================
 
if nargout == 2 || nargout == 3,
    
    % p-corrected
    pcor = pval.*V.*cV./idx;
 
    % Sort back to the original order and output
    [~,oidxR] = sort(oidx);
    varargout{2} = pcor(oidxR);
end
 
% ========[PART 3: FDR ADJUSTED ]========================================
 
if nargout == 3,
 
    % Loop over each sorted original p-value
    padj = zeros(size(pval));
    prev = 1;
    for i = V:-1:1,
        % The p-adjusted for the current p-value is the smallest slope among
        % all the slopes of each of the p-values larger than the current one
        % Yekutieli & Benjamini (1999), equation #3.
        padj(i) = min(prev,pval(i)*V*cV/i);
        prev = padj(i);
    end
    varargout{3} = padj(oidxR);
end
% That's it!


%至此 beta值的统计检验告一段落。

