# 龙哥-matlab-fNIR基础分析

Version: 0.1.0

MATLAB fNIR/fNIRS basic analysis session template with workflow guidance and reference scripts.

## Intended Use

Use this template to collaborate on MATLAB-based fNIR/fNIRS analysis. It includes portable workflow guidance, dependency checks, output-structure rules, and copied reference scripts for beta analysis, FC/WTC workflows, Hitachi/HuiChuang variants, denoising, FDR helpers, and xjview resources.

## Included Managed Files

- `assemble.ts`
- `assemble-schema.md`
- `fnir-analysis-workflow.json`
- `fnir-project-resource-guide.json`
- `resources/fnir-matlab/README.md`
- `resources/fnir-matlab/**/*.m`
- `resources/fnir-matlab/**/*.mat`
- `resources/fnir-matlab/**/*.hdr`
- `resources/fnir-matlab/**/*.img`
- `resources/fnir-matlab/团体创意生成中wtc的兴趣频段.xls`
- `system/README.md`
- `tool/README.md`

## Metadata

- Updater: `opencode-test`
- Updated: 2026-05-26
- Source session: `ses_1a0a0e829ffesjnnBfXe1N2Q1T`
- Repository path: `agents/longge-matlab-fnir-basic`

## Notes

- The copied `resources/fnir-matlab/` files are reference resources for the template. For real analysis, inspect the user's active workspace and data files first.
- The template expects agents to verify MATLAB availability and required toolboxes/functions before attempting execution.
- This package uses root-level assemble JSON context files plus `resources/`; installation requires a manager tool version that supports those package files.

## Changelog

### 0.1.0 - 2026-05-26

- Initial export of the MATLAB fNIR/fNIRS basic analysis template.
- Includes portable workflow guidance, resource guide, and copied MATLAB reference resources.
