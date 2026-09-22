"""
Load Olist CSV files from data/ into a SQLite database (data/olist.db).
Run from the project root: python sql/load_data.py
"""

import sqlite3
import pandas as pd
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
DB_PATH = DATA_DIR / "olist.db"

CSV_TABLE_MAP = {
    "olist_orders_dataset.csv": "orders",
    "olist_order_items_dataset.csv": "order_items",
    "olist_order_payments_dataset.csv": "order_payments",
    "olist_order_reviews_dataset.csv": "order_reviews",
    "olist_customers_dataset.csv": "customers",
    "olist_products_dataset.csv": "products",
    "olist_sellers_dataset.csv": "sellers",
    "olist_geolocation_dataset.csv": "geolocation",
    "product_category_name_translation.csv": "category_translation",
}


def load_csvs_to_sqlite():
    conn = sqlite3.connect(DB_PATH)
    loaded = []
    skipped = []

    for filename, table_name in CSV_TABLE_MAP.items():
        csv_path = DATA_DIR / filename
        if not csv_path.exists():
            skipped.append(filename)
            continue

        df = pd.read_csv(csv_path)
        df.to_sql(table_name, conn, if_exists="replace", index=False)
        print(f"  {filename} -> '{table_name}' ({len(df):,} rows)")
        loaded.append(table_name)

    conn.close()

    print(f"\nLoaded {len(loaded)} tables into {DB_PATH}")
    if skipped:
        print(f"Skipped (not found): {', '.join(skipped)}")


if __name__ == "__main__":
    load_csvs_to_sqlite()
