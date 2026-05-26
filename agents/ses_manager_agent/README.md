# ses_manager_agent

Version: 0.1.1

Manager session template for installing, exporting, and uploading opencode session templates.

## Intended Use

Use this template for a global manager session that maintains session-local context, system prompt overrides, tools, and shareable agent-session packages.

## Included Managed Files

- `assemble.ts`
- `assemble-schema.md`
- `context/default-agent-repository.json`
- `context/manager-agent.json`
- `context/session-install-workflow.json`
- `context/session-upload-workflow.json`
- `system/instructions.txt`
- `system/README.md`
- `tool/manage-session.ts`
- `tool/README.md`
- `tool/session-dispatch.ts`

## Metadata

- Updater: `opencode-test`
- Updated: 2026-05-26
- Source session: `ses_manager_agent`

## Notes

- `context/manager-nickname.json` is intentionally excluded. It is local contributor identity, not part of the reusable template.
- The upload workflow uses GitHub branches and PRs; template changes are not available on `main` until reviewed and merged.

## Changelog

### 0.1.1 - 2026-05-26

- Updated `tool/manage-session.ts` to package root-level assemble JSON files and `resources/` directories.
- Enables templates with reference resources, such as MATLAB fNIR/fNIRS analysis packages, to install more completely.

### 0.1.0 - 2026-05-25

- Initial manager session template export.
- Includes default repository policy, install workflow, upload workflow, and session-local management tools.
