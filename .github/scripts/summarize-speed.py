#!/usr/bin/env python3

"""Summarize repeated LibreSSL `openssl speed -mr` results."""

from __future__ import annotations

import argparse
import glob
import statistics
from collections import defaultdict
from pathlib import Path


Measurements = dict[str, list[float]]
Units = dict[str, str]


def add_measurement(
    measurements: Measurements,
    units: Units,
    name: str,
    value: float,
    unit: str,
) -> None:
    measurements[name].append(value)
    units[name] = unit


def parse_file(path: str, measurements: Measurements, units: Units) -> None:
    block_sizes: list[str] = []

    for line in Path(path).read_text(encoding="utf-8").splitlines():
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
                add_measurement(
                    measurements,
                    units,
                    f"{algorithm} ({size} bytes)",
                    float(value),
                    "bytes/s",
                )
        elif line.startswith("+F4:"):
            bits = fields[2]
            add_measurement(
                measurements,
                units,
                f"ecdsa-{bits} sign",
                1.0 / float(fields[3]),
                "op/s",
            )
            add_measurement(
                measurements,
                units,
                f"ecdsa-{bits} verify",
                1.0 / float(fields[4]),
                "op/s",
            )
        elif line.startswith("+F6:"):
            bits = fields[1]
            add_measurement(
                measurements, units, f"mlkem-{bits} keygen", float(fields[3]), "op/s"
            )
            add_measurement(
                measurements, units, f"mlkem-{bits} encap", float(fields[5]), "op/s"
            )
            add_measurement(
                measurements, units, f"mlkem-{bits} decap", float(fields[7]), "op/s"
            )


def load(pattern: str) -> tuple[Measurements, Units, int]:
    paths = sorted(glob.glob(pattern))
    if not paths:
        raise ValueError(f"no files matched {pattern!r}")

    measurements: Measurements = defaultdict(list)
    units: Units = {}
    for path in paths:
        parse_file(path, measurements, units)

    for name, values in measurements.items():
        if len(values) != len(paths):
            raise ValueError(
                f"{name!r} has {len(values)} measurements, expected {len(paths)}"
            )
    return measurements, units, len(paths)


def format_value(value: float, unit: str) -> str:
    if unit == "bytes/s":
        if value >= 1_000_000_000:
            return f"{value / 1_000_000_000:.2f} GB/s"
        if value >= 1_000_000:
            return f"{value / 1_000_000:.2f} MB/s"
        return f"{value / 1_000:.2f} kB/s"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M op/s"
    if value >= 1_000:
        return f"{value / 1_000:.2f}k op/s"
    return f"{value:.2f} op/s"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="glob for speed result files")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    measurements, units, repetitions = load(args.input)
    output = [
        "## Daily performance report",
        "",
        f"Median of {repetitions} runs. Higher is better.",
        "",
        "| Benchmark | Median | Observed range |",
        "|---|---:|---:|",
    ]

    for name, values in measurements.items():
        median = statistics.median(values)
        spread = (max(values) - min(values)) / median * 100.0
        output.append(
            f"| {name} | {format_value(median, units[name])} | {spread:.2f}% |"
        )

    output.extend(
        [
            "",
            "The range is `(maximum - minimum) / median` for this run.",
            "Compare absolute values only between runs with equivalent CPU models.",
            "",
        ]
    )
    args.output.write_text("\n".join(output), encoding="utf-8")


if __name__ == "__main__":
    main()
