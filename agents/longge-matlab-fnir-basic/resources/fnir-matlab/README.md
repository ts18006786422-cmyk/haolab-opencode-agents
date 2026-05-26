# fNIR MATLAB Script Resource Guide

This folder is a session-local copy of the fNIR/fNIRS MATLAB scripts and supporting resources from the workspace. It is intended as a portable reference for future agents working in this session template.

Do not treat these copied files as the user's active analysis workspace unless the user explicitly says so. For real analysis, inspect the current workspace files and data paths first.

## Main Workflow Scripts

- `Script_betaanalysis.m`: HuiChuang-style beta analysis pipeline. It includes raw `.mat` conversion into `nirs_data`, CBSI, wavelet denoise, NIRS-SPM GLM specification/estimation, beta extraction, and FDR placeholder.
- `Script_betaanalysis_Hitachi.m`: Hitachi CSV beta analysis variant. It calls `readHitachData`, then uses the same downstream CBSI/wavelet/GLM beta logic. It requires a compatible `readHitachData.m` or replacement reader.
- `Script_fcandwtcanalysis.m`: HuiChuang-style WTC/FC pipeline. It includes conversion/preprocessing, WTC computation, Sub1/Sub2 brain-internal FC, inter-brain synchronization, and 5D matrix extraction.
- `Script_fcandwtcanalysis_epoch.m`: WTC/FC epoch variant. It splits task periods, for example into early/late task windows, before WTC/FC extraction.
- `Script_Hitachi_fcandwtcanalysis.m`: Hitachi CSV conversion plus downstream beta/FC/WTC style workflow. It also depends on `readHitachData`.

## Cleaning And Statistics Helpers

- `DataCleanning_Forbetaanalysis_singlesubject.m`: Beta outlier-cleaning workflow for single-person/non-nested channel data.
- `DataCleanning_Forbetaanalysis_pairedsubject.m`: Beta outlier-cleaning workflow for paired/hyperscanning data. It assumes 70 channels are split into two 35-channel participants.
- `clean_outliers/clean_outliers.m`: Helper for group-wise extreme value handling. Supports 2SD, 3SD, IQR, mean replacement, winsorizing, and NaN filling.
- `FOIselect_OneT.m`: Frequency-of-interest selection script. It computes task minus baseline WTC, tests each frequency with a one-sample right-tailed t-test, excludes predefined frequency indices, and applies FDR.
- `fdr/fdr.m`: Benjamini-Hochberg/Yekutieli FDR correction helper.
- `fdr/brat_MulCC.m`: Additional multiple-comparison correction utility.

## Preprocessing Helper

- `wtc_denoise/par_wtc_denoise.m`: Wavelet-based denoising helper. It uses `parfor`, so Parallel Computing Toolbox or a `parfor` to `for` fallback may be needed.

## Visualization And Reference Resources

- `xjview96/xjview/xjview.m`: xjview visualization tool.
- `xjview96/xjview/*.img` and `*.hdr`: AAL, Brodmann, ch2, ch2bet, and example Analyze image resources.
- `xjview96/xjview/TDdatabase.mat`: Talairach daemon/database-style reference used by xjview.
- `xjview96/xjview/xjview_render.mat`: Render resource for xjview.

These resources can help with SPM/xjview visualization and brain-region reference, but they do not constitute a full automated fNIRS channel-localization pipeline.

## Other Reference Files

- `团体创意生成中wtc的兴趣频段.xls`: Likely a project-specific WTC frequency-of-interest result/reference table for group creativity analysis.

## Device/Data Distinction

- HuiChuang-like data usually uses `Gxx_data.mat` plus `Gxx_mark.mat`, with variables such as `dataSave.HbO`, `dataSave.HbR`, `dataSave.tHRF`, and `onsets`. Scripts often assume `fs = 11`, a channel map such as `raw_NumofCh.mat`, and active channel ranges such as `[1:35]` plus `[71:105]`.
- Hitachi data usually uses `Gxx.csv` and a reader call like `[hbo, hbr, mark] = readHitachData({input_file})`. Scripts often assume `fs = 10` for Hitachi7100.
- Both routes aim to produce a unified `nirs_data` structure with `oxyData`, `dxyData`, `vector_onset`, `fs`, and `nch`.

## Recommended Agent Workflow

1. Verify a callable MATLAB runtime with non-interactive `-batch` support.
2. Determine data type/device from files and variables, then ask the user to confirm if inference is possible.
3. Check required dependencies for the requested workflow: NIRS-SPM/SPM for beta, `wtc` for WTC/FC, `readHitachData` for Hitachi CSV, Parallel Computing Toolbox or fallback for `parfor` denoise.
4. Track the current processing stage: raw data, converted `nirs_data`, CBSI output, wavelet-denoised output, beta output, WTC output, statistics matrices, or cleaned matrices.
5. If the agent just performed an automated step, do not ask whether that step was done. After automated preprocessing, ask whether the user wants non-destructive manual QC outputs before formal beta/WTC/statistics.
6. Confirm analysis parameters: paths, subject range, sampling rate, channel layout, marker count, event names, event durations, baseline rule, output folders, statistical design, and FDR/multiple-comparison scope.
7. Avoid destructive operations such as renaming, moving, deleting, or overwriting raw files unless the user explicitly confirms backup and target paths.

## QC Gap To Remember

The scripts include CBSI, wavelet denoise, and some file/marker/channel checks. They do not provide a complete systematic QC workflow for bad channels, saturation, severe motion artifacts, marker timing validation, subject/channel exclusion, SNR/SCI/PSP, short-separation regression, or full reproducible QC reports.

Before formal beta, WTC, FC, FOI, or statistics, if manual QC status is unknown, explain why QC matters and offer to create a non-destructive MATLAB QC script that generates outputs such as `qc_summary.csv`, `marker_check.csv`, `suspicious_channels.csv`, `subject_timecourse_plots/`, and `qc_report.mat`.
