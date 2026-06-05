# Customer Behavior Analysis — Olist Brazilian E-Commerce

End-to-end data analysis project following the **CRISP-DM** methodology.  
Built for a **Berlin tech portfolio** — demonstrates SQL, Python, feature engineering, RFM segmentation and business storytelling on a real-world dataset.

**Dataset:** [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (Kaggle) — 100K orders, 2016–2018.

---

## Stack

| Layer | Tools |
|-------|-------|
| Language | Python 3.10 |
| Storage | SQLite (via `sqlite3` + SQLAlchemy) |
| Analysis | Pandas 2.2 · NumPy 1.26 |
| Visualization | Matplotlib 3.9 · Seaborn 0.13 |
| ML | Scikit-learn 1.5 |
| Notebooks | Jupyter 7.2 |
| SQL | CTEs · Window Functions · Aggregations |

---

## Project Structure

```
├── data/                          # Raw CSVs + SQLite DB (not versioned)
├── sql/
│   ├── load_data.py               # Ingest CSVs → SQLite (9 tables)
│   ├── 02_data_preparation.sql    # 6-CTE master table query
│   └── 03_retention.sql           # 7-CTE retention + window functions
├── notebooks/
│   ├── 01_eda.ipynb               # Phase 2 — Data Understanding
│   ├── 02_data_prep.ipynb         # Phase 3 — Data Preparation
│   ├── 03_negative_reviews.ipynb  # Phase 4 — Negative Review Drivers
│   ├── 04_rfm_segmentation.ipynb  # Phase 4 — RFM Segmentation
│   └── 05_evaluation.ipynb        # Phase 5 — Evaluation & Recommendations
├── dashboard/                     # 23 exported charts (PNG)
├── requirements.txt
└── README.md
```

---

## Key Results

### Customer Segmentation (RFM)

93,337 unique customers segmented using Recency · Frequency · Monetary quintile scoring (1–5).

| Segment | Customers | % of base | Avg Recency | Avg Frequency | Avg Monetary |
|---------|----------:|----------:|------------:|--------------:|-------------:|
| **At Risk** | 22,233 | 24% | 395 days | 1.0 orders | R$144 |
| **Loyal** | 18,819 | 20% | 169 days | 1.0 orders | R$138 |
| **Lost** | 15,102 | 16% | 395 days | 1.0 orders | R$141 |
| **Champions** | 14,950 | 16% | 90 days | 1.1 orders | R$151 |
| **Others** | 14,807 | 16% | 154 days | 1.0 orders | R$136 |
| **New Customers** | 7,426 | 8% | 91 days | 1.0 orders | R$139 |

> **Insight:** `At Risk` is the largest segment (24%). These were active customers now dormant for ~13 months — the highest-ROI win-back opportunity without new customer acquisition costs.

---

### Top 3 Drivers of Negative Reviews

Negative review defined as `review_score ≤ 2` (13% of all reviews with score).  
Statistical evidence: Pearson correlation + Mann-Whitney U test.

| Rank | Feature | Pearson r with score | Finding |
|------|---------|---------------------:|---------|
| **#1** | `delivery_delay_days` | Strongest negative | Late orders generate **3× more** negative reviews than on-time orders (p < 0.001) |
| **#2** | `delivery_days` | Second negative | Total delivery time independently predicts satisfaction (Kruskal-Wallis significant) |
| **#3** | `freight_ratio` | Third negative | High freight-to-price ratio correlates with dissatisfaction regardless of delivery time |

> **Insight:** When a package arrives late vs. the promised date, negative review rate jumps from ~5% to ~15–16%. Communicating delays proactively would be the single highest-impact action.

---

### Customer Retention by Product Category

Retention = % of customers who made a second purchase (any category) after their first.  
Only categories with ≥ 50 first-time customers included. Global retention rate: **~5%**.

**Highest retention:**

| Rank | Category | Retention Rate | Customers |
|------|----------|---------------:|----------:|
| 1 | `home_appliances` | **9.0%** | 677 |
| 2 | `fashion_male_clothing` | 6.0% | 100 |
| 3 | `furniture_bedroom` | 5.95% | 84 |

**Lowest retention** (< 2%) — categories with one-off purchase behavior: `agro_industry_and_commerce`, `fashio_female_clothing`, `home_comfort_2`.

> **Insight:** Retention varies ~4.5× across categories. Loyalty strategies should be category-specific: `home_appliances` buyers are 2× more likely to return than average.

---

## CRISP-DM Phases

### Phase 1 — Business Understanding

**Goal:** Understand customer purchasing behavior to identify:
1. Which customer segments generate the most revenue?
2. What factors drive low review scores?
3. How does delivery performance affect repeat purchases?

---

### Phase 2 — Data Understanding · `notebooks/01_eda.ipynb`

Exploratory analysis of all 9 Olist tables (99,441 orders, 2016–2018).

| Dimension | Finding |
|-----------|---------|
| **Period** | Sep 2016 → Oct 2018 (2.1 years, 772 days) |
| **Volume** | 99K orders · 112K items · 99K reviews |
| **Data quality** | `review_comment_title`: 88% null · `geolocation`: 261K duplicates |
| **Review score** | Bimodal distribution — peaks at 1 and 5 (typical e-commerce pattern) |
| **Payment value** | Strong right skew — median R$86.50, max R$13,440 |
| **Order status** | 96%+ delivered, <1% cancelled |
| **Trend** | Sustained growth; peak Nov 2017 (Brazilian Black Friday) |

---

### Phase 3 — Data Preparation · `notebooks/02_data_prep.ipynb`

Produces `data/olist_master.csv`: **96,457 rows × 18 columns**.

**Key decisions:**
- Filter `delivered` orders only — only these have a real delivery date to calculate delay
- Remove `delivery_days ≤ 0` — 139 corrupt records (delivery before purchase)
- Deduplicate reviews by `review_answer_timestamp` (keep latest)
- Left join reviews — missing = no review filed, not satisfaction neutral
- Translate product categories PT → EN; fill unmapped as `unknown`

**Engineered features:**

| Feature | Formula | Business meaning |
|---------|---------|-----------------|
| `delivery_delay_days` | delivered_date − estimated_date | Positive = late, Negative = early |
| `delivery_days` | delivered_date − purchase_date | Total wait time perceived by customer |
| `is_negative_review` | score ≤ 2 → 1, else 0 | Binary target for classification |
| `freight_ratio` | freight_total / price_total | Logistics cost as share of order value |
| `order_month` | YYYY-MM period | Captures seasonality |
| `order_weekday` | 0=Monday … 6=Sunday | Day-of-week purchase pattern |
| `order_hour` | 0–23 | Time-of-day purchase pattern |

---

### Phase 4a — Negative Review Drivers · `notebooks/03_negative_reviews.ipynb`

Statistical analysis of what predicts a `review_score ≤ 2`.

**Method:** Pearson correlation, Mann-Whitney U, Kruskal-Wallis H, violin/box plots.

**Multicollinearity note:** `delivery_delay_days` and `delivery_days` are highly correlated (r ≈ 0.7). Use only `delivery_delay_days` as the primary predictor in any downstream model.

---

### Phase 4b — RFM Segmentation · `notebooks/04_rfm_segmentation.ipynb`

RFM quintile scoring on `customer_unique_id` (stable cross-order identifier).

- **Snapshot date:** 2018-10-18 (day after last order in dataset)
- **Scoring:** `pd.qcut` into quintiles 1–5; R inverted (lower recency = higher score)
- **Segment rules:** based on R_score and F_score thresholds

Produces `data/olist_rfm.csv` (93,337 rows) and `data/rfm_segments.csv`.

**Segment actions:**

| Segment | Priority | Recommended action |
|---------|----------|-------------------|
| Champions | Retain | VIP program, early access, referral campaigns |
| Loyal | Grow | Upsell to premium categories, volume discounts |
| New Customers | Convert | 2nd-purchase discount email, personalized recs |
| At Risk | Reactivate | Time-limited win-back coupon, urgency messaging |
| Lost | Low investment | Low-cost reactivation email or CRM removal |

---

### Phase 5 — Evaluation · `notebooks/05_evaluation.ipynb`

Consolidates all findings. Validates RFM coherence (4/4 consistency checks pass),  
cross-references RFM segments with satisfaction data, and produces a 4-panel executive dashboard.

**Cross-segment satisfaction finding:** Satisfaction metrics are broadly consistent across segments — the delivery delay effect dominates over segment membership, suggesting the supply chain improvement has higher priority than CRM alone.

---

### Phase 6 — Deployment

- 23 charts exported to `dashboard/` (PNG, 2.5 MB total)
- `sql/02_data_preparation.sql` — reproducible master table in pure SQL
- `sql/03_retention.sql` — retention analysis with `ROW_NUMBER`, `RANK`, `NTILE` window functions
- All notebooks executed with full cell outputs committed

---

## Setup

### Requirements

- Python 3.10+
- ~500 MB disk space for the SQLite DB and outputs

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/LuciaPardo/olist-customer-analysis.git
cd olist-customer-analysis

# 2. Create and activate virtual environment
python -m venv .venv

# Windows
.venv\Scripts\activate
# macOS / Linux
source .venv/bin/activate

# 3. Install dependencies
pip install -r requirements.txt
```

### Data

Download the dataset from Kaggle and place all CSV files in `data/`:

```
kaggle datasets download -d olistbr/brazilian-ecommerce
unzip brazilian-ecommerce.zip -d data/
```

Or download manually from:  
[https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)

| File | Rows | Description |
|------|-----:|-------------|
| `olist_orders_dataset.csv` | 99,441 | Order headers and status |
| `olist_order_items_dataset.csv` | 112,650 | Line items per order |
| `olist_order_payments_dataset.csv` | 103,886 | Payment details and installments |
| `olist_order_reviews_dataset.csv` | 99,224 | Customer reviews (score + text) |
| `olist_customers_dataset.csv` | 99,441 | Customer master with ZIP and state |
| `olist_products_dataset.csv` | 32,951 | Product catalog with dimensions |
| `olist_sellers_dataset.csv` | 3,095 | Seller master |
| `olist_geolocation_dataset.csv` | 1,000,163 | ZIP-code geolocation coordinates |
| `product_category_name_translation.csv` | 71 | Category names PT → EN |

> `data/` is excluded from version control (`.gitignore`). Run the steps below to regenerate all outputs.

### Running the project

```bash
# 4. Load CSVs into SQLite (creates data/olist.db)
python sql/load_data.py

# 5. Launch Jupyter and run notebooks in order
jupyter notebook notebooks/
```

Run notebooks in this order:
1. `01_eda.ipynb` → exploratory analysis
2. `02_data_prep.ipynb` → generates `data/olist_master.csv`
3. `03_negative_reviews.ipynb` → review driver analysis
4. `04_rfm_segmentation.ipynb` → generates `data/olist_rfm.csv`
5. `05_evaluation.ipynb` → consolidated evaluation + executive dashboard

---

## Repository Contents

| Path | Description |
|------|-------------|
| `sql/load_data.py` | Reads 9 CSVs into SQLite with progress output |
| `sql/02_data_preparation.sql` | 6-CTE query: delivered orders → master table with delay features |
| `sql/03_retention.sql` | 7-CTE query: retention by category using `ROW_NUMBER`, `RANK`, `NTILE(4)` |
| `notebooks/01_eda.ipynb` | Schema review, null/duplicate audit, distributions, correlations, time series |
| `notebooks/02_data_prep.ipynb` | Merge pipeline, feature engineering, integrity checks, CSV export |
| `notebooks/03_negative_reviews.ipynb` | Correlation analysis, statistical tests, driver ranking, category breakdown |
| `notebooks/04_rfm_segmentation.ipynb` | Quintile scoring, segment assignment, scatter/violin/heatmap visuals |
| `notebooks/05_evaluation.ipynb` | Segment validation, cross-analysis, executive dashboard, recommendations |
| `dashboard/` | 23 PNG charts covering all analysis phases |

---

## Author

**Lucia Pardo** · Data Analyst  
Portfolio project · Berlin, 2026
