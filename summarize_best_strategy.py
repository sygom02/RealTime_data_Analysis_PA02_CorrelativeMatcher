#!/usr/bin/env python3
"""Summarize benchmark outputs and choose the best current strategy."""

import argparse
import math
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


Record = Dict[str, object]


def parse_value(value: str) -> object:
    try:
        if value.lower() in {"nan", "inf", "-inf"}:
            return float(value)
        if "." in value or "e" in value.lower():
            return float(value)
        return int(value)
    except ValueError:
        return value


def parse_line(line: str, source: str) -> Optional[Record]:
    line = line.strip()
    if not line:
        return None
    labels: List[str] = []
    data: Record = {"source": source, "raw": line}
    for token in line.split():
        if "=" in token:
            key, value = token.split("=", 1)
            data[key] = parse_value(value)
        else:
            labels.append(token)
    if not labels and "benchmark" not in data:
        return None
    data["labels"] = labels
    data["prefix"] = labels[0] if labels else ""
    data["variant"] = infer_variant(labels, data)
    return data


def infer_variant(labels: List[str], data: Record) -> str:
    prefix = labels[0] if labels else ""
    if prefix in {
        "gpu_breakdown",
        "gpu_scaling",
        "matcher",
        "matcher_cuda_build",
        "score_all",
        "pruning",
        "correctness",
    } and len(labels) > 1:
        return labels[1]
    if labels:
        return labels[0]
    return str(data.get("benchmark", "unknown"))


def read_records(path: Path) -> List[Record]:
    if not path.exists():
        return []
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16", errors="replace")
    elif raw[:200].count(b"\x00") > 20:
        text = raw.decode("utf-16", errors="replace")
    else:
        text = raw.decode("utf-8", errors="replace")
    records: List[Record] = []
    for line in text.splitlines():
        record = parse_line(line, path.name)
        if record is not None:
            records.append(record)
    return records


def number(record: Record, key: str) -> Optional[float]:
    value = record.get(key)
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def correctness_map(records: Iterable[Record]) -> Dict[str, bool]:
    result: Dict[str, bool] = {}
    for record in records:
        if record.get("benchmark") != "correctness":
            continue
        variant = str(record["variant"])
        top1 = number(record, "top1_same")
        overlap = number(record, "topK_overlap")
        result[variant] = top1 == 1 and overlap is not None and overlap >= 0.999
    return result


def is_correct(variant: str, checks: Dict[str, bool]) -> bool:
    return checks.get(variant, True)


def best_by(records: Iterable[Record], key: str,
            checks: Dict[str, bool]) -> Optional[Record]:
    candidates = [
        record
        for record in records
        if number(record, key) is not None and is_correct(str(record["variant"]), checks)
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda record: float(number(record, key)))


def find_record(records: Iterable[Record], variant: str,
                prefix: Optional[str] = None) -> Optional[Record]:
    for record in records:
        if str(record.get("variant")) != variant:
            continue
        if prefix is not None and record.get("prefix") != prefix:
            continue
        return record
    return None


def pct_improvement(old: Optional[float], new: Optional[float]) -> Optional[float]:
    if old is None or new is None or old == 0:
        return None
    return (old - new) / old * 100.0


