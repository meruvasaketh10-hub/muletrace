import re, json, html
import streamlit as st                

st.set_page_config(page_title="MuleTrace", page_icon="🕵️", layout="wide")

try:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
except Exception:
    session = st.connection("snowflake").session()

st.markdown("""<style>
.hero{background:linear-gradient(120deg,#0b1f4d,#2a5bd7 60%,#29b5e8);padding:26px 32px;border-radius:18px;margin-bottom:18px}
.hero h1{margin:0;font-size:2.1rem;color:#fff}.hero p{margin:6px 0 10px;font-size:1.05rem;color:#fff;opacity:.92}
.pill{display:inline-block;background:rgba(255,255,255,.2);color:#fff;padding:3px 12px;border-radius:999px;font-size:.8rem;margin-right:6px}
.card{background:#f6f8fc;border:1px solid #e1e7f5;border-radius:14px;padding:14px 18px}
.card .l{font-size:.75rem;color:#5b6784;text-transform:uppercase;letter-spacing:.05em}
.card .v{font-size:1.4rem;font-weight:700;color:#0b1f4d}
</style>""", unsafe_allow_html=True)

ALLOWED = {"KYC_FRAUD", "JOB_SCAM", "MARKETPLACE_FRAUD", "OTHER"}
NAME_OK = re.compile(r"[A-Za-z0-9_]+")

def inr(x):  # Indian digit grouping: 10,00,000
    n = int(round(float(x))); s = str(abs(n))
    if len(s) > 3:
        head, tail, parts = s[:-3], s[-3:], []
        while len(head) > 2:
            parts.insert(0, head[-2:]); head = head[:-2]
        if head: parts.insert(0, head)
        s = ",".join(parts + [tail])
    return "Rs " + ("-" if n < 0 else "") + s

def card(col, label, value):  # every value is HTML-escaped
    col.markdown(f'<div class="card"><div class="l">{html.escape(str(label))}</div>'
                 f'<div class="v">{html.escape(str(value))}</div></div>', unsafe_allow_html=True)

@st.cache_data(ttl=300)
def load(sql):
    return session.sql(sql).to_pandas()

def q(s): return str(s).replace('"', '')

def show_graph(trail, victim, freeze_accs):
    colors = {}
    for r in trail.itertuples():
        for n in (r.FROM_ACC, r.TO_ACC):
            colors[n] = "#8fe3ff" if n == victim else ("#ff6b6b" if n in freeze_accs else "#ffc96b")
    nodes = "".join(f'"{q(n)}" [fillcolor="{c}"];' for n, c in colors.items())
    edges = "".join(f'"{q(r.FROM_ACC)}" -> "{q(r.TO_ACC)}" [label="{inr(r.AMOUNT)}"];' for r in trail.itertuples())
    st.graphviz_chart('digraph{rankdir=LR;node [shape=box,style="filled,rounded",fontname=Helvetica];' + nodes + edges + '}')
    st.caption("🟦 victim   🟧 mule account   🟥 cash-out: freeze first")

def trace(v, r):  # bound parameters, no string building with user data
    sql = """WITH RECURSIVE trail (hop, from_acc, to_acc, amount, txn_time) AS (
      SELECT CAST(1 AS INT), FROM_ACCOUNT, TO_ACCOUNT, AMOUNT, TXN_TIME
      FROM MULETRACE.CORE.TRANSACTIONS WHERE FROM_ACCOUNT=? AND TO_ACCOUNT=?
      UNION ALL
      SELECT CAST(tr.hop+1 AS INT), t.FROM_ACCOUNT, t.TO_ACCOUNT, t.AMOUNT, t.TXN_TIME
      FROM trail tr JOIN MULETRACE.CORE.TRANSACTIONS t
        ON t.FROM_ACCOUNT=tr.to_acc AND t.TXN_TIME>tr.txn_time AND t.TXN_TIME<=DATEADD(hour,6,tr.txn_time)
      WHERE tr.hop<6)
    SELECT hop, from_acc, to_acc, amount, txn_time FROM trail ORDER BY hop, txn_time LIMIT 200"""
    return session.sql(sql, params=[v, r]).to_pandas()

