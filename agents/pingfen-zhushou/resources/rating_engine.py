#!/usr/bin/env python3
"""Standalone multi-model rating engine.

Expected input data columns, by default:
- id: stable row id
- question: prompt, task, or question background
- answer: text to score

Example:
  python rating_engine.py --input rating_input.xlsx --config rating_config.json --output ai_scored.xlsx
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests


def ensure_pandas():
    try:
        import pandas as pd
    except ImportError as exc:
        raise SystemExit("Missing dependency: pandas. Install with `pip install pandas openpyxl requests`.") from exc
    return pd


@dataclass(frozen=True)
class RatingJob:
    model: str
    dimension: dict[str, Any]
    question: str
    answers: list[str]
    indexes: list[int]
    column: str


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
    raise ValueError(f"Unsupported input file type: {suffix}. Use .xlsx, .xls, or .csv")


def save_table(df: pd.DataFrame, path: str | Path) -> None:
    pd = ensure_pandas()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xls"}:
        df.to_excel(path, index=False)
        return
    if suffix == ".csv":
        df.to_csv(path, index=False, encoding="utf-8-sig")
        return
    raise ValueError(f"Unsupported output file type: {suffix}. Use .xlsx or .csv")


def get_nested(config: dict[str, Any], path: list[str], default: Any = None) -> Any:
    current: Any = config
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def normalize_dimensions(config: dict[str, Any]) -> list[dict[str, Any]]:
    dimensions = get_nested(config, ["rating", "dimensions"])
    if dimensions is None:
        dimensions = config.get("dimensions") or config.get("ratings")
    if not isinstance(dimensions, list) or not dimensions:
        raise ValueError("Config must include rating.dimensions as a non-empty list")

    normalized = []
    for item in dimensions:
        if not isinstance(item, dict):
            raise ValueError("Each rating dimension must be an object")
        name = item.get("name") or item.get("dimension")
        prompt = item.get("prompt")
        if not name or not prompt:
            raise ValueError("Each rating dimension requires name and prompt")
        normalized.append({
            "name": str(name),
            "label": str(item.get("label") or name),
            "prompt": str(prompt),
            "format": str(item.get("format") or "Return an integer score from 1 to 5"),
        })
    return normalized


def normalize_models(config: dict[str, Any]) -> list[str]:
    models = config.get("models") or get_nested(config, ["model", "names"])
    if models is None and get_nested(config, ["model", "name"]):
        models = [get_nested(config, ["model", "name"])]
    if not isinstance(models, list) or not models:
        raise ValueError("Config must include models as a non-empty list")
    return [str(model) for model in models]


def score_column_name(dimension: str, model: str) -> str:
    clean_dimension = re.sub(r"\s+", "_", str(dimension).strip())
    clean_model = re.sub(r"\s+", "_", str(model).strip())
    return f"{clean_dimension}_score_{clean_model}"


def resolve_api_key(config: dict[str, Any]) -> str:
    api = config.get("api") or {}
    key = api.get("api_key") or api.get("key")
    if key:
        return str(key).strip()

    key_file = api.get("api_key_file") or api.get("key_file")
    if key_file:
        content = Path(key_file).expanduser().read_text(encoding="utf-8").strip()
        try:
            data = json.loads(content)
            key = data.get("api_key") or data.get("key")
            if key:
                return str(key).strip()
        except json.JSONDecodeError:
            pass
        return content.strip()

    env_name = api.get("api_key_env") or "RATING_API_KEY"
    key = os.environ.get(str(env_name), "")
    if key:
        return key.strip()
    raise ValueError("Missing API key. Set api.api_key, api.api_key_file, or api.api_key_env")


def resolve_chat_url(config: dict[str, Any]) -> str:
    api = config.get("api") or {}
    chat_url = api.get("chat_url") or api.get("api_url")
    if chat_url:
        return str(chat_url).rstrip("/")
    base_url = api.get("base_url")
    if base_url:
        return str(base_url).rstrip("/") + "/chat/completions"
    raise ValueError("Missing API chat URL. Set api.chat_url or api.base_url")


def build_headers(config: dict[str, Any]) -> dict[str, str]:
    api = config.get("api") or {}
    key = resolve_api_key(config)
    prefix = str(api.get("authorization_prefix", "Bearer")).strip()
    authorization = key
    if prefix and not key.lower().startswith(prefix.lower() + " "):
        authorization = f"{prefix} {key}"
    return {"Authorization": authorization, "Content-Type": "application/json"}


def parse_scores(content: str, expected: int) -> list[Any]:
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```[a-zA-Z]*\n", "", content)
        content = re.sub(r"\n```$", "", content)
    try:
        scores = json.loads(content)
    except Exception:
        match = re.search(r"\[[\s\S]*?\]", content)
        if not match:
            raise
        scores = json.loads(match.group(0))
    if not isinstance(scores, list):
        raise ValueError("Model response is not a JSON array")
    if len(scores) < expected:
        scores += [None] * (expected - len(scores))
    return scores[:expected]


def request_scores(job: RatingJob, config: dict[str, Any], headers: dict[str, str], chat_url: str) -> tuple[RatingJob, list[Any], bool, str]:
    global_prompt = get_nested(config, ["rating", "global_prompt"], "You are a strict, fair, and consistent evaluator.")
    temperature = get_nested(config, ["model", "temperature"], 0)
    timeout = get_nested(config, ["model", "timeout_seconds"], get_nested(config, ["api", "timeout_seconds"], 60))
    max_retries = int(get_nested(config, ["rating", "max_retries"], 3))
    retry_sleep = float(get_nested(config, ["rating", "retry_sleep_seconds"], 2))

    answers_text = "\n".join(f"{i + 1}. {answer}" for i, answer in enumerate(job.answers))
    user_content = (
        f"Scoring dimension: {job.dimension['label']}\n"
        f"Scoring instruction:\n{job.dimension['prompt']}\n\n"
        f"Question/background:\n{job.question}\n\n"
        f"Answers:\n{answers_text}\n\n"
        f"Score format: {job.dimension['format']}\n"
        f"Return only a JSON array with exactly {len(job.answers)} items, in the same order as the answers."
    )
    payload = {
        "model": job.model,
        "messages": [
            {"role": "system", "content": global_prompt},
            {"role": "user", "content": user_content},
        ],
        "temperature": temperature,
    }

    last_error = ""
    for attempt in range(1, max_retries + 1):
        try:
            response = requests.post(chat_url, headers=headers, json=payload, timeout=timeout)
            if response.status_code == 429 and attempt < max_retries:
                time.sleep(retry_sleep * attempt)
                continue
            response.raise_for_status()
            result = response.json()
            content = result["choices"][0]["message"]["content"]
            scores = parse_scores(content, len(job.answers))
            return job, scores, any(score is not None for score in scores), ""
        except Exception as exc:
            last_error = str(exc)
            if attempt < max_retries:
                time.sleep(retry_sleep * attempt)
    return job, [None] * len(job.answers), False, last_error


def build_jobs(df: pd.DataFrame, config: dict[str, Any]) -> tuple[list[RatingJob], list[str]]:
    pd = ensure_pandas()
    input_cfg = config.get("input") or {}
    question_col = input_cfg.get("question_column", "question")
    answer_col = input_cfg.get("answer_column", "answer")
    group_by_question = bool(input_cfg.get("group_by_question", True))
    batch_size = int(get_nested(config, ["rating", "batch_size"], 5))

    if question_col not in df.columns:
        raise ValueError(f"Missing question column: {question_col}")
    if answer_col not in df.columns:
        raise ValueError(f"Missing answer column: {answer_col}")
    if batch_size < 1:
        raise ValueError("rating.batch_size must be >= 1")

    models = normalize_models(config)
    dimensions = normalize_dimensions(config)
    score_columns = [score_column_name(dim["name"], model) for model in models for dim in dimensions]

    jobs: list[RatingJob] = []
    if group_by_question:
        groups = df.groupby(question_col, dropna=False)
    else:
        groups = [("", df)]

    for question, group_df in groups:
        indexes = list(group_df.index)
        answers = ["" if pd.isna(value) else str(value) for value in group_df[answer_col].tolist()]
        question_text = "" if pd.isna(question) else str(question)
        for start in range(0, len(answers), batch_size):
            batch_answers = answers[start:start + batch_size]
            batch_indexes = indexes[start:start + batch_size]
            for model in models:
                for dimension in dimensions:
                    jobs.append(RatingJob(
                        model=model,
                        dimension=dimension,
                        question=question_text,
                        answers=batch_answers,
                        indexes=batch_indexes,
                        column=score_column_name(dimension["name"], model),
                    ))
    return jobs, score_columns


def rate_file(input_path: str, config_path: str, output_path: str) -> None:
    config = load_json(config_path)
    df = load_table(input_path)
    jobs, score_columns = build_jobs(df, config)
    for column in score_columns:
        df[column] = None

    headers = build_headers(config)
    chat_url = resolve_chat_url(config)
    max_workers = int(get_nested(config, ["parallel", "max_workers"], 4))
    max_workers = max(1, max_workers)

    print(f"Loaded {len(df)} rows. Submitting {len(jobs)} rating jobs with max_workers={max_workers}.")
    completed = 0
    failures = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(request_scores, job, config, headers, chat_url) for job in jobs]
        for future in concurrent.futures.as_completed(futures):
            job, scores, ok, error = future.result()
            for row_index, score in zip(job.indexes, scores):
                df.at[row_index, job.column] = score
            completed += 1
            if not ok:
                failures += 1
                print(f"WARN job failed: model={job.model}, dimension={job.dimension['name']}, error={error}")
            if completed == 1 or completed == len(jobs) or completed % 10 == 0:
                print(f"Progress: {completed}/{len(jobs)} jobs completed")

    save_table(df, output_path)
    print(f"Saved scored data to {output_path}. Failed jobs: {failures}/{len(jobs)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run parallel multi-model AI scoring on standardized rating data.")
    parser.add_argument("--input", required=True, help="Input .xlsx/.csv file with id/question/answer columns")
    parser.add_argument("--config", required=True, help="Rating config JSON")
    parser.add_argument("--output", required=True, help="Output .xlsx/.csv file")
    args = parser.parse_args()
    rate_file(args.input, args.config, args.output)


if __name__ == "__main__":
    main()