def fmt(value: Optional[float], digits: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def variant_table(records: Iterable[Record], keys: List[str]) -> List[str]:
    rows = []
    header = "| variant | " + " | ".join(keys) + " |"
    sep = "| --- | " + " | ".join(["---:"] * len(keys)) + " |"
    rows.extend([header, sep])
    for record in records:
        values = [fmt(number(record, key)) for key in keys]
        rows.append(f"| {record['variant']} | " + " | ".join(values) + " |")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", required=True)
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    pipeline = read_records(results_dir / "pipeline_score_summary.txt")
    pipeline += read_records(results_dir / "confirm_summary.txt")
    score = read_records(results_dir / "score_scaling_pruning_summary.txt")
    gpu = read_records(results_dir / "gpu_breakdown_scaling_summary.txt")
    gpu += read_records(results_dir / "gpu_improvement_summary.txt")
    gpu += read_records(results_dir / "gpu_grid_compare_summary.txt")
    gpu += read_records(results_dir / "confirm_summary.txt")
    correctness = read_records(results_dir / "correctness_summary.txt")

    checks = correctness_map(correctness + pipeline + score + gpu)

    cpu_matchers = [
        record
        for record in pipeline
        if record.get("benchmark") == "matcher"
        and not str(record["variant"]).startswith("gpu_")
    ]
    gpu_matchers = [
        record
        for record in gpu
        if record.get("benchmark") == "matcher"
        and str(record["variant"]).startswith("gpu_")
    ]
    gpu_breakdown = [
        record for record in gpu if record.get("prefix") == "gpu_breakdown"
    ]
    pruning = [record for record in score + gpu if record.get("prefix") == "pruning"]

    best_cpu = best_by(cpu_matchers, "match_total_ms", checks)
    best_gpu = best_by(gpu_matchers, "match_total_ms", checks)
    best_gpu_score = best_by(gpu_breakdown, "score_all_profile_ms", checks)

    reuse_buffer = find_record(gpu_breakdown, "gpu_reuse_buffer", "gpu_breakdown")
    reuse_block = find_record(gpu_breakdown, "gpu_reuse_block", "gpu_breakdown")
    cached_grid = find_record(
        gpu_breakdown, "gpu_reuse_block_cached_grid", "gpu_breakdown"
    )

    lines: List[str] = []
    lines.append("# Best Strategy Summary")
    lines.append("")
    lines.append(f"Results directory: `{results_dir}`")
    lines.append("")

    lines.append("## CPU Strategy")
    lines.append("")
    if cpu_matchers:
        lines.extend(
            variant_table(
                cpu_matchers,
                [
                    "match_total_ms",
                    "score_total_ms",
                    "score_grouping_ms",
                    "score_vector_alloc_count",
                    "score_all_only_ms",
                ],
            )
        )
        lines.append("")
    if best_cpu:
        lines.append(
            f"- Best CPU variant: `{best_cpu['variant']}` "
            f"(`match_total_ms={fmt(number(best_cpu, 'match_total_ms'))}` ms)."
        )
    else:
        lines.append("- CPU matcher result was not found.")
    lines.append("")

    lines.append("## GPU Strategy")
    lines.append("")
    if gpu_matchers:
        lines.extend(
            variant_table(
                gpu_matchers,
                [
                    "match_total_ms",
                    "score_total_ms",
                    "score_all_only_ms",
                    "score_all_call_count",
                ],
            )
        )
        lines.append("")
    if gpu_breakdown:
        lines.extend(
            variant_table(
                gpu_breakdown,
                [
                    "score_all_profile_ms",
                    "device_alloc_ms",
                    "h2d_grid_ms",
                    "h2d_scan_ms",
                    "h2d_cand_ms",
                    "h2d_total_ms",
                    "kernel_ms",
                    "d2h_score_ms",
                ],
            )
        )
        lines.append("")
    if best_gpu:
        lines.append(
            f"- Best GPU matcher variant: `{best_gpu['variant']}` "
            f"(`match_total_ms={fmt(number(best_gpu, 'match_total_ms'))}` ms)."
        )
    if best_gpu_score:
        lines.append(
            f"- Best standalone GPU score_all variant: `{best_gpu_score['variant']}` "
            f"(`score_all_profile_ms={fmt(number(best_gpu_score, 'score_all_profile_ms'))}` ms)."
        )
    lines.append("")

    lines.append("## Cause Checks")
    lines.append("")
    if reuse_buffer and reuse_block:
        kernel_delta = pct_improvement(
            number(reuse_buffer, "kernel_ms"), number(reuse_block, "kernel_ms")
        )
        matcher_delta = None
        rb_match = find_record(gpu_matchers, "gpu_reuse_buffer")
        block_match = find_record(gpu_matchers, "gpu_reuse_block")
        if rb_match and block_match:
            matcher_delta = pct_improvement(
                number(rb_match, "match_total_ms"),
                number(block_match, "match_total_ms"),
            )
        lines.append(
            f"- `gpu_reuse_block` kernel change vs `gpu_reuse_buffer`: "
            f"`kernel_ms` improvement={fmt(kernel_delta, 2)}%."
        )
        if matcher_delta is not None:
            lines.append(
                f"- Matcher-level improvement of `gpu_reuse_block` vs "
                f"`gpu_reuse_buffer`: {fmt(matcher_delta, 2)}%."
            )
    if reuse_block and cached_grid:
        h2d_delta = pct_improvement(
            number(reuse_block, "h2d_total_ms"), number(cached_grid, "h2d_total_ms")
        )
        grid_delta = pct_improvement(
            number(reuse_block, "h2d_grid_ms"), number(cached_grid, "h2d_grid_ms")
        )
        lines.append(
            f"- `gpu_reuse_block_cached_grid` transfer change vs "
            f"`gpu_reuse_block`: `h2d_total_ms` improvement={fmt(h2d_delta, 2)}%, "
            f"`h2d_grid_ms` improvement={fmt(grid_delta, 2)}%."
        )
    if pruning:
        best_prune = max(
            pruning,
            key=lambda record: number(record, "pruned_ratio") or -1.0,
        )
        lines.append(
            f"- Highest pruning ratio observed: `{best_prune['variant']}` "
            f"`pruned_ratio={fmt(number(best_prune, 'pruned_ratio'), 4)}`."
        )
    lines.append("")

    lines.append("## Current Recommendation")
    lines.append("")
    cpu_time = number(best_cpu, "match_total_ms") if best_cpu else None
    gpu_time = number(best_gpu, "match_total_ms") if best_gpu else None
    if cpu_time is not None and gpu_time is not None:
        if cpu_time <= gpu_time:
            lines.append(
                f"- Final runtime strategy for this workload: CPU `{best_cpu['variant']}`."
            )
            lines.append(
                "- GPU variants remain useful for root-cause analysis and large workload "
                "scaling, but they are not the final runtime choice unless Jetson BAG "
                "results reverse this ordering."
            )
        else:
            lines.append(
                f"- Final runtime strategy for this workload: GPU `{best_gpu['variant']}`."
            )
    elif best_cpu:
        lines.append(f"- Current best available strategy: CPU `{best_cpu['variant']}`.")
    elif best_gpu:
        lines.append(f"- Current best available strategy: GPU `{best_gpu['variant']}`.")
    else:
        lines.append("- Not enough matcher data to choose a final strategy.")

    if best_gpu:
        call_count = number(best_gpu, "score_all_call_count")
        if call_count is not None and call_count > 1:
            lines.append(
                f"- Next GPU optimization target: batching, because "
                f"`score_all_call_count={fmt(call_count, 0)}` still means many small "
                "GPU calls."
            )
    lines.append("")
    lines.append("## Correctness Gate")
    lines.append("")
    if checks:
        for variant, ok in sorted(checks.items()):
            lines.append(f"- `{variant}`: {'PASS' if ok else 'FAIL'}")
    else:
        lines.append("- Correctness records were not found in this result directory.")
    lines.append("")

    output = results_dir / "best_strategy_summary.md"
    output.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
