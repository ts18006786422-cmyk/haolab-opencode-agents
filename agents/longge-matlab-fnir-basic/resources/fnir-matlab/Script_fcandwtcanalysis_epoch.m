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



%% ================== 第五步 基于WTC小波相干分析计算脑内功能连接和脑间同步值  ==================
% --- 参数设置部分 ---
dataFolder = 'D:\Research data\Study_AI_hyperscanning\Raw data';
filePrefix = 'wtccbsi';
freqRange = 1:109;
sampling_rate = 11;
event_durations = [120, 150, 150, 120, 120, 150, 150, 120, 120, 150, 150, 120] * sampling_rate; % 用于需要计算任务前后期数据的情况
% event_durations = [120, 300, 120, 120, 300, 120, 120, 300, 120] * sampling_rate; % 用于不需要计算任务前后期数据的情况
num_channels = 35; %每个被试的通道数，如果有2个人，70个通道，那也是每人35，填35
outputFilePattern = 'WTC_%s.mat';

disp('参数设置完毕，请确保所有路径、范围和持续时间参数已根据数据修改。')

% --- 数据处理脚本 ---
filePattern = fullfile(dataFolder, [filePrefix '*.mat']);
dataFiles = dir(filePattern);
numFiles = length(dataFiles);

fisher_transform = @(x) 0.5 * log((1 + x) ./ (1 - x)); 

