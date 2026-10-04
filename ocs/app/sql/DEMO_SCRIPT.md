# MuleTrace: 2-minute demo script

Keep the Streamlit app open and scrolled to the top. Practice twice before recording.

## 0:00 to 0:15 | The problem
"When a UPI scam victim complains, the money is usually gone through four or five mule accounts within minutes. Analysts trace it by hand. MuleTrace does that in seconds, inside Snowflake. All data you'll see is synthetic."

## 0:15 to 0:40 | Complaint 1 (the main case)
Select **complaint 1**.
- Point at the complaint text: "A victim's messy complaint."
- Point at the fact boxes: "Snowflake Cortex pulled out the scam type, the victim account, the amount, and where the money went."

## 0:40 to 1:05 | The trail
Scroll to the **money trail** and the flow diagram.
- "Recursive SQL follows the money forward in time. Victim to a mule, split to two more, then two cash-out accounts, all inside seventeen minutes."
- Point at **accounts to freeze**: "These two are where the money stops moving. Freeze these first."

## 1:05 to 1:25 | The report and the safety design
Scroll to the **draft report**.
- "Every number here is computed in SQL. The AI only writes the two-sentence summary. We found a small model garbles amounts, so we kept it away from facts."
- "It's marked DRAFT. A human analyst approves it."

## 1:25 to 1:45 | Complaints 2 and 3, then a live complaint
Select **complaint 2**: "This victim wrote in Hinglish and said 30,000. The bank records show 50,000. The system flags the mismatch instead of trusting the complaint."
Select **complaint 3**: "No trail in the ledger, so it says so and sends it to a human. It doesn't invent one."
Open **Try a new complaint**, click Analyse: "A brand new complaint, read live. This ring keeps a cut and waits hours, and it still finds the cash-out account."

## 1:45 to 2:00 | Measured accuracy
Open **Detector accuracy**.
- "The obvious rule accuses 40 innocent customers. Our first detector missed the sneaky rings, so we improved it. The data is synthetic and we tuned on it, so we treat the score as optimistic."

## If something breaks live
Say "I have a recording of this" and play the backup video. Always record one.

## Things you might be asked
- **Why not let the LLM write the whole report?** It made up numbers in our testing.
- **Is the detector a trained model?** No. It is rule-based on purpose, so analysts can see why an account was flagged.
- **What would you do next?** Proportional attribution when a mule serves several victims, a proper train/test split, and cross-complaint ring linking.
