# Customer Behavior Analysis — Olist Brazilian E-Commerce

End-to-end data analysis project following the **CRISP-DM** methodology, built for a Berlin tech portfolio.  
Dataset: [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (Kaggle).

## Stack
Python 3.10 · SQLite · Pandas · NumPy · Seaborn · Matplotlib · Scikit-learn · Jupyter

---

## Project Structure

```
├── data/               # Raw CSVs (not versioned) + olist.db (SQLite)
├── sql/
│   └── load_data.py    # Load CSVs into SQLite
├── notebooks/          # Jupyter notebooks per CRISP-DM phase
├── dashboard/          # Static charts / dashboard exports
├── requirements.txt
└── README.md
```

---

## CRISP-DM Phases

### 1. Business Understanding
- **Goal**: Understand customer purchasing behavior to identify high-value segments, churn risk, and satisfaction drivers.
- **Key questions**:
  - Which customer segments generate the most revenue?
  - What factors drive low review scores?
  - How does delivery performance affect repeat purchases?

### 2. Data Understanding
- Notebook: `notebooks/01_data_understanding.ipynb`
- Explore schema, row counts, nulls, distributions, and key relationships across the 9 Olist tables.

### 3. Data Preparation
- Notebook: `notebooks/02_data_preparation.ipynb`
- Merge tables, handle missing values, engineer features (delivery delay, RFM scores, etc.).

### 4. Modeling
- Notebook: `notebooks/03_modeling.ipynb`
- Customer segmentation (KMeans RFM), churn prediction (logistic regression / random forest), review score prediction.

### 5. Evaluation
- Notebook: `notebooks/04_evaluation.ipynb`
- Metrics, confusion matrices, feature importance, business interpretation of results.

### 6. Deployment
- `dashboard/` — exportable charts and summary visuals suitable for portfolio presentation.

---

## Setup

```bash
# 1. Create virtual environment
python -m venv .venv
.venv\Scripts\activate        # Windows
# source .venv/bin/activate   # macOS/Linux

# 2. Install dependencies
pip install -r requirements.txt

# 3. Place Olist CSVs in data/

# 4. Load data into SQLite
python sql/load_data.py
```

---

## Data

Download the dataset from Kaggle and place all CSV files in `data/`:

| File | Description |
|------|-------------|
| `olist_orders_dataset.csv` | Orders header |
| `olist_order_items_dataset.csv` | Line items per order |
| `olist_order_payments_dataset.csv` | Payment details |
| `olist_order_reviews_dataset.csv` | Customer reviews |
| `olist_customers_dataset.csv` | Customer master |
| `olist_products_dataset.csv` | Product catalog |
| `olist_sellers_dataset.csv` | Seller master |
| `olist_geolocation_dataset.csv` | ZIP-code geolocation |
| `product_category_name_translation.csv` | Category PT→EN |

> The `data/` directory is excluded from version control.
