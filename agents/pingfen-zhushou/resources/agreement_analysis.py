#!/usr/bin/env python3
"""Generic agreement analysis and expert-rating sample generator.

Commands:
  python agreement_analysis.py agreement --input scores.xlsx --config rating_config.json --output agreement.xlsx
  python agreement_analysis.py sample-expert --input scores.xlsx --config rating_config.json --output expert_sample.xlsx
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import re
from pathlib import Path
from typing import Any


def ensure_pandas():
    try:
        import pandas as pd
    except ImportError as exc:
        raise SystemExit("Missing dependency: pandas. Install with `pip install pandas openpyxl`.") from exc
    return pd


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_table(path: str | Path) -> pd.DataFrame:
    pd = ensure_pandas()
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xls"}:
        return pd.read_excel(path, engine="openpyxl")
    if suffix == ".csv":
        return pd.read_csv(path)
    raise ValueError(f"Unsupported file type: {suffix}. Use .xlsx, .xls, or .csv")


def write_workbook(path: str | Path, sheets: dict[str, pd.DataFrame]) -> None:
    pd = ensure_pandas()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".csv":
        first = next(iter(sheets.values()))
        first.to_csv(path, index=False, encoding="utf-8-sig")
        return
    with pd.ExcelWriter(path, engine="openpyxl") as writer:
        for name, df in sheets.items():
            safe_name = name[:31]
            df.to_excel(writer, sheet_name=safe_name, index=False)


def get_nested(config: dict[str, Any], path: list[str], default: Any = None) -> Any:
    current: Any = config
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def dimension_names(config: dict[str, Any]) -> list[str]:
    dimensions = get_nested(config, ["rating", "dimensions"], config.get("dimensions") or [])
    names = []
    for dim in dimensions:
        if isinstance(dim, dict):
            name = dim.get("name") or dim.get("dimension")
            if name:
                names.append(str(name))
    return names


def score_column_name(dimension: str, rater: str) -> str:
    clean_dimension = re.sub(r"\s+", "_", str(dimension).strip())
    clean_rater = re.sub(r"\s+", "_", str(rater).strip())
    return f"{clean_dimension}_score_{clean_rater}"


def configured_score_columns(df: pd.DataFrame, config: dict[str, Any]) -> dict[str, dict[str, str]]:
    explicit = get_nested(config, ["agreement", "dimensions"])
    if isinstance(explicit, list) and explicit:
        result: dict[str, dict[str, str]] = {}
        for dim in explicit:
            if not isinstance(dim, dict):
                continue
            name = str(dim.get("name") or dim.get("dimension") or "")
            score_columns = dim.get("score_columns") or {}
            if name and isinstance(score_columns, dict):
                result[name] = {str(rater): str(col) for rater, col in score_columns.items() if str(col) in df.columns}
        if result:
            return result

    result = {}
    models = [str(model) for model in config.get("models", [])]
    for dim in dimension_names(config):
        columns: dict[str, str] = {}
        for model in models:
            col = score_column_name(dim, model)
            if col in df.columns:
                columns[model] = col

        prefix = re.escape(re.sub(r"\s+", "_", dim).strip()) + r"_score_"
        for col in df.columns:
            if re.match(prefix, str(col)):
                rater = str(col)[len(re.sub(r"\s+", "_", dim).strip()) + len("_score_"):]
                columns.setdefault(rater, str(col))
        if columns:
            result[dim] = columns
    return result


def pairwise_metrics(values_a: pd.Series, values_b: pd.Series) -> dict[str, Any]:
    pd = ensure_pandas()
    paired = pd.DataFrame({"a": pd.to_numeric(values_a, errors="coerce"), "b": pd.to_numeric(values_b, errors="coerce")}).dropna()
    n = len(paired)
    if n == 0:
        return {"n": 0, "pearson": None, "spearman": None, "mae": None, "rmse": None, "exact_agreement": None, "within_1_agreement": None, "mean_diff": None}

    diff = paired["a"] - paired["b"]
    pearson = paired["a"].corr(paired["b"], method="pearson") if n >= 2 else None
    spearman = paired["a"].corr(paired["b"], method="spearman") if n >= 2 else None
    mae = diff.abs().mean()
    rmse = math.sqrt((diff ** 2).mean())
    return {
        "n": int(n),
        "pearson": None if pd.isna(pearson) else float(pearson),
        "spearman": None if pd.isna(spearman) else float(spearman),
        "mae": float(mae),
        "rmse": float(rmse),
        "exact_agreement": float((diff == 0).mean()),
        "within_1_agreement": float((diff.abs() <= 1).mean()),
        "mean_diff": float(diff.mean()),
    }


def run_agreement(input_path: str, config_path: str, output_path: str, expert_scores_path: str | None = None) -> None:
    pd = ensure_pandas()
    config = load_json(config_path)
    df = load_table(input_path)
    if expert_scores_path:
        expert_df = load_table(expert_scores_path)
        id_col = get_nested(config, ["input", "id_column"], "id")
        if id_col not in df.columns or id_col not in expert_df.columns:
            raise ValueError(f"Both AI and expert score files must contain id column: {id_col}")
        expert_cols = [col for col in expert_df.columns if col != id_col and col not in df.columns]
        df = df.merge(expert_df[[id_col] + expert_cols], on=id_col, how="inner")

    dimensions = configured_score_columns(df, config)
    if not dimensions:
        raise ValueError("No score columns found. Configure agreement.dimensions or use {dimension}_score_{rater} columns.")

    rows = []
    raw_cols = []
    for dimension, columns in dimensions.items():
        raw_cols.extend(columns.values())
        for (rater_a, col_a), (rater_b, col_b) in itertools.combinations(columns.items(), 2):
            metrics = pairwise_metrics(df[col_a], df[col_b])
            rows.append({
                "dimension": dimension,
                "rater_a": rater_a,
                "rater_b": rater_b,
                "column_a": col_a,
                "column_b": col_b,
                **metrics,
            })

    pairwise = pd.DataFrame(rows)
    if pairwise.empty:
        summary = pd.DataFrame(columns=["dimension", "pairs", "mean_pearson", "mean_spearman", "mean_mae", "mean_rmse", "mean_exact_agreement", "mean_within_1_agreement"])
    else:
        summary = pairwise.groupby("dimension", dropna=False).agg(
            pairs=("dimension", "count"),
            mean_pearson=("pearson", "mean"),
            mean_spearman=("spearman", "mean"),
            mean_mae=("mae", "mean"),
            mean_rmse=("rmse", "mean"),
            mean_exact_agreement=("exact_agreement", "mean"),
            mean_within_1_agreement=("within_1_agreement", "mean"),
        ).reset_index()

    id_col = get_nested(config, ["input", "id_column"], "id")
    keep_cols = [col for col in [id_col, get_nested(config, ["input", "question_column"], "question"), get_nested(config, ["input", "answer_column"], "answer")] if col in df.columns]
    raw_scores = df[keep_cols + sorted(set(raw_cols))]
    write_workbook(output_path, {
        "pairwise_agreement": pairwise,
        "dimension_summary": summary,
        "raw_scores": raw_scores,
    })
    print(f"Saved agreement report to {output_path}")


def sample_expert(input_path: str, config_path: str, output_path: str) -> None:
    config = load_json(config_path)
    df = load_table(input_path)
    id_col = get_nested(config, ["input", "id_column"], "id")
    question_col = get_nested(config, ["input", "question_column"], "question")
    answer_col = get_nested(config, ["input", "answer_column"], "answer")
    for col in [id_col, question_col, answer_col]:
        if col not in df.columns:
            raise ValueError(f"Missing required column for expert sample: {col}")

    sample_size = int(get_nested(config, ["expert_review", "sample_size"], min(50, len(df))))
    random_seed = int(get_nested(config, ["expert_review", "random_seed"], 42))
    include_ai_scores = bool(get_nested(config, ["expert_review", "include_ai_scores"], False))
    expert_count = int(get_nested(config, ["expert_review", "expert_count"], 1))
    sample_size = min(max(1, sample_size), len(df))

    sample = df.sample(n=sample_size, random_state=random_seed).copy()
    base_cols = [id_col, question_col, answer_col]
    output = sample[base_cols].copy()

    if include_ai_scores:
        score_cols = [col for col in sample.columns if "_score_" in str(col)]
        for col in score_cols:
            output[col] = sample[col]

    for dim in dimension_names(config):
        if expert_count <= 1:
            output[score_column_name(dim, "expert")] = ""
        else:
            for idx in range(1, expert_count + 1):
                output[score_column_name(dim, f"expert_{idx}")] = ""

    write_workbook(output_path, {"expert_rating": output})
    print(f"Saved expert rating sample to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Agreement analysis and expert sample generation.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    agreement = subparsers.add_parser("agreement", help="Compute pairwise agreement among score columns")
    agreement.add_argument("--input", required=True, help="Input score table")
    agreement.add_argument("--expert-scores", help="Optional expert score table to merge by id")
    agreement.add_argument("--config", required=True, help="Rating/agreement config JSON")
    agreement.add_argument("--output", required=True, help="Output agreement workbook")

    sample = subparsers.add_parser("sample-expert", help="Generate expert rating sample workbook")
    sample.add_argument("--input", required=True, help="Input scored table")
    sample.add_argument("--config", required=True, help="Rating config JSON")
    sample.add_argument("--output", required=True, help="Output expert sample workbook")

    args = parser.parse_args()
    if args.command == "agreement":
        run_agreement(args.input, args.config, args.output, args.expert_scores)
    elif args.command == "sample-expert":
        sample_expert(args.input, args.config, args.output)


if __name__ == "__main__":
    main()
