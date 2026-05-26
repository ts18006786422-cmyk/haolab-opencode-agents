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

%% ================== NIRS_SPM数据格式转换工具 ==================
%% --------------- 用户可配置参数 ---------------
clc, clear

% 文件命名参数
prefix      = 'G';              % 文件名前缀
suffix      = '.csv';           % 输入数据文件后缀
digits      = 2;                % 序号位数 (2表示01,02,...)   @不需改
startIndex  = 1;                % 起始编号                    @不需改
endIndex    = 4;                % 结束编号    

% 数据处理参数
fs          = 10;               % 采样频率 (Hz, Hitachi7100为10Hz)

%% --------------- 主处理流程 (无需修改) ---------------
for isub = startIndex:endIndex
    %% a. 构建文件名并加载数据
    sub_str = num2str(isub, ['%0' num2str(digits) 'd']);
    input_file = [prefix sub_str suffix];
    
    if ~exist(input_file, 'file')
        warning('文件 %s 不存在，跳过', input_file);
        continue;
    end
    
    % 读取数据 (确保readHitachData函数在路径中)
    [hbo, hbr, mark] = readHitachData({input_file});
    
    %% b. 构建事件标记向量
    vector_onset = zeros(length(hbo), 1);
    for vector = 1:size(mark, 1)
        vector_onset(mark(vector, 2)) = mark(vector, 1);
    end
    
    %% c. 设置通道数和采样率
    num_ch = size(hbo, 2);  
    
    %% d. 构建NIRS_SPM数据结构
    nirs_data = struct(...
        'oxyData', hbo, ...
        'dxyData', hbr, ...
        'vector_onset', vector_onset, ...
        'fs', fs, ...
        'nch', num_ch);
    
    %% e. 保存结果
    output_file = [prefix sub_str '.mat'];
    save(output_file, 'nirs_data');
    
    fprintf('已完成 %s → %s 的转换\n', input_file, output_file);
end
disp('==== 所有数据转换完成 ====');


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
start_sub = 1;                  % 起始被试编号
end_sub = 8;                  % 结束被试编号                                                          @@修改 

% 文件参数
input_prefix = 'wtccbsi_';      % 输入文件前缀
output_prefix = '';             % 输出SPM文件前缀（若需要）
base_prefix = 'G';                % 文件名基础前缀
dir_save = 'D:\Research data\Study_AI_hyperscanning\Raw data\NIRS_SPARK\New Folder\'; % 保存路径         @@修改 

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


%% ================== 2. NIRS模型估计流程 ==================
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





%% ================== 第六步 提取第五步计算出来的fc（脑内）或wtc值（脑间同步），用于统计检验  ==================
%% 参数设置部分
clear; close all; clc;

% 1. 设置文件路径和编号范围
filePath = 'D:\Research data\Study_AI_hyperscanning\Raw data\';
filePrefix = 'WTC_wtccbsi_G';  % 文件名前缀
startIndex = 1;                 % 起始编号
endIndex = 120;                  % 结束编号
numSubjects = endIndex - startIndex + 1;

% 2. 设置要提取的变量和事件
variablesToExtract = {'Sub1_Rsq_matrix', 'Sub2_Rsq_matrix', 'Inter_Rsq_matrix'};
numEvents = 9;                  % event1到event9
numChannels = 35;               % 35个通道
numFrequencies = 109;           % 109个频率点

% 3. 输出文件设置
outputFolder = 'D:\Research data\Study_AI_hyperscanning\Processed data\';
if ~exist(outputFolder, 'dir')
    mkdir(outputFolder);
end

%% 主处理部分
% 创建通道组合索引映射表
channelPairs = cell(numChannels * numChannels, 2);
for row = 1:numChannels
    for col = 1:numChannels
        index = (row-1)*numChannels + col;
        channelPairs{index, 1} = row;
        channelPairs{index, 2} = col;
    end
end
save(fullfile(outputFolder, 'ChannelPairsMapping.mat'), 'channelPairs');

