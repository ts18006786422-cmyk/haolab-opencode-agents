%% 注意
   % 此脚本适合于非嵌套数据的beta极端值处理，即只用于一个数据只有一个被试通道数据。
%% ==================== 参数设置 ====================
clear; clc;

% 直接将load的结果赋值给变量data
mydata = load('D:\Research data\Study_Cliff illusion\20260103神经数据（悦悦）\BetaforStatistics.mat');
field_names = fieldnames(mydata);
data = mydata.(field_names{1});

load('D:\Research data\Study_Cliff illusion\20260103神经数据（悦悦）\groupID.mat');     % 要自己先把每个被试的分组信息创建好（第一列被试编号，第二列为分组编号信息，以mat文件保存，变量名就是groupID。
group = groupID(:,2);    % 取第二列作为真实的组编号
groups = unique(group);  % 例如 [1,2,3]


events_to_use = [3, 5];            % 你要分析的事件编号（单个）
method_std = 1;                 % 1=±2SD, 2=±3SD, 3=IQR
replace_method = 1;             % 1=均值替换, 2=winsorizing

out_folder = 'D:\Research data\Study_Cliff illusion\20260103神经数据（悦悦）\output_beta2/';     % 保存路径
if ~exist(out_folder, 'dir')
    mkdir(out_folder);
end

%% ========= Step 0：基线校正（事件 1-6 − 事件 1（C1））注意，这里只适用于任务阶段（2&3）的基线矫正，预测阶段的可能不适合 ====================
% data: 95×70×6
baseline = data(:,:,1);               % 事件1 C1（基线），尺寸： data: 95×70×1
baseline = repmat(baseline, [1 1 6]); % 扩展到事件维度，变成 95×70×6
           % 因为原始 baseline（事件 1）只有一个事件维，我们使用 repmat(...,[1 1 6 ]) 将其在事件维复制 6次，使其尺寸与完整 beta 数据匹配，从而能够逐点执行事件差值（event subtraction）进行基线校正,否则维度不匹配，不能相减。
data_bc = data - baseline;                 % 基线矫正

% 若你希望 event1 结果保持 0（推荐保留），不用改；
% 若你想保留 event1 原始值，把下面打开（默认关闭）
% data_bc(:,:,1) = data(:,:,1);


%% ==================== Step 2：提取基线校正后的指定事件（降维 3D → 2D） ====================

for i = 1:length(events_to_use)
data3(:,:,i) = data_bc(:,:,events_to_use(i));  % --> 95×70
end

betaOri  = data3; 

%% ==================== Step 3：对每个通道组合进行极端值处理 ====================

% data3(subj,ch,event)
[nSubj,n1,event] = size(data3);
beta_clean = data3;   % 用于存放清理后的数据
singlebrain = n1

for numE = 1:event
for c1 = 1:singlebrain
        
        x = squeeze(data3(:,c1,numE));    % 95 x numch
        
        x_clean = x;   % 用于回填

        % -------- 按被试组号处理 outliers --------
        for g = groups'
            idx = (group == g);     % 当前组的被试
      
            x_group = x(idx);       % 当前组的数据（n_g × 1）
            
           if all(isnan(x_group)), continue; end   % 这一步是为了排除全是NAN的组（即数据缺失的几组）
           
            % 调用增强版 outlier 函数
            [x_group_clean, ~] = clean_outliers(x_group, method_std, replace_method);

            x_clean(idx) = x_group_clean;
        end

        beta_clean(:,c1,numE) = x_clean;
end
end
disp('极端值处理完成！');

%% ==================== Step 4：保存结果 ====================

save(fullfile(out_folder, ...
    sprintf('beta_clean_events_%s.mat', ...
    mat2str(events_to_use))), ...
    'betaOri','beta_clean','events_to_use','method_std','replace_method');

disp('已保存处理后的 .mat 文件！');
