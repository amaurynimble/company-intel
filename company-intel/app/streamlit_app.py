"""Company intelligence cockpit (Streamlit in Snowflake) over NIMBLE_INTEL.MART.

The visual cockpit is cockpit.html, filled with one company's data from cockpit_data.build().
The chat below it calls the Cortex Agent COMPANY_INTEL_ANALYST and falls back to Cortex Analyst.
No Cortex call runs at page load.
"""
import json
import os

import streamlit as st
import streamlit.components.v1 as components
from snowflake.snowpark.context import get_active_session

import cockpit_data

st.set_page_config(page_title="Company intelligence", layout="wide", initial_sidebar_state="collapsed")
st.markdown("""<style>
#MainMenu, footer, header { visibility: hidden; height: 0; }
.block-container { padding-top: 0.6rem !important; padding-bottom: 1rem !important; max-width: 100% !important; }
div[data-testid="stSelectbox"] { max-width: 420px; }
</style>""", unsafe_allow_html=True)

session = get_active_session()
AGENT_PATH = "/api/v2/databases/NIMBLE_INTEL/schemas/APP/agents/COMPANY_INTEL_ANALYST:run"
SV = "NIMBLE_INTEL.APP.COMPANY_INTEL_SV"
HERE = os.path.dirname(os.path.abspath(__file__))


def q(sql, params=None):
    return [{k.lower(): v for k, v in r.as_dict().items()} for r in session.sql(sql, params=params or []).collect()]


@st.cache_data(ttl=300, show_spinner=False)
def companies():
    return q("SELECT company_id, company, status FROM NIMBLE_INTEL.MART.V_COMPANIES ORDER BY created_at DESC")


@st.cache_data(ttl=300, show_spinner="Loading the company")
def payload(cid):
    return cockpit_data.build(cid, q)


@st.cache_data(show_spinner=False)
def template():
    with open(os.path.join(HERE, "cockpit.html"), encoding="utf-8") as f:
        return f.read()


rows = companies()
if not rows:
    st.info("No company has been researched yet. In Cortex Code, run /company-intel <company>. "
            "In SQL, run CALL NIMBLE_INTEL.CORE.RESEARCH('Company', 'company.com').")
    st.stop()
labels = {r["company_id"]: r["company"] + ("" if r["status"] == "ready" else f" (research {r['status']})") for r in rows}
cid = st.selectbox("Company", list(labels), format_func=lambda k: labels[k], label_visibility="collapsed")
data = payload(cid)
html = template().replace("/*DATA*/null", json.dumps(data, default=str).replace("</", "<\\/"))
components.html(html, height=1500, scrolling=True)


# ------------------------------------------------------------------ chat with the Cortex Agent
def ask(question, company):
    import _snowflake
    text, table = "", None
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": f"Company id: {cid} ({company}). {question}"}]}]}
    try:
        resp = _snowflake.send_snow_api_request("POST", AGENT_PATH, {}, {}, body, None, 120000)
        content = resp.get("content") if isinstance(resp, dict) else None
        if isinstance(content, str):
            events = []
            try:
                events = json.loads(content)
            except ValueError:
                for line in content.splitlines():
                    if line.startswith("data:"):
                        try:
                            events.append(json.loads(line[5:].strip()))
                        except ValueError:
                            pass
            if isinstance(events, dict):
                events = [events]
            for ev in events:
                d = ev.get("data", ev) if isinstance(ev, dict) else {}
                if isinstance(d, dict) and ev.get("event", "") in ("response.text.delta", "response.text", "") and isinstance(d.get("text"), str):
                    text += d["text"]
                elif isinstance(d, dict) and d.get("role") == "assistant":
                    text += "".join(p.get("text", "") for p in d.get("content", []) if isinstance(p, dict) and p.get("type") == "text")
    except Exception:  # noqa: BLE001
        text = ""
    if text.strip():
        return text, None
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": f"For company_id {cid}: {question}"}]}], "semantic_view": SV}
    resp = _snowflake.send_snow_api_request("POST", "/api/v2/cortex/analyst/message", {}, {}, body, None, 60000)
    content = resp.get("content") if isinstance(resp, dict) else None
    content = json.loads(content) if isinstance(content, str) else content or {}
    parts = (content.get("message") or {}).get("content", [])
    text = "".join(p.get("text", "") for p in parts if p.get("type") == "text")
    sql = next((p.get("statement") for p in parts if p.get("type") == "sql"), None)
    if sql:
        table = session.sql(sql).to_pandas().head(50)
    return text or "Here is what the data shows.", table


company = labels[cid].split(" (research")[0]
st.markdown(f"#### Ask the analyst about {company}")
st.caption("The Cortex Agent answers from this research and can search the live web through Nimble. "
           "The same agent is in Snowflake Intelligence.")
key = f"chat_{cid}"
st.session_state.setdefault(key, [])
for role, text, table in st.session_state[key]:
    with st.chat_message(role):
        st.markdown(text)
        if table is not None:
            st.dataframe(table, hide_index=True)
question = st.chat_input(f"For example: which rival does ChatGPT name most often, and why?")
if question:
    st.session_state[key].append(("user", question, None))
    with st.spinner("The analyst is working"):
        try:
            answer, table = ask(question, company)
        except Exception as e:  # noqa: BLE001
            answer, table = f"The analyst could not answer: {str(e)[:200]}", None
    st.session_state[key].append(("assistant", answer, table))
    st.rerun()