% 为每个变量和事件预先分配存储空间
for v = 1:length(variablesToExtract)
    varName = variablesToExtract{v};
    for e = 1:numEvents
        eval([varName '_event' num2str(e) ' = zeros(numSubjects, numChannels*numChannels, numFrequencies);']);
    end
end

%% 处理每个文件
validSubjects = 0;  % 记录实际有效文件数
for fileNum = startIndex:endIndex
    % 构造文件名（假设文件名格式为WTC_wtccbsi_G1.mat到WTC_wtccbsi_G120.mat）
    currentFile = fullfile(filePath, [filePrefix num2str(fileNum, '%02d') '.mat']);
    
    fprintf('正在处理文件 %d/%d: %s\n', fileNum, endIndex, [filePrefix num2str(fileNum, '%02d') '.mat']);
    
    % 检查文件是否存在
    if ~exist(currentFile, 'file')
        fprintf('文件 %s 不存在，跳过\n', currentFile);
        continue;
    end
    
    try
        % 加载文件
        loadedData = load(currentFile);
        
        % 检查results结构体是否存在
        if ~isfield(loadedData, 'results')
            error('文件 %s 中缺少 results 结构体', [filePrefix num2str(fileNum) '.mat']);
        end
        
        % 处理每个事件
        for e = 1:numEvents
            eventName = ['event' num2str(e)];
            
            % 检查事件是否存在
            if ~isfield(loadedData.results, eventName)
                error('文件 %s 中缺少 %s 结构体', [filePrefix num2str(fileNum) '.mat'], eventName);
            end
            
            % 提取每个变量的数据
            for v = 1:length(variablesToExtract)
                varName = variablesToExtract{v};
                
                % 检查变量是否存在
                if ~isfield(loadedData.results.(eventName), varName)
                    error('文件 %s 的 %s 中缺少 %s 变量', [filePrefix num2str(fileNum) '.mat'], eventName, varName);
                end
                
                % 获取当前数据矩阵
                currentMatrix = loadedData.results.(eventName).(varName);
                
                % 验证矩阵尺寸
                if ~isequal(size(currentMatrix), [numChannels, numChannels, numFrequencies])
                    error('文件 %s 的 %s 中 %s 矩阵尺寸不正确', [filePrefix num2str(fileNum) '.mat'], eventName, varName);
                end
                
                % 将35x35x109矩阵重塑为1225x109矩阵(1225=35*35)
                reshapedMatrix = reshape(currentMatrix, numChannels*numChannels, numFrequencies);
                
                % 存储到预分配的变量中（使用validSubjects+1作为索引）
                eval([varName '_event' num2str(e) '(validSubjects + 1, :, :) = reshapedMatrix;']);
            end
        end
        
        validSubjects = validSubjects + 1;  % 成功处理一个文件
        
    catch ME
        fprintf('处理文件 %s 时出错: %s\n', [filePrefix num2str(fileNum) '.mat'], ME.message);
        continue;  % 跳过出错的文件，继续处理下一个
    end
end

%% 保存处理后的数据
% 为每个变量和事件保存单独的文件
for v = 1:length(variablesToExtract)
    varName = variablesToExtract{v};
    
    for e = 1:numEvents
        % 获取当前数据（只保留有效数据部分）
        currentData = eval([varName '_event' num2str(e) '(1:validSubjects, :, :)']);
        
        % 创建变量名
        dataVarName = [varName '_event' num2str(e)];
        
        % 保存到文件
        outputFileName = fullfile(outputFolder, ['WtcforStatistics_' dataVarName '.mat']);
        save(outputFileName, dataVarName, '-v7.3');  % 使用v7.3格式保存大文件
        
        fprintf('已保存: %s\n', outputFileName);
    end
end

fprintf('处理完成! 共处理了%d个有效文件（从%d到%d）\n', validSubjects, startIndex, endIndex);



%% ================== 第七步 按需求对第六步提取的wtc值进行统计检验 ==================






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