# 评分助手

Reusable opencode agent-session template for standardized AI rating, expert sampling, and agreement analysis workflows.

## Contents

- `rating_workflow.json`: session context that guides the agent through data standardization, scoring, expert review, and agreement analysis.
- `rating_config.template.json`: default scoring configuration template.
- `resources/rating_engine.py`: standalone multi-model AI scoring script.
- `resources/agreement_analysis.py`: agreement analysis and expert-rating sample generator.

## Notes

- Configure API credentials outside the template, normally through `RATING_API_KEY`.
- Generated project outputs should be written under a workspace output directory such as `rating_output/`.

## Changelog

- 2026-05-26: Initial upload by `Tong` from `ses_1a06be178ffeZOlFZpjccSeDPt`.
