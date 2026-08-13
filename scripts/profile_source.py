"""Profile selected categorical fields in a Statistics Canada CSV using stdlib only."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--column", action="append", required=True)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--include-dguid-types", action="store_true")
    args = parser.parse_args()

    counts = {column: Counter[str]() for column in args.column}
    dguid_types: Counter[str] = Counter()
    with args.csv_path.open("r", encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            for column in args.column:
                counts[column][row[column]] += 1
            if args.include_dguid_types:
                dguid_types[row["DGUID"][4:9]] += 1

    output = {
        column: counter.most_common(args.limit) for column, counter in counts.items()
    }
    if args.include_dguid_types:
        output["DGUID_TYPE"] = dguid_types.most_common(args.limit)
    print(json.dumps(output, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
