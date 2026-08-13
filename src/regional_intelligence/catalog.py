"""Authoritative Statistics Canada dataset catalog for the MVP."""

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Dataset:
    table_id: str
    title: str
    subject: str

    @property
    def product_id(self) -> str:
        """Return the eight-digit WDS PID from a ten-digit display table ID."""
        return self.table_id.replace("-", "")[:8]


DATASETS: tuple[Dataset, ...] = (
    Dataset(
        table_id="14-10-0461-01",
        title="Labour force characteristics by census metropolitan area, annual",
        subject="labour_market",
    ),
    Dataset(
        table_id="17-10-0148-01",
        title=(
            "Population estimates, July 1, by census metropolitan area and "
            "census agglomeration, 2021 boundaries"
        ),
        subject="population",
    ),
)

