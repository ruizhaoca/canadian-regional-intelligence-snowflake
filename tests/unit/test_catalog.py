from regional_intelligence.catalog import DATASETS


def test_catalog_contains_the_two_mvp_tables() -> None:
    assert {dataset.table_id for dataset in DATASETS} == {
        "14-10-0461-01",
        "17-10-0148-01",
    }


def test_product_ids_are_eight_digits() -> None:
    assert {dataset.product_id for dataset in DATASETS} == {"14100461", "17100148"}

