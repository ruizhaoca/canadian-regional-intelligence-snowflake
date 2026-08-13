"""Command-line entry point for scheduled acquisition."""

from __future__ import annotations

import argparse
import json
import logging
import tempfile
from pathlib import Path

from regional_intelligence.catalog import DATASETS
from regional_intelligence.config import Settings
from regional_intelligence.pipeline import acquire_dataset
from regional_intelligence.statscan import StatsCanClient
from regional_intelligence.storage import (
    AzureDataLakeLandingStore,
    LandingStore,
    LocalLandingStore,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--table-id",
        action="append",
        choices=[dataset.table_id for dataset in DATASETS],
        help="Acquire only this table; repeat to select multiple tables.",
    )
    parser.add_argument(
        "--local-output",
        type=Path,
        help="Use a local landing root instead of ADLS (development only).",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    selected = [
        dataset
        for dataset in DATASETS
        if not args.table_id or dataset.table_id in args.table_id
    ]

    store: LandingStore
    if args.local_output:
        store = LocalLandingStore(args.local_output)
        prefix = "statcan"
    else:
        settings = Settings()  # type: ignore[call-arg]
        store = AzureDataLakeLandingStore(
            str(settings.azure_storage_account_url), settings.azure_storage_file_system
        )
        prefix = settings.azure_storage_prefix

    with (
        tempfile.TemporaryDirectory(prefix="regional-intelligence-") as temp_dir,
        StatsCanClient() as client,
    ):
        for dataset in selected:
            result = acquire_dataset(
                dataset,
                client=client,
                store=store,
                work_dir=Path(temp_dir),
                prefix=prefix,
            )
            logging.info(json.dumps(result.model_dump(), sort_keys=True))
    return 0
