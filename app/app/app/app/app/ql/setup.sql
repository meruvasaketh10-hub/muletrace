-- =====================================================================
-- MuleTrace: UPI Fraud Investigation Copilot  |  Setup script
-- All data is SYNTHETIC. Run top to bottom (Snowsight: Run All).
-- Role used: ACCOUNTADMIN. Warehouse: any small one (e.g. COMPUTE_WH).
-- Re-runnable: tables are CREATE OR REPLACE, so a second run rebuilds
-- everything from scratch (no duplicate rows).
-- NOTE: if Cortex complains the model is unavailable in your region, run once:
--   ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
-- (fine for synthetic data; do NOT do this with real customer data)
-- =====================================================================

CREATE DATABASE IF NOT EXISTS MULETRACE;
CREATE SCHEMA IF NOT EXISTS MULETRACE.CORE;

-- ---------- 1. Tables ------------------------------------------------
CREATE OR REPLACE TABLE MULETRACE.CORE.ACCOUNTS (
  ACCOUNT_ID STRING, HOLDER_NAME STRING, BANK STRING,
  CITY STRING, OPENED_DATE DATE, ACCOUNT_TYPE STRING);

CREATE OR REPLACE TABLE MULETRACE.CORE.TRANSACTIONS (
  TXN_ID STRING, FROM_ACCOUNT STRING, TO_ACCOUNT STRING,
  AMOUNT NUMBER(12,2), TXN_TIME TIMESTAMP_NTZ, CHANNEL STRING);

CREATE OR REPLACE TABLE MULETRACE.CORE.GROUND_TRUTH (
  ACCOUNT_ID STRING, ROLE STRING, RING_ID NUMBER);

-- ---------- 2. Normal customers and payments -------------------------
INSERT INTO MULETRACE.CORE.ACCOUNTS
SELECT 'ACC' || LPAD(SEQ4()::STRING, 5, '0'),
  'Customer ' || SEQ4(),
  ARRAY_CONSTRUCT('Bank A','Bank B','Bank C','Bank D','Bank E')[UNIFORM(0,4,RANDOM())]::STRING,
  ARRAY_CONSTRUCT('Hyderabad','Mumbai','Delhi','Bengaluru','Chennai','Kolkata')[UNIFORM(0,5,RANDOM())]::STRING,
  DATEADD(day, -UNIFORM(200,3000,RANDOM()), CURRENT_DATE()),
  'INDIVIDUAL'
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

