#!/usr/bin/env python3
"""合并重复测量，输出中位数、百分之九十五分位和变化比例；报告只写到指定位置。"""
import argparse
import json
import math
import statistics
from pathlib import Path


def load(paths):
    combined = {}
    for name in paths:
        path = Path(name)
        if path.is_dir():
            path = path / "results.json"
        for key, values in json.loads(path.read_text()).items():
            combined.setdefault(key, []).extend(values)
    return combined


def summary(values):
    ordered = sorted(values)
    return {
        "samples": len(values),
        "median": statistics.median(values),
        "p95": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)],
        "minimum": min(values),
        "maximum": max(values),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", nargs="+", required=True)
    parser.add_argument("--after", nargs="+", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    before, after = load(args.before), load(args.after)
    result = {}
    print("| 指标 | 优化前中位数 | 优化后中位数 | 变化 |")
    print("| --- | ---: | ---: | ---: |")
    for name in sorted(before.keys() & after.keys()):
        previous, current = summary(before[name]), summary(after[name])
        delta = ((current["median"] / previous["median"] - 1) * 100) if previous["median"] else None
        result[name] = {"before": previous, "after": current, "change_percent": delta}
        formatted = f"{delta:+.1f}%" if delta is not None else "—"
        print(f"| {name} | {previous['median']:.3f} | {current['median']:.3f} | {formatted} |")
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
