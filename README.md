# Olist E-Commerce Analytics — End-to-End Microsoft Fabric Platform

An end-to-end data analytics platform built on **Microsoft Fabric**, covering the full journey from raw CSV files to interactive Power BI dashboards — using the **Medallion architecture** (Bronze → Silver → Gold), a governed semantic model, and an orchestrated, self-monitoring pipeline.

Built as a portfolio project to demonstrate practical data engineering and BI skills using a real, messy public dataset rather than a clean tutorial dataset.

---

## 🎯 Business Question

> How can revenue, customer satisfaction, and delivery performance be analyzed and optimized on the Olist e-commerce marketplace?

**Dataset:** [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — ~99,441 orders, 2016–2018, 9 relational CSV files (orders, items, payments, reviews, products, customers, sellers, geolocation).

---

## 🏗️ Architecture

```
CSV Files (Kaggle)
    │
    ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   BRONZE    │────▶│   SILVER    │────▶│    GOLD     │
│  Lakehouse  │     │  Lakehouse  │     │  Warehouse  │
│ (raw, as-is)│     │ (cleaned,   │     │ (star schema│
│             │     │  typed)     │     │ + business  │
│             │     │             │     │  logic)     │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                                │
                                                ▼
                                    ┌───────────────────────┐
                                    │  Semantic Model        │
                                    │  (Direct Lake, DAX)    │
                                    └───────────┬────────────┘
                                                │
                                                ▼
                                    ┌───────────────────────┐
                                    │  Power BI Dashboards   │
                                    │  Executive / Sales /   │
                                    │  Logistics / Customer  │
                                    └────────────────────────┘

    All orchestrated end-to-end by a Fabric Data Pipeline
    with data quality gating and failure alerting.
```

**Why Lakehouse for Bronze/Silver, Warehouse for Gold?** Spark/Lakehouse gives the flexibility needed for raw and semi-structured transformation work. The Gold layer, acting as the single source of truth for reporting, benefits from a SQL engine's stricter schema guarantees and native Power BI integration — so it moved to a Warehouse.

---

## 📦 Layer-by-Layer Breakdown

### Bronze — Raw Ingestion
- 9 CSV files loaded as-is into Delta tables via a PySpark notebook, preserving full lineage back to the source.
- **Data quality find:** `review_score` values were being silently misparsed as dates. Root cause: free-text review comments containing commas/line breaks shifted column alignment during CSV parsing. Fixed with explicit `multiLine`, `quote`, and `escape` options.

### Silver — Structural Cleaning
Cleaning limited to *structural* correctness only (types, keys, duplicates) — no business logic, kept deliberately reusable regardless of downstream analysis purpose.

- **Composite keys identified empirically, not assumed** — e.g. `order_items` is unique on `(order_id, order_item_id)`, not `order_id` alone; `reviews` required `(review_id, order_id)` after discovering a single review_id can map to multiple orders.
- **Geolocation deduplication** — the most involved data quality investigation in the project:
  1. Grouping by `(prefix, city, state)` still left duplicates per zip prefix
  2. Root cause 1: whitespace/case inconsistency → fixed with `trim()`/`lower()`
  3. Root cause 2: **accented character inconsistency** (`"ibiaça"` vs `"ibiaca"`) → fixed with `F.translate()` to strip diacritics
  4. Remaining ~555 cases were genuine typos or two distinct towns sharing a zip prefix → resolved with a **tie-breaker** (`Window` + `row_number()`, keeping the most frequent city/state pairing per prefix) — an intentional, documented simplification, not a "correct" answer
  5. Bonus finding: 304 city names exist in *multiple* Brazilian states (e.g. "agua boa" appears in 3 states) — confirming `(city, state)` must always be treated as a pair

### Gold — Star Schema with Business Logic
- Surrogate keys throughout (`ROW_NUMBER()`-generated), PascalCase naming convention, one fact table (`FactOrderItems`) at "sold item" grain.
- `DimDate` built in **PySpark**, not SQL — Fabric Warehouse (Synapse SQL) doesn't support recursive CTEs.
- **Payments modeling — three iterations before landing on the right grain:**
  1. Static PIVOT by payment type → missed a rare `not_defined` type, abandoned
  2. Separate `DimPaymentType` + `FactPayments` → abandoned due to grain mismatch (a payment applies to a whole order, but an order can span multiple sellers/products — no clean join possible)
  3. **Final:** aggregated to one row per order (`ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY payment_value DESC)` for dominant type, `SUM`/`COUNT` for totals), embedded as denormalized fields in the fact table
- **The row-count mystery:** `FactOrderItems` had 113,314 rows vs. an expected 112,650. Diagnosed by adding one join at a time and checking row counts after each — isolated the reviews join as the cause. A first estimate only explained 551 of the 664 extra rows; the remaining 113 came from a **multiplicative effect** (orders with both multiple items *and* multiple reviews). Fixed by aggregating reviews to one-per-order before joining, same pattern as payments.
- Business-logic fields kept in Gold, not Silver (a deliberate boundary): `IsDelivered`, `IsLateDelivery`, `StatusDateMismatch` (8 orders where status says "delivered" but the delivery date is missing — documented rather than silently corrected), `EstimateAccuracyBucket` (delivery-estimate accuracy analysis).

### Data Quality Checks
A consolidated SQL script covering referential integrity, key uniqueness, value plausibility, and cross-table consistency. Findings are explicitly split into **critical** ("should be 0") vs. **known, accepted** anomalies:

| Finding | Count | Explanation |
|---|---|---|
| Sellers without geo-coordinates | 134 / 3,095 | 7 zip prefixes missing from source geolocation data |
| Customers with implausible coordinates | 4 | Sign-flip error traced to Bronze raw data |
| Orders with payment/item value mismatch | 379 | 362 explained by installment interest (correlated with `max_installments`); 17 by multi-payment-type orders |

### Semantic Model
Direct Lake on SQL. Two real technical constraints surfaced and were worked around:
- **No DAX calculated columns in Direct Lake** — only measures. Fields like `DayOfMonth` had to be pushed back into the source layer (PySpark/Gold SQL) instead.
- **DAX filter context conflict** — a measure filtering `NOT ISBLANK(ReviewScore)` broke when `ReviewScore` was also the chart axis (identical bar heights across categories). Fixed using `KEEPFILTERS()` as a standalone top-level `CALCULATE` argument.

### Power BI Dashboards
Four pages, each answering distinct business questions with deliberate effort to avoid redundancy between pages:

- **Executive Summary** — 8 KPI cards, revenue trend (drill-to-day reveals a clear Black Friday spike on Nov 24, 2017)
- **Sales** — revenue/volume/price by category, seller location map (switched from state-code text to lat/long after Bing geocoding scattered points across continents), Top-N filtering consistently sorted by volume to avoid distortion from low-sample niche categories
- **Logistics** — delivery volume vs. on-time rate combo chart (reveals an inverse relationship: as volume grew 2016→2018, punctuality declined), delivery-estimate accuracy (Olist delivers ~12 days earlier than estimated on average)
- **Customer** — review score distribution, satisfaction trend, delivery-time-vs-satisfaction scatter, satisfaction-by-state map with conditional formatting calibrated to the real ~3.5–4.1 score range

### Automation Pipeline
```
Bronze Ingestion
    ├──▶ 4× Silver Notebooks (parallel)
    └──▶ Gold Date Dimension (parallel)
              │
              ▼
      Gold Dimensions (SQL Script)
              │
              ▼
      Gold Fact Table (SQL Script)
              │
              ▼
      Data Quality Checks ──[on failure]──▶ Email Alert
              │
              ▼
      Semantic Model Refresh
```
The Data Quality Checks step uses a `THROW` inside the SQL script when any critical check fails, converting a *content* problem into a real *pipeline* failure — which then triggers an email notification via the on-failure path, before anything reaches the reports.

---

## 🛠️ Tech Stack

Microsoft Fabric · Lakehouse · Data Warehouse · PySpark · T-SQL · Power BI (Direct Lake) · DAX · Data Pipelines

---

## 📁 Repo Structure

```
├── sql/                    Gold layer dimension & fact table scripts, data quality checks
├── notebooks/               Bronze ingestion, Silver cleaning notebooks
├── dax/                     Semantic model measures
├── docs/
│   ├── architecture.png
│   ├── pipeline.png
│   └── dashboards/           Screenshots of all 4 report pages
└── PROJECT_SUMMARY.pdf       Full write-up + interview Q&A
```

---

## 🔑 Key Takeaways

- Real-world data quality issues rarely have a single root cause — the geolocation duplicate problem required three separate, layered fixes before it was actually resolved.
- Row-count mismatches in fact tables are best diagnosed by adding joins incrementally, not guessing at the aggregate level.
- A fact table's grain should be decided by what can be joined cleanly, not by what seems intuitive — this is why a separate `FactPayments` table was designed, tested, and ultimately rejected.
- Not every anomaly is a bug. Documenting *and quantifying* accepted data gaps (missing geocodes, installment-interest discrepancies) is as important as fixing genuine defects.