INSERT INTO MULETRACE.CORE.TRANSACTIONS
SELECT 'TXN' || LPAD(SEQ4()::STRING, 7, '0'),
  'ACC' || LPAD(UNIFORM(0,1999,RANDOM())::STRING, 5, '0'),
  'ACC' || LPAD(UNIFORM(0,1999,RANDOM())::STRING, 5, '0'),
  ROUND(UNIFORM(100,20000,RANDOM()), 2),
  DATEADD(minute, -UNIFORM(1,43200,RANDOM()), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
  'UPI'
FROM TABLE(GENERATOR(ROWCOUNT => 30000));

-- ---------- 3. Planted mule rings (5 rings x 5 accounts) -------------
INSERT INTO MULETRACE.CORE.ACCOUNTS
SELECT 'MULE_R' || r || '_' || b.k, 'Mule Holder ' || r || b.k, 'Demo Bank', 'Patna',
  DATEADD(day, -UNIFORM(5,40,RANDOM()), CURRENT_DATE()), 'INDIVIDUAL'
FROM (SELECT SEQ4()+1 AS r FROM TABLE(GENERATOR(ROWCOUNT => 5))) a
CROSS JOIN (SELECT column1 AS k FROM VALUES ('M1'),('M2'),('M3'),('C1'),('C2')) b;

-- Secret answer sheet used only to MEASURE the detector
INSERT INTO MULETRACE.CORE.GROUND_TRUTH
SELECT ACCOUNT_ID,
  IFF(RIGHT(ACCOUNT_ID,2) LIKE 'C%', 'CASHOUT', 'MULE'),
  SUBSTR(ACCOUNT_ID,7,1)::NUMBER
FROM MULETRACE.CORE.ACCOUNTS WHERE ACCOUNT_ID LIKE 'MULE%';

-- Stolen-money hops: 2 victims -> M1 -> M2/M3 -> cash-out, all within 17 minutes
INSERT INTO MULETRACE.CORE.TRANSACTIONS
SELECT 'TXN_R' || r || '_' || s.n,
  CASE s.n
    WHEN 1 THEN 'ACC' || LPAD((1100+r)::STRING, 5, '0')
    WHEN 2 THEN 'ACC' || LPAD((1200+r)::STRING, 5, '0')
    WHEN 3 THEN 'MULE_R' || r || '_M1'
    WHEN 4 THEN 'MULE_R' || r || '_M1'
    WHEN 5 THEN 'MULE_R' || r || '_M2'
    ELSE 'MULE_R' || r || '_M3' END,
  CASE s.n
    WHEN 1 THEN 'MULE_R' || r || '_M1'
    WHEN 2 THEN 'MULE_R' || r || '_M1'
    WHEN 3 THEN 'MULE_R' || r || '_M2'
    WHEN 4 THEN 'MULE_R' || r || '_M3'
    WHEN 5 THEN 'MULE_R' || r || '_C1'
    ELSE 'MULE_R' || r || '_C2' END,
  s.amt,
  DATEADD(minute, s.mins, DATEADD(hour, -r*20, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)),
  'UPI'
FROM (SELECT SEQ4()+1 AS r FROM TABLE(GENERATOR(ROWCOUNT => 5))) a
CROSS JOIN (SELECT column1 AS n, column2 AS mins, column3 AS amt
  FROM VALUES (1,0,50000),(2,3,30000),(3,8,40000),(4,9,40000),(5,15,39000),(6,17,39000)) s;

-- ---------- 4. Decoys: 40 HONEST new customers who receive big money --
-- These make the simple rule look bad (false alarms), on purpose.
INSERT INTO MULETRACE.CORE.ACCOUNTS
SELECT 'NEWCUST_' || n, 'New Customer ' || n, 'Bank A', 'Mumbai',
  DATEADD(day, -UNIFORM(5,50,RANDOM()), CURRENT_DATE()), 'INDIVIDUAL'
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
      FROM TABLE(GENERATOR(ROWCOUNT => 40)));

INSERT INTO MULETRACE.CORE.TRANSACTIONS
SELECT 'TXN_D' || a.n || '_' || p.k,
  'ACC' || LPAD(UNIFORM(0,1999,RANDOM())::STRING, 5, '0'),
  'NEWCUST_' || a.n,
  ROUND(UNIFORM(12000,20000,RANDOM()), 2),
  DATEADD(hour, -UNIFORM(1,500,RANDOM()), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
  'UPI'
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
      FROM TABLE(GENERATOR(ROWCOUNT => 40))) a
CROSS JOIN (SELECT column1 AS k FROM VALUES (1),(2),(3)) p;

-- ---------- Sneaky rings: 5 rings x 3 accounts, keep a 15% cut, wait hours between hops
-- (idempotent: safe to run more than once)
DELETE FROM MULETRACE.CORE.ACCOUNTS WHERE ACCOUNT_ID LIKE 'SNK%';
DELETE FROM MULETRACE.CORE.GROUND_TRUTH WHERE ACCOUNT_ID LIKE 'SNK%';
DELETE FROM MULETRACE.CORE.TRANSACTIONS WHERE TXN_ID LIKE 'TXN_S%';

INSERT INTO MULETRACE.CORE.ACCOUNTS
SELECT 'SNK_R' || r || '_' || b.k, 'Sneaky Holder ' || r || b.k, 'Demo Bank', 'Lucknow',
  DATEADD(day, -UNIFORM(10,30,RANDOM()), CURRENT_DATE()), 'INDIVIDUAL'
FROM (SELECT SEQ4()+1 AS r FROM TABLE(GENERATOR(ROWCOUNT => 5))) a
CROSS JOIN (SELECT column1 AS k FROM VALUES ('M1'),('M2'),('C1')) b;

INSERT INTO MULETRACE.CORE.GROUND_TRUTH
SELECT ACCOUNT_ID, IFF(RIGHT(ACCOUNT_ID,2)='C1','CASHOUT','MULE'), SUBSTR(ACCOUNT_ID,6,1)::NUMBER + 5
FROM MULETRACE.CORE.ACCOUNTS WHERE ACCOUNT_ID LIKE 'SNK%';

