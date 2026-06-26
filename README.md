## Retail Supply Chain Inventory and Demand Intelligence

An end-to-end supply chain analytics project on the DataCo Smart Supply Chain
dataset: a PostgreSQL data model, analytical SQL over orders and shipments,
demand forecasting in Python, and inventory policy derived from the forecast.

## Overview

Starting from a single wide 53-column transactional export, the project builds a
clean analytical model, answers operational questions with SQL (where revenue
concentrates, where deliveries run late, how variable lead times are, how demand
trends), forecasts demand per product, and converts those forecasts into
inventory decisions (safety stock, reorder point, order quantity).

## Data

DataCo Smart Supply Chain dataset (publicly available, 53 columns of order,
shipment, product, and customer fields). Paste the exact source link here.

The raw export is not committed. Download it from the source above and point the
scripts at your local copy. Keeping large raw data out of the repo is deliberate.

## Repository structure

    sql/            schema build plus the analytical queries
    forecasting/    demand forecasting and inventory policy notebook or script
    README.md       this file

## 1. Data model

A staging table ingests the raw 53-column file. From it the project builds a
normalized star schema in PostgreSQL:

- a product dimension (product identity and category attributes)
- an orders fact table (one row per order, with dates, shipping mode, status)
- an order-items fact table (one row per line item, with quantity, price, sales)

This separates the grain of orders from line items and removes the repetition of
the flat file, so the analytical queries stay clean.

## 2. SQL analytics

The analytical queries use CTEs and window functions:

- ABC revenue classification of products by cumulative revenue share
- late-delivery rate broken down by shipping mode and region
- lead-time variability (spread of actual delivery time against scheduled)
- month-over-month demand growth using LAG over an ordered window
- demand trend and volume ranking across the product range

Headline findings (confirm each against your own query output before committing):

- revenue is highly concentrated: roughly 7 products account for about 80% of
  revenue, a clean Pareto signal for where to focus inventory attention
- First Class shipping runs late on the order of 95% of the time, which points
  to a scheduling-policy problem rather than an execution failure, since the
  pattern is structural and not random

## 3. Demand forecasting

Per-product demand is forecast in Python using a benchmark of methods (naive,
moving average, Holt, and Holt-Winters), compared by MAPE to find what actually
holds up on this data rather than assuming the most complex method wins.

Result to verify and paste from your run: on this dataset the naive baseline was
the strongest or near-strongest performer (around 33.6% MAPE in our run), which
is itself a finding. The series are short and noisy with limited repeating
seasonal signal, so the smoothing models did not beat a simple baseline. The
honest takeaway is about forecastability, not about forcing a fancier model.

## 4. Inventory policy

The forecast and the observed lead-time variability feed standard inventory
decisions per product:

- safety stock from a service-level factor and the variability of demand over
  the lead time
- reorder point as expected lead-time demand plus safety stock
- economic order quantity from demand, ordering cost, and holding cost

This is the step that turns the analysis into an operational recommendation:
not just what demand will be, but when to reorder and how much.

## How to run

1. Create a PostgreSQL database and run the scripts in `sql/` to build the
   staging table and the star schema, then load the dataset.
2. Run the analytical queries in `sql/`.
3. Open the notebook or script in `forecasting/` and run the forecasting and
   inventory cells against your database or exported tables.

## Key findings

- revenue concentration: about 7 SKUs drive roughly 80% of revenue
- delivery reliability: First Class shipping is late around 95% of the time, a
  structural scheduling issue
- forecasting: a naive baseline was hard to beat, a signal about the data's
  forecastability rather than a modeling shortcut
- inventory: safety stock, reorder point, and EOQ computed per product from the
  forecast and lead-time variability