for i = 1:numFiles
    results = struct();
    dataPath = fullfile(dataFiles(i).folder, dataFiles(i).name);
    data = load(dataPath);
    
    if ~isfield(data, 'nirs_data') || ~isfield(data.nirs_data, 'oxyData') || ~isfield(data.nirs_data, 'vector_onset')
        warning('数据结构不匹配，跳过文件: %s', dataFiles(i).name);
        continue;
    end

    oxyData = data.nirs_data.oxyData;
    vector_onset = data.nirs_data.vector_onset;
    pre_mark = find(vector_onset > 0);
    
    %%  与非EPOCH脚本的区别在这（我们重复了三个任务的mark，以备建立三个任务的前期和后期两个阶段的mark点和时间序列)
    mark_t1 = 2;value_t1 = pre_mark(2)+ 150 * sampling_rate;  %任务1的中点mark 任务总共300s， 慧创机子时间分辨率为sampling_rate
    mark_t2 = 5;value_t2 = pre_mark(5)+ 150 * sampling_rate;  %任务2的中点mark
    mark_t3 = 8;value_t3 = pre_mark(8)+ 150 * sampling_rate;  %任务3的中点mark
    mark = [pre_mark(1:mark_t1);value_t1;pre_mark(mark_t1+1:mark_t2);value_t2;pre_mark(mark_t2+1:mark_t3);value_t3;pre_mark(mark_t3+1:end)];
    %%
    
    
    if length(mark) < length(event_durations)
        warning('事件标记不足，文件 %s 仅有 %d 个标记，无法匹配 %d 个事件持续时间', dataFiles(i).name, length(mark), length(event_durations));
        continue;
    end

    event_points = arrayfun(@(j) mark(j):min(mark(j) + event_durations(j) - 1, size(oxyData, 1)), 1:length(event_durations), 'UniformOutput', false);
    exceeding_events = find(cellfun(@(range) range(end) > size(oxyData, 1), event_points));
    if ~isempty(exceeding_events)
        warning('文件 %s 中事件范围超出数据长度，事件编号：%s', dataFiles(i).name, mat2str(exceeding_events));
    end

    if size(oxyData, 2) < num_channels * 2
        warning('通道数不足，跳过文件: %s', dataFiles(i).name);
        continue;
    end

    channels_1 = oxyData(:, 1:num_channels);
    channels_2 = oxyData(:, num_channels+1:2*num_channels); % 默认是1台机子的第二个帽子的通道
    num_freqs = length(freqRange);

    results.filename = dataFiles(i).name;
    frequency_calculated = false;

    % 计算所有通道对的 Rsq 值
    for ch1 = 1:num_channels
        for ch2 = ch1+1:num_channels
            s1_sub1 = channels_1(:, ch1);
            s2_sub1 = channels_1(:, ch2);
            s1_sub2 = channels_2(:, ch1);
            s2_sub2 = channels_2(:, ch2);

            % 计算 Sub1 和 Sub2 内部的 Rsq 值，并转换为 z 分数
            % Sub1 的脑内Functional connectivity
            [Rsq_sub1, period, ~, ~, ~] = wtc(s1_sub1, s2_sub1, 'mcc', 0);
            Rsq_z_sub1 = fisher_transform(Rsq_sub1);

            if ~frequency_calculated
                frequency = 1 ./ period; 
                results.frequency = frequency(freqRange); 
                frequency_calculated = true; 
            end
            % Sub2 的脑内Functional connectivity
            % %如果仅有一个光极板在工作，可以不计算sub2的Fc，也不用计算后续的脑同步值，直接在后面的相关脚本前加 %
            % ，%开头的所在行的代码不会执行，仅作为注释。
            
            [Rsq_sub2, ~, ~, ~, ~] = wtc(s1_sub2, s2_sub2, 'mcc', 0);
            Rsq_z_sub2 = fisher_transform(Rsq_sub2);

            % 针对每个事件计算 Rsq 范围的平均值
            for event_idx = 1:length(event_points)
                event_range = event_points{event_idx};
                
                if ~isfield(results, ['event' num2str(event_idx)]) %检查 results 结构体中是否不（~）存在当前事件编号（如 'event1'、'event2' 等）对应的字段。
                    results.(['event' num2str(event_idx)]).Sub1_Rsq_matrix = zeros(num_channels, num_channels, num_freqs);
                    results.(['event' num2str(event_idx)]).Sub2_Rsq_matrix = zeros(num_channels, num_channels, num_freqs);
                end

                results.(['event' num2str(event_idx)]).Sub1_Rsq_matrix(ch1, ch2, :) = mean(Rsq_z_sub1(freqRange, event_range), 2);
                results.(['event' num2str(event_idx)]).Sub2_Rsq_matrix(ch1, ch2, :) = mean(Rsq_z_sub2(freqRange, event_range), 2);
            end
        end
    end

    % 计算 S1 和 S2 的脑同步（跨被试）
    for ch1 = 1:num_channels
        for ch2 = 1:num_channels
            s1_sub1 = channels_1(:, ch1);
            s2_sub2 = channels_2(:, ch2);

            % 计算跨被试 Rsq 值
            [Rsq_inter, ~, ~, ~, ~] = wtc(s1_sub1, s2_sub2, 'mcc', 0);
            Rsq_z_inter = fisher_transform(Rsq_inter);

            % 针对每个事件计算跨被试 Rsq 范围的平均值
            for event_idx = 1:length(event_points)
                event_range = event_points{event_idx};
                
                if ~isfield(results, ['event' num2str(event_idx)])
                    results.(['event' num2str(event_idx)]).Inter_Rsq_matrix = zeros(num_channels, num_channels, num_freqs);
                end

                results.(['event' num2str(event_idx)]).Inter_Rsq_matrix(ch1, ch2, :) = mean(Rsq_z_inter(freqRange, event_range), 2);
            end
        end
    end

    outputFileName = sprintf(outputFilePattern, erase(dataFiles(i).name, '.mat'));
    fileSaveStartTime = tic;
    save(outputFileName, 'results');
    fileSaveElapsedTime = toc(fileSaveStartTime);
    fprintf('文件 %s 处理并保存完成，保存用时：%.2f 秒\n', outputFileName, fileSaveElapsedTime);
end