INSERT INTO MULETRACE.CORE.TRANSACTIONS
SELECT 'TXN_S' || r || '_' || s.n,
  CASE s.n WHEN 1 THEN 'ACC' || LPAD((1300+r)::STRING,5,'0') WHEN 2 THEN 'SNK_R'||r||'_M1' ELSE 'SNK_R'||r||'_M2' END,
  CASE s.n WHEN 1 THEN 'SNK_R'||r||'_M1' WHEN 2 THEN 'SNK_R'||r||'_M2' ELSE 'SNK_R'||r||'_C1' END,
  s.amt,
  DATEADD(minute, s.mins, DATEADD(hour, -r*15, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)),
  'UPI'
FROM (SELECT SEQ4()+1 AS r FROM TABLE(GENERATOR(ROWCOUNT => 5))) a
CROSS JOIN (SELECT column1 AS n, column2 AS mins, column3 AS amt
  FROM VALUES (1,0,40000),(2,100,34000),(3,230,28900)) s;

-- ---------- Detector accuracy view (read by the app)
-- NOTE: v2 thresholds were chosen AFTER seeing v1 miss the sneaky rings, on the same synthetic data.
CREATE OR REPLACE VIEW MULETRACE.CORE.DETECTOR_RESULTS AS
WITH new_acc AS (SELECT ACCOUNT_ID FROM MULETRACE.CORE.ACCOUNTS WHERE OPENED_DATE > DATEADD(day,-60,CURRENT_DATE())),
inflow AS (SELECT TO_ACCOUNT acc, SUM(AMOUNT) total_in FROM MULETRACE.CORE.TRANSACTIONS GROUP BY 1),
outflow AS (SELECT FROM_ACCOUNT acc, SUM(AMOUNT) total_out FROM MULETRACE.CORE.TRANSACTIONS GROUP BY 1),
simple AS (SELECT n.ACCOUNT_ID acc FROM new_acc n JOIN inflow i ON i.acc=n.ACCOUNT_ID WHERE i.total_in>=30000),
m1 AS (SELECT n.ACCOUNT_ID acc FROM new_acc n JOIN inflow i ON i.acc=n.ACCOUNT_ID JOIN outflow o ON o.acc=n.ACCOUNT_ID WHERE i.total_in>=30000 AND o.total_out>=0.9*i.total_in),
c1 AS (SELECT t.TO_ACCOUNT acc FROM MULETRACE.CORE.TRANSACTIONS t JOIN m1 ON m1.acc=t.FROM_ACCOUNT JOIN new_acc n ON n.ACCOUNT_ID=t.TO_ACCOUNT GROUP BY 1 HAVING SUM(t.AMOUNT)>=30000),
v1 AS (SELECT acc FROM m1 UNION SELECT acc FROM c1),
m2 AS (SELECT n.ACCOUNT_ID acc FROM new_acc n JOIN inflow i ON i.acc=n.ACCOUNT_ID JOIN outflow o ON o.acc=n.ACCOUNT_ID WHERE i.total_in>=25000 AND o.total_out>=0.75*i.total_in),
c2 AS (SELECT t.TO_ACCOUNT acc FROM MULETRACE.CORE.TRANSACTIONS t JOIN m2 ON m2.acc=t.FROM_ACCOUNT JOIN new_acc n ON n.ACCOUNT_ID=t.TO_ACCOUNT GROUP BY 1 HAVING SUM(t.AMOUNT)>=25000),
v2 AS (SELECT acc FROM m2 UNION SELECT acc FROM c2),
r AS (
  SELECT 'Simple rule' AS RULE, COUNT(*) AS FLAGGED, COUNT(g.ACCOUNT_ID) AS CORRECT FROM simple s LEFT JOIN MULETRACE.CORE.GROUND_TRUTH g ON g.ACCOUNT_ID=s.acc
  UNION ALL SELECT 'Smart v1 (strict)', COUNT(*), COUNT(g.ACCOUNT_ID) FROM v1 s LEFT JOIN MULETRACE.CORE.GROUND_TRUTH g ON g.ACCOUNT_ID=s.acc
  UNION ALL SELECT 'Smart v2 (allows a cut)', COUNT(*), COUNT(g.ACCOUNT_ID) FROM v2 s LEFT JOIN MULETRACE.CORE.GROUND_TRUTH g ON g.ACCOUNT_ID=s.acc)
