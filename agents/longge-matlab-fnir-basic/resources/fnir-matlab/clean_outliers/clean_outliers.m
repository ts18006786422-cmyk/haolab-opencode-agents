function [x_clean, outlier_idx] = clean_outliers(x, method_std, replace_method)
% clean_outliers:
%   - 先处理 NAN：记录并从判断集中移除
%   - 判断极端值（±2SD, ±3SD, IQR）
%   - 替换极端值 AND 原来的 NaN
%   - 替换方式：均值替换 or winsorizing
%
% 输入：
%   x              - 列向量 Nx1
%   method_std     - 极端值判断方法（1=2SD, 2=3SD, 3=IQR）
%   replace_method - 替换方式（1=均值替换, 2=winsorizing）
%
% 输出：
%   x_clean     - 处理后的 Nx1 列向量
%   outlier_idx - 极端值位置（不包含 NAN 的判断）
%
% 输入参数：
%   x              - 输入数据列向量 (Nx1)
%   method_std     - 极端值判定方法：
%                       1 = ±2 SD
%                       2 = ±3 SD
%                       3 = IQR (箱线图界限)
%   replace_method - 替换极端值的方法：
%                       1 = 组均值替换
%                       2 = Winsorizing（替换为界限值）
%
% 输出：
%   x_clean        - 清理后的数据
%   outlier_idx    - 极端值位置索引 (logical Nx1)
%
% 例子：
%   [cleaned, idx] = clean_outliers(x, 3, 2); 
%   -> IQR 检测 + winsorizing 替换



    % ------ 确保是列向量 ------
    if ~iscolumn(x)
        error('输入必须是列向量 Nx1');
    end

    % ------ 备份输出 ------
    x_clean = x;

    % ------ Step 0: 找出 NaN 并暂时移除 ------
    nan_idx = isnan(x);
    x_valid = x(~nan_idx);   % 去掉 NaN 后的数据

    % 如果全是 NaN，直接返回
    if all(nan_idx)
        warning('该向量全为 NaN，无法进行 outlier 处理');
        return;
    end

    % ------ Step 1: 根据方法计算界限 ------
    switch method_std
        case 1  % ±2 SD
            mu = mean(x_valid);
            sd = std(x_valid);
            lower = mu - 2 * sd;
            upper = mu + 2 * sd;

        case 2  % ±3 SD
            mu = mean(x_valid);
            sd = std(x_valid);
            lower = mu - 3 * sd;
            upper = mu + 3 * sd;

        case 3  % IQR
            Q1 = quantile(x_valid, 0.25);
            Q3 = quantile(x_valid, 0.75);
            IQR_val = Q3 - Q1;
            lower = Q1 - 1.5 * IQR_val;
            upper = Q3 + 1.5 * IQR_val;

        otherwise
            error('method_std 必须为 1=2SD, 2=3SD, 3=IQR');
    end

    % ------ Step 2: 判断 outlier（只对有效值 x_valid）------
    outlier_idx_valid = (x_valid < lower) | (x_valid > upper);

    % ------ Step 3: 执行替换（对有效值）------
    switch replace_method

        case 1  % 组均值替换
            replacement = mean(x_valid(~outlier_idx_valid)); % 组均值
            x_valid_clean = x_valid;
            x_valid_clean(outlier_idx_valid) = replacement;

        case 2  % Winsorizing
            x_valid_clean = x_valid;
            x_valid_clean(x_valid < lower) = lower;
            x_valid_clean(x_valid > upper) = upper;
            replacement = [];  % 后面用于补 NaN 的替换值由 NaN 决定

        otherwise
            error('replace_method 必须为 1=均值替换 or 2=winsorizing');
    end

    % ------ Step 4: NaN 的替换策略 ------
    if replace_method == 1
        % 均值替换：NaN 也替换成组均值
        x_valid_nan_filled = replacement;

    elseif replace_method == 2
        % Winsorizing：NaN 替换为中间值（界限平均）
        mid_val = (upper + lower) / 2;
        x_valid_nan_filled = mid_val;
    end

    % ------ Step 5: 重新把数据放回 x_clean 中 ------
    x_clean(~nan_idx) = x_valid_clean;         % 非 NaN 的清理值
    x_clean(nan_idx)  = x_valid_nan_filled;    % NaN 的填充值

    % ------ 返回极端值标记（扩展回 Nx1）------
    outlier_idx = false(size(x));
    outlier_idx(~nan_idx) = outlier_idx_valid;

end