%% ================== 第六步 提取第五步计算出来的fc（脑内）或wtc值（脑间同步），用于统计检验 ==================
%% ================== 生成三个 5D 数据矩阵 ==================
clear; close all; clc;

%% ---------- 用户配置部分 ----------
filePath = 'D:\Research data\Study_AI_hyperscanning\Raw data\S4_WTC_分阶段\';
filePrefix = 'WTC_wtccbsi_G';

startIndex = 1;
endIndex = 120;
numSubjects = endIndex - startIndex + 1;

variablesToExtract = {'Sub1_Rsq_matrix', 'Sub2_Rsq_matrix', 'Inter_Rsq_matrix'};
numEvents = 12;
numChannels = 35;
numFrequencies = 109;

outputFolder = filePath;   % 输出到同一文件夹
if ~exist(outputFolder, 'dir')
    mkdir(outputFolder);
end

%% ---------- 预分配 5 维矩阵 ----------
Sub1_Rsq_all  = nan(numChannels, numChannels, numEvents, numSubjects, numFrequencies);
Sub2_Rsq_all  = nan(numChannels, numChannels, numEvents, numSubjects, numFrequencies);
Inter_Rsq_all = nan(numChannels, numChannels, numEvents, numSubjects, numFrequencies);

%% ---------- 主循环：读取每个文件 ----------
validSubjects = 0;

for fileNum = startIndex:endIndex

    fileName = fullfile(filePath, sprintf('%s%02d.mat', filePrefix, fileNum));
    fprintf('处理文件 %d/%d: %s\n', fileNum, endIndex, fileName);

    if ~exist(fileName, 'file')
        fprintf('  文件不存在，跳过\n');
        continue;
    end

    try
        loadedData = load(fileName);

        if ~isfield(loadedData, 'results')
            error('文件缺少 results 结构体');
        end

        validSubjects = validSubjects + 1;

        % -------- 处理 12 个 event --------
        for e = 1:numEvents
            eventName = sprintf('event%d', e);

            if ~isfield(loadedData.results, eventName)
                error('文件缺少 %s', eventName);
            end

            % -------- 处理 3 个变量 --------
            for v = 1:length(variablesToExtract)
                varName = variablesToExtract{v};
                currentMatrix = loadedData.results.(eventName).(varName);

                if ~isequal(size(currentMatrix), [numChannels, numChannels, numFrequencies])
                    error('%s 的矩阵尺寸不符合要求', varName);
                end

                % 存入对应 5D 矩阵
                switch varName
                    case 'Sub1_Rsq_matrix'
                        Sub1_Rsq_all(:,:,e,validSubjects,:) = currentMatrix;

                    case 'Sub2_Rsq_matrix'
                        Sub2_Rsq_all(:,:,e,validSubjects,:) = currentMatrix;

                    case 'Inter_Rsq_matrix'
                        Inter_Rsq_all(:,:,e,validSubjects,:) = currentMatrix;
                end
            end
        end

    catch ME
        fprintf('文件 %s 出错: %s\n', fileName, ME.message);
        continue;
    end
end

%% ---------- 截取实际有效维度 ----------
Sub1_Rsq_all  = real(Sub1_Rsq_all(:,:,:,1:validSubjects,:));
Sub2_Rsq_all  = real(Sub2_Rsq_all(:,:,:,1:validSubjects,:));
Inter_Rsq_all = real(Inter_Rsq_all(:,:,:,1:validSubjects,:));

%% ---------- 保存 ----------


save(fullfile(outputFolder, 'WTC_5D_Sub1_Rsq.mat'),  'Sub1_Rsq_all',  '-v7');
save(fullfile(outputFolder, 'WTC_5D_Sub2_Rsq.mat'),  'Sub2_Rsq_all',  '-v7');
save(fullfile(outputFolder, 'WTC_5D_Inter_Rsq.mat'), 'Inter_Rsq_all', '-v7');

fprintf('完成！共处理 %d 个有效文件。\n', validSubjects);






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