SELECT RULE, FLAGGED, CORRECT, FLAGGED-CORRECT AS FALSE_ALARMS,
  ROUND(100*CORRECT/FLAGGED,1) AS PRECISION_PCT,
  ROUND(100*CORRECT/(SELECT COUNT(*) FROM MULETRACE.CORE.GROUND_TRUTH),1) AS RECALL_PCT
FROM r;

-- ---------- 6. Complaints + AI extraction (Cortex) --------------------
CREATE OR REPLACE TABLE MULETRACE.CORE.COMPLAINTS (COMPLAINT_ID NUMBER, COMPLAINT_TEXT STRING);

INSERT INTO MULETRACE.CORE.COMPLAINTS VALUES
(1, 'My account is ACC01101. On 29 September a man called saying he was from my bank KYC team. He told me to send 50000 rupees by UPI to verify my account. I sent it to MULE_R1_M1. Then his phone was switched off. Please help me get my money back.'),
(2, 'Mera account ACC01102 hai. Ek aadmi ne job ka lalach diya aur registration fees ke naam par 30000 rupaye MULE_R2_M1 account mein bhejne ko kaha. Paisa bhejne ke baad usne phone nahi uthaya.'),
(3, 'I am ACC00555. Someone sold me a phone on a marketplace and asked for 8000 rupees advance to ACC00777. The phone never arrived and the seller blocked me.');

-- One LLM call per complaint; result is stored so we never pay twice.
CREATE OR REPLACE TABLE MULETRACE.CORE.COMPLAINTS_AI AS
SELECT COMPLAINT_ID, COMPLAINT_TEXT,
  SNOWFLAKE.CORTEX.COMPLETE('llama3.1-8b',
    'Extract fields from this complaint. Reply with ONLY a JSON object, no other words, with keys: victim_account, amount_inr (a number), scam_type (one of KYC_FRAUD, JOB_SCAM, MARKETPLACE_FRAUD, OTHER), receiver_account, summary_en (one short English sentence). Complaint: '
    || COMPLAINT_TEXT) AS RAW_AI
FROM MULETRACE.CORE.COMPLAINTS;

-- The model sometimes wraps JSON in code fences; the regex strips them.
CREATE OR REPLACE TABLE MULETRACE.CORE.COMPLAINTS_CLEAN AS
SELECT COMPLAINT_ID, COMPLAINT_TEXT,
  p:victim_account::STRING AS victim_account,
  p:amount_inr::NUMBER AS amount_inr,
  p:scam_type::STRING AS scam_type,
  p:receiver_account::STRING AS receiver_account
FROM (SELECT *, TRY_PARSE_JSON(REGEXP_SUBSTR(RAW_AI, '\\{.*\\}', 1, 1, 's')) AS p
      FROM MULETRACE.CORE.COMPLAINTS_AI);

-- ---------- 7. Money trail (recursive SQL, time-ordered) -------------
CREATE OR REPLACE VIEW MULETRACE.CORE.TRAIL AS
WITH RECURSIVE trail (complaint_id, hop, from_acc, to_acc, amount, txn_time) AS (
  SELECT c.COMPLAINT_ID, CAST(1 AS INT), t.FROM_ACCOUNT, t.TO_ACCOUNT, t.AMOUNT, t.TXN_TIME
  FROM MULETRACE.CORE.COMPLAINTS_CLEAN c
  JOIN MULETRACE.CORE.TRANSACTIONS t
    ON t.FROM_ACCOUNT = c.victim_account AND t.TO_ACCOUNT = c.receiver_account
  UNION ALL
  SELECT tr.complaint_id, CAST(tr.hop + 1 AS INT), t.FROM_ACCOUNT, t.TO_ACCOUNT, t.AMOUNT, t.TXN_TIME
  FROM trail tr
  JOIN MULETRACE.CORE.TRANSACTIONS t
    ON t.FROM_ACCOUNT = tr.to_acc
   AND t.TXN_TIME > tr.txn_time
   AND t.TXN_TIME <= DATEADD(hour, 6, tr.txn_time)
  WHERE tr.hop < 6)
SELECT * FROM trail;