def extract(text):  # Cortex call with bound parameters; one retry
    prompt = ("Extract fields from this complaint. Reply with ONLY a JSON object with keys: victim_account, "
              "amount_inr (a number), scam_type (one of KYC_FRAUD, JOB_SCAM, MARKETPLACE_FRAUD, OTHER), "
              "receiver_account. Complaint: " + text)
    for _ in range(2):
        out = session.sql("SELECT SNOWFLAKE.CORTEX.COMPLETE(?, ?)", params=["llama3.1-8b", prompt]).collect()[0][0]
        m = re.search(r"\{.*\}", out, re.S)
        try:
            return json.loads(m.group(0))
        except Exception:
            continue
    return None

st.markdown("""<div class="hero"><h1>🕵️ MuleTrace</h1>
<p>Follow stolen UPI money from the victim to the cash-out account in seconds, with AI and SQL inside Snowflake.</p>
<span class="pill">Snowflake Cortex</span><span class="pill">Synthetic data only</span><span class="pill">Human approves every report</span></div>""", unsafe_allow_html=True)

with st.sidebar:
    st.header("How it works")
    st.markdown("1. 🗣️ AI reads the complaint\n2. 🔗 SQL follows the money\n3. 🧊 Freeze list is built\n4. 📝 Draft report is written\n5. ✅ A human approves")
    st.info("All data is synthetic. Reports are drafts for analyst review.")

tab1, tab2, tab3 = st.tabs(["🔎 Investigate", "🧪 Try a new complaint", "📊 Detector accuracy"])

with tab1:
    cs = load("SELECT COMPLAINT_ID, SCAM_TYPE, VICTIM_ACCOUNT, AMOUNT_INR, RECEIVER_ACCOUNT, COMPLAINT_TEXT FROM MULETRACE.CORE.COMPLAINTS_CLEAN ORDER BY 1")
    names = {int(r.COMPLAINT_ID): f"Complaint #{int(r.COMPLAINT_ID)}: {str(r.SCAM_TYPE).replace('_',' ').title()}" for r in cs.itertuples()}
    cid = int(st.selectbox("Choose a complaint", list(names), format_func=lambda i: names[i]))
    row = cs[cs["COMPLAINT_ID"] == cid].iloc[0]
    trail = load(f"SELECT HOP, FROM_ACC, TO_ACC, AMOUNT, TXN_TIME FROM MULETRACE.CORE.TRAIL WHERE COMPLAINT_ID={cid} ORDER BY HOP, TXN_TIME")
    freeze = load(f"SELECT ACCOUNT_TO_FREEZE, HOP, AMOUNT_RECEIVED FROM MULETRACE.CORE.FREEZE_LIST WHERE COMPLAINT_ID={cid}")

    st.markdown("##### 1. What the victim said")
    st.info(row["COMPLAINT_TEXT"])
    st.markdown("##### 2. What the AI understood")
    c = st.columns(5)
    card(c[0], "Scam type", str(row["SCAM_TYPE"]).replace("_", " ").title())
    card(c[1], "Victim account", row["VICTIM_ACCOUNT"])
    card(c[2], "Amount claimed", inr(row["AMOUNT_INR"]))
    card(c[3], "Hops traced", int(trail["HOP"].max()) if not trail.empty else 0)
    card(c[4], "Accounts to freeze", len(freeze))

    st.markdown("##### 3. Where the money went")
    if trail.empty:
        st.warning("No trail found in bank records. Sent to a human analyst.")
    else:
        first = float(trail[trail["HOP"] == 1]["AMOUNT"].sum())
        if abs(first - float(row["AMOUNT_INR"])) < 0.01:
            st.success(f"✅ Claimed amount matches bank records ({inr(first)}).")
        else:
            st.error(f"⚠️ Mismatch: victim claimed {inr(row['AMOUNT_INR'])} but bank records show {inr(first)}.")
        left, right = st.columns([3, 2])
        with left:
            show_graph(trail, row["VICTIM_ACCOUNT"], set(freeze["ACCOUNT_TO_FREEZE"]))
        with right:
            st.markdown("**🧊 Freeze these first**")
            st.dataframe(freeze, use_container_width=True, hide_index=True)
        with st.expander("See every payment in the trail"):
            st.dataframe(trail, use_container_width=True, hide_index=True)

    st.markdown("##### 4. Draft report for the analyst")
    d = load(f"SELECT STR_DRAFT FROM MULETRACE.CORE.STR_DRAFTS WHERE COMPLAINT_ID={cid}")
    with st.container(border=True):
        st.markdown(d.iloc[0]["STR_DRAFT"] if not d.empty else "No draft for this complaint.")
    if st.button("✅ Approve report (demo)", key=f"ok{cid}"):
        st.success("Approved. This is a demo, nothing was saved or filed.")

