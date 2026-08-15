#!/usr/bin/env python3

"""Compare repeated LibreSSL `openssl speed -mr` results."""

from __future__ import annotations

import argparse
import glob
import statistics
from collections import defaultdict
from pathlib import Path


Measurements = dict[str, list[float]]


def parse_file(path: str, measurements: Measurements) -> None:
    block_sizes: list[str] = []
    lines = Path(path).read_text(encoding="utf-8").splitlines()

    for line in lines:
        fields = line.split(":")

        if line.startswith("+H:"):
            block_sizes = fields[1:]
        elif line.startswith("+F:"):
            if not block_sizes:
                raise ValueError(f"{path}: +F appeared before +H")
            algorithm = fields[2]
            values = fields[3:]
            if len(values) != len(block_sizes):
                raise ValueError(f"{path}: unexpected +F field count: {line}")
            for size, value in zip(block_sizes, values, strict=True):
                measurements[f"{algorithm} ({size} bytes)"].append(float(value))
        elif line.startswith("+F4:"):
            bits = fields[2]
            measurements[f"ecdsa-{bits} sign"].append(1.0 / float(fields[3]))
            measurements[f"ecdsa-{bits} verify"].append(1.0 / float(fields[4]))
        elif line.startswith("+F6:"):
            bits = fields[1]
            measurements[f"mlkem-{bits} keygen"].append(float(fields[3]))
            measurements[f"mlkem-{bits} encap"].append(float(fields[5]))
            measurements[f"mlkem-{bits} decap"].append(float(fields[7]))


def load(pattern: str) -> Measurements:
    paths = sorted(glob.glob(pattern))
    if not paths:
        raise ValueError(f"no files matched {pattern!r}")

    measurements: Measurements = defaultdict(list)
    for path in paths:
        parse_file(path, measurements)
    return measurements


def format_rate(value: float) -> str:
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f} GB/s"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f} MB/s"
    if value >= 1_000:
        return f"{value / 1_000:.2f}k op/s"
    return f"{value:.2f} op/s"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="glob for base results")
    parser.add_argument("--head", required=True, help="glob for head results")
    parser.add_argument("--warning-threshold", type=float, default=10.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    base = load(args.base)
    head = load(args.head)
    if base.keys() != head.keys():
        missing_from_head = sorted(base.keys() - head.keys())
        missing_from_base = sorted(head.keys() - base.keys())
        raise ValueError(
            f"benchmark sets differ; missing from head={missing_from_head}, "
            f"missing from base={missing_from_base}"
        )

    output = [
        "## Performance comparison",
        "",
        "Values are medians of repeated runs on the same runner. Higher is better.",
        "",
        "| Benchmark | Base | Head | Change |",
        "|---|---:|---:|---:|",
    ]
    warnings = 0

    for name in base:
        base_median = statistics.median(base[name])
        head_median = statistics.median(head[name])
        change = (head_median / base_median - 1.0) * 100.0
        marker = ""
        if change <= -args.warning_threshold:
            marker = " ⚠️"
            warnings += 1
        output.append(
            f"| {name} | {format_rate(base_median)} | "
            f"{format_rate(head_median)} | {change:+.2f}%{marker} |"
        )

    output.extend(
        [
            "",
            f"Warning threshold: -{args.warning_threshold:g}%.",
            f"Potential regressions: {warnings}.",
            "This workflow reports results but does not fail on a regression.",
            "",
        ]
    )
    args.output.write_text("\n".join(output), encoding="utf-8")


if __name__ == "__main__":
    main()
