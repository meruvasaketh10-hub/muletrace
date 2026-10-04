# MuleTrace: UPI Fraud Investigation Copilot

**Snowflake CoCo CLI Hackathon: GCC Edition**
Domain: Risk, Fraud and Regulatory Intelligence Copilot
Team: `[skyatix]` | Members: `[saketh ram]`

> **All data in this project is synthetic.** The report output is a **draft for a human analyst to review and approve**. Nothing here files a real report or freezes a real account.

## The problem

When a UPI scam victim complains, an analyst has to work out where the money went. The money usually hops through several "mule" accounts within minutes before being cashed out. Doing this by hand is slow, and every hour of delay lowers the chance of recovering the money.

## What MuleTrace does

An analyst picks a complaint, and MuleTrace:

1. **Extracts the facts** (victim account, amount, scam type, first receiver) from the free-text complaint, including a Hinglish one, using Snowflake Cortex.
2. **Traces the money** hop by hop through the transaction ledger with recursive SQL, following only payments that happen *after* the money arrives.
3. **Lists the accounts to freeze first**: the accounts where the money stopped moving.
4. **Drafts a report** with four sections: summary, money trail, accounts to freeze, and checks.
5. **Checks the victim's claim against bank records.** If the claimed amount differs from the first payment on record, it flags a mismatch for the analyst.
6. **Analyses a brand new complaint live**, with checks on what the AI extracted before anything is traced.
7. **Reports measured detector accuracy** against planted ground truth.

## Design principle: the AI never writes numbers

Every account ID, amount, timestamp and check in the report is computed in SQL. The LLM writes only a short two-sentence summary. In testing, a small LLM wrote a garbled amount and an invented "discrepancy" when asked to produce the whole report, so we moved all facts out of the model.

## Architecture (all inside Snowflake)

```
Complaint text
   |  Cortex COMPLETE (extract JSON)         -> COMPLAINTS_AI -> COMPLAINTS_CLEAN
   v
Recursive SQL over TRANSACTIONS              -> TRAIL (view)
   v
Terminal accounts                            -> FREEZE_LIST (view)
   v
SQL facts + short LLM summary                -> STR_DRAFTS
   v
Streamlit app (analyst review, "approve")
```

| Component | Snowflake feature |
|---|---|
| Complaint understanding | Cortex LLM function (`SNOWFLAKE.CORTEX.COMPLETE`) |
| Money trail | Recursive CTE in SQL |
| Detector accuracy | SQL view (`DETECTOR_RESULTS`) against a `GROUND_TRUTH` table |
| UI | Streamlit in Snowflake |
| Build and verification | Snowflake CoCo CLI |

## Detector results (measured on synthetic data)

The data has 5 planted mule rings (25 accounts), 5 "sneaky" rings (15 accounts) that keep a 15% cut and wait hours between hops, and 40 honest new accounts that also receive large payments, as decoys.

| Rule | Flagged | Correct | False alarms | Precision % | Recall % |
|---|---|---|---|---|---|
| Simple rule | 75 | 35 | 40 | 46.7 | 87.5 |
| Smart v1 (strict) | 25 | 25 | 0 | 100 | 62.5 |
| Smart v2 (allows a cut) | 40 | 40 | 0 | 100 | 100 |

*(Copy these numbers from the "Detector accuracy" tab in the app.)*

**Honest caveat:** v1 missed the sneaky rings, so we loosened the thresholds in v2. We tuned v2 on the same synthetic data we test on, so its score is optimistic. We do not claim this will hold on real bank data, where mules split amounts and add delays.

## Known limitations

- **Synthetic data only.** No real transactions or customers.
- **Rule-based detector.** It is simple and explainable, not a trained model.
- **Trace follows all outgoing money** from each account within a six-hour window. When a mule account serves two victims, the trace does not split the money in proportion. A production system would attribute amounts per victim.
- **Small LLM.** The summary sentence can occasionally add a detail that is not in the complaint (we saw this once). That is why every report is a draft that needs human review.
- **Three sample complaints.** The pipeline is built to run on more, but we only tested these three.
- **Detector tuned on its own test data.** Smart v2 thresholds were chosen after v1 missed the sneaky rings, with no train/test split. Its score is optimistic.
- **Approval button is a demo.** It does not save an audit record. A real system needs an audit table (analyst, time, report version) and role-based access.
- **Trace assumptions.** The first hop must go to the receiver named in the complaint, so a wrongly named receiver gives "no trail". Time only moves forward, so loops cannot repeat, and hops and rows are capped, but branching rings are not tracked proportionally.
- **Freeze list is computed across all trails together.** This is fine for our separate rings but would need to be per complaint in production.
- **Hardening done:** all values shown in cards are HTML-escaped; SQL and the Cortex call use bound parameters; AI-extracted accounts must appear in the complaint text, exist in the bank records, and pass amount and scam-type checks, otherwise the case goes to human review.
- **Extraction uses a small model** (llama3.1-8b) because it worked in our region. A stronger model or Snowflake's newer extraction functions may do better.

## How to run it

**Requirements:** a Snowflake account with Cortex enabled, and the ACCOUNTADMIN role (or one that can create a database).

1. Open a new SQL file in Snowsight and paste `sql/setup.sql`. Use the small arrow next to the Run button and choose **Run all**. It creates the database `MULETRACE`, schema `CORE`, all tables and views, and runs the AI steps.
2. Check the last query returns: accounts `2080`, transactions `30165`, ground_truth `40`, complaints `3`.
3. In a Snowsight workspace choose **+ Add new, then Streamlit app**. Replace `streamlit_app.py` with `app/streamlit_app.py` from this repo and click **Run**.

If Cortex says the model is not available in your region, run once:
`ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` (acceptable for synthetic data only).

## Cost notes

An X-Small warehouse is enough. The only LLM calls are one per complaint for extraction and one per complaint for the summary, and results are stored in tables so they are never recomputed.

## How CoCo CLI was used

"We installed Snowflake CoCo CLI (Cortex Code v1.1.87) and connected it to our Snowflake account. We used it to query our data in plain English and to verify our work. For example, it counted rows in our tables, checked our detector against the planted ground truth (25 flagged, 25 correct), parsed the AI-extracted complaint fields, and flagged a missing amount in one of our early draft reports. Screenshots are in the docs folder."

DEMO VIDEO : https://youtu.be/kALf7-6xVaE?si=bLLlzfsdH6JX3Wr_

## Repo layout

```
README.md
sql/setup.sql
app/streamlit_app.py
DEMO_SCRIPT.md
docs/            
```