with tab2:
    st.write("Paste a **new** complaint. Cortex reads it, we check the answer, then SQL traces the money live.")
    sample = "My account is ACC01301. A caller pretending to be from my bank's KYC team told me to send 40000 rupees by UPI. I sent it to SNK_R1_M1 and then he stopped answering."
    txt = st.text_area("Complaint text", sample, height=120, max_chars=2000)
    if st.button("🔍 Analyse complaint"):
        try:
            j = extract(txt)
            if not j:
                st.warning("The AI answer could not be read. A human should review this complaint.")
            else:
                v, r = str(j.get("victim_account", "")), str(j.get("receiver_account", ""))
                stype = str(j.get("scam_type", "OTHER"))
                try: amt = float(j.get("amount_inr", 0))
                except Exception: amt = 0
                problems = []
                if not (NAME_OK.fullmatch(v) and NAME_OK.fullmatch(r)): problems.append("account names look invalid")
                elif v == r: problems.append("victim and receiver are the same account")
                else:
                    if v.lower() not in txt.lower() or r.lower() not in txt.lower():
                        problems.append("an extracted account does not appear in the complaint text")
                    n = session.sql("SELECT COUNT(*) FROM MULETRACE.CORE.ACCOUNTS WHERE ACCOUNT_ID IN (?, ?)", params=[v, r]).collect()[0][0]
                    if n != 2: problems.append("an extracted account does not exist in the bank records")
                if amt <= 0: problems.append("amount is not a positive number")
                if stype not in ALLOWED: problems.append("unknown scam type")
                if problems:
                    st.warning("Needs human review: " + "; ".join(problems) + ".")
                else:
                    c = st.columns(4)
                    card(c[0], "Scam type", stype.replace("_", " ").title()); card(c[1], "Victim", v)
                    card(c[2], "Amount", inr(amt)); card(c[3], "First receiver", r)
                    t = trace(v, r)
                    if t.empty:
                        st.warning("No trail found in bank records. Needs human review.")
                    else:
                        ends = set(t["TO_ACC"]) - set(t["FROM_ACC"])
                        show_graph(t, v, ends)
                        st.error("🧊 Freeze first: " + ", ".join(sorted(ends)))
        except Exception as e:
            st.warning("Could not analyse this complaint. A human should review it.")
            st.caption(str(e)[:200])

with tab3:
    @st.cache_data(ttl=600)
    def accuracy():
        return session.sql("SELECT * FROM MULETRACE.CORE.DETECTOR_RESULTS").to_pandas()
    a = accuracy().set_index("RULE").copy()
    for col in ("PRECISION_PCT", "RECALL_PCT"): a[col] = a[col].astype(float)
    a["F1_PCT"] = (2 * a["PRECISION_PCT"] * a["RECALL_PCT"] / (a["PRECISION_PCT"] + a["RECALL_PCT"])).round(1)
    need = ["Simple rule", "Smart v1 (strict)", "Smart v2 (allows a cut)"]
    if not all(n in a.index for n in need):
        st.warning("DETECTOR_RESULTS has unexpected rule names. Re-run sql/step2_harder_rings.sql.")
        st.dataframe(a.reset_index(), use_container_width=True, hide_index=True)
    else:
        s, v1, v2 = a.loc[need[0]], a.loc[need[1]], a.loc[need[2]]
        c = st.columns(3)
        c[0].metric("Simple rule: innocent people accused", int(s["FALSE_ALARMS"]))
        c[1].metric("Smart v2: innocent people accused", int(v2["FALSE_ALARMS"]), delta=int(v2["FALSE_ALARMS"] - s["FALSE_ALARMS"]), delta_color="inverse")
        c[2].metric("Smart v2: share of real mules found", f"{v2['RECALL_PCT']}%", delta=f"{round(v2['RECALL_PCT'] - v1['RECALL_PCT'], 1)} pts vs v1")
        st.bar_chart(a[["FALSE_ALARMS"]])
        st.dataframe(a.reset_index(), use_container_width=True, hide_index=True)
        st.caption("Synthetic data. v1 missed the sneaky rings that keep a cut and wait hours between hops. v2 allows both. v2 was tuned on the same data it is tested on, so treat its score as optimistic.")