-- Accounts where the money stopped moving = freeze first
CREATE OR REPLACE VIEW MULETRACE.CORE.FREEZE_LIST AS
SELECT complaint_id, to_acc AS account_to_freeze, MAX(hop) AS hop, SUM(amount) AS amount_received
FROM MULETRACE.CORE.TRAIL
WHERE to_acc NOT IN (SELECT from_acc FROM MULETRACE.CORE.TRAIL)
GROUP BY complaint_id, to_acc;

-- ---------- 8. Draft report: SQL supplies facts, LLM writes only the summary
CREATE OR REPLACE TABLE MULETRACE.CORE.STR_DRAFTS AS
WITH first_hop AS (
  SELECT complaint_id, SUM(amount) AS first_hop_amt
  FROM MULETRACE.CORE.TRAIL WHERE hop = 1 GROUP BY complaint_id),
trail_txt AS (
  SELECT complaint_id,
    LISTAGG('- Hop ' || hop || ': ' || from_acc || ' -> ' || to_acc || ', Rs '
      || TRIM(TO_VARCHAR(amount, '999,999,990')) || ' at '
      || TO_VARCHAR(txn_time, 'YYYY-MM-DD HH24:MI'), '\n')
      WITHIN GROUP (ORDER BY hop, txn_time) AS trail_text
  FROM MULETRACE.CORE.TRAIL GROUP BY complaint_id),
freeze_txt AS (
  SELECT complaint_id,
    LISTAGG('- ' || account_to_freeze || ' (hop ' || hop || ', Rs '
      || TRIM(TO_VARCHAR(amount_received, '999,999,990')) || ' received)', '\n') AS freeze_text
  FROM MULETRACE.CORE.FREEZE_LIST GROUP BY complaint_id)
SELECT c.COMPLAINT_ID,
  '### 1. Summary\n'
  || SNOWFLAKE.CORTEX.COMPLETE('llama3.1-8b',
       'Write a neutral 2-sentence summary in English of this fraud complaint for a bank analyst. Use only facts in the complaint. Do not mention any amount except Rs '
       || c.amount_inr || '. Scam type: ' || c.scam_type || '. Complaint: ' || c.COMPLAINT_TEXT)
  || '\n\n### 2. Money trail (from bank records)\n'
  || COALESCE(t.trail_text, 'No trail found in bank records.')
  || '\n\n### 3. Accounts recommended for freeze\n'
  || COALESCE(f.freeze_text, 'None identified.')
  || '\n\n### 4. Checks\n'
  || CASE
       WHEN h.first_hop_amt IS NULL
         THEN '- No matching first payment found in bank records. Needs human review.'
       WHEN h.first_hop_amt = c.amount_inr
         THEN '- Claimed amount (Rs ' || TRIM(TO_VARCHAR(c.amount_inr, '999,999,990'))
              || ') matches the first payment in bank records.'
       ELSE '- MISMATCH: victim claimed Rs ' || TRIM(TO_VARCHAR(c.amount_inr, '999,999,990'))
              || ' but bank records show Rs ' || TRIM(TO_VARCHAR(h.first_hop_amt, '999,999,990'))
              || ' as the first payment. Needs human review.'
     END
  || '\n\n**DRAFT - requires human analyst review.**' AS STR_DRAFT
FROM MULETRACE.CORE.COMPLAINTS_CLEAN c
LEFT JOIN trail_txt t ON t.complaint_id = c.COMPLAINT_ID
LEFT JOIN freeze_txt f ON f.complaint_id = c.COMPLAINT_ID
LEFT JOIN first_hop h ON h.complaint_id = c.COMPLAINT_ID;

-- ---------- 9. Sanity checks -----------------------------------------
-- Expected: ACCOUNTS 2080, TRANSACTIONS 30165, GROUND_TRUTH 40, COMPLAINTS 3
SELECT (SELECT COUNT(*) FROM MULETRACE.CORE.ACCOUNTS)     AS accounts,
       (SELECT COUNT(*) FROM MULETRACE.CORE.TRANSACTIONS) AS transactions,
       (SELECT COUNT(*) FROM MULETRACE.CORE.GROUND_TRUTH) AS ground_truth,
       (SELECT COUNT(*) FROM MULETRACE.CORE.COMPLAINTS)   AS complaints;
