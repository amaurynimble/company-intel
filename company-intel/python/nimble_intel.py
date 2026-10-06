"""Nimble company intelligence: stored-procedure handlers for NIMBLE_INTEL.CORE.

Staged at @NIMBLE_INTEL.CORE.CODE and imported by the procedures in sql/02_procs.sql:
  INSTALL_AGENTS()                              -> creates (or finds) the two Web Search Agents on the customer's key
  RESEARCH(company, domain, market, include_maps) -> registers the company and submits the account brief run
  POLL()                                        -> called by POLL_TASK every 2 minutes; advances every company
  BUILD(company_id)                             -> Cortex classification, then marks the company ready

All Nimble calls go to sdk.nimbleway.com with the key in the NIMBLE_INTEL.CORE.NIMBLE_KEY secret.
"""
import json
import re
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import _snowflake
import requests

BASE = "https://sdk.nimbleway.com"
DB = "NIMBLE_INTEL.CORE"
METROS = ["New York NY", "Los Angeles CA", "Chicago IL", "Houston TX", "Phoenix AZ",
          "Philadelphia PA", "San Antonio TX", "San Diego CA", "Dallas TX", "Miami FL"]
SOCIAL_ANGLES = ["", "customer service", "price", "review", "problem"]
LLM_ENGINES = ["chatgpt", "gemini"]
MAX_ATTEMPTS = 2


# ------------------------------------------------------------------ helpers
def _headers():
    return {"Authorization": "Bearer " + _snowflake.get_generic_secret_string("nimble_key"),
            "Content-Type": "application/json", "X-Client-Source": "snowflake-company-intel"}


def _req(method, path, body=None, params=None, timeout=60):
    for attempt in range(4):
        r = requests.request(method, BASE + path, headers=_headers(), json=body, params=params, timeout=timeout)
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(5 * (attempt + 1))
            continue
        return r
    return r


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _slug(s):
    return re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_")


def _q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()


def _json_param(v):
    return json.dumps(v, ensure_ascii=False)


def _insert(session, table, cols, rows):
    """Inserts rows; VARIANT columns are passed as JSON text and wrapped with PARSE_JSON by the caller's col spec."""
    if not rows:
        return 0
    # Snowpark binds Python None as the text 'None', so missing values are written as a literal NULL instead of a bind.
    names = [c.split(":")[0] for c in cols]
    sel = ", ".join(f"PARSE_JSON(column{i + 1})" if c.endswith(":v") else f"column{i + 1}" for i, c in enumerate(cols))
    for k in range(0, len(rows), 200):
        chunk = rows[k:k + 200]
        values, flat = [], []
        for r in chunk:
            marks = []
            for j, v in enumerate(r):
                if v is None:
                    marks.append("NULL")
                else:
                    marks.append("?")
                    flat.append(_json_param(v) if cols[j].endswith(":v") else v)
            values.append("(" + ", ".join(marks) + ")")
        _q(session, f"INSERT INTO {DB}.{table} ({', '.join(names)}) SELECT {sel} FROM VALUES {', '.join(values)}", flat)
    return len(rows)


def _job(session, company_id, step, kind, label, status="queued", remote_id=None, agent_id=None, payload=None):
    jid = uuid.uuid4().hex[:16]
    _q(session, f"""INSERT INTO {DB}.JOBS (job_id, company_id, step, kind, label, remote_id, agent_id, status, attempts, input, created_at, updated_at)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, 1, PARSE_JSON(?), CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()""",
       [jid, company_id, step, kind, label, remote_id, agent_id, status, _json_param(payload or {})])
    return jid


def _set_job(session, job_id, status, error=None, remote_id=None):
    _q(session, f"""UPDATE {DB}.JOBS SET status = ?, error = COALESCE(?, error), remote_id = COALESCE(?, remote_id),
        updated_at = CURRENT_TIMESTAMP() WHERE job_id = ?""", [status, error, remote_id, job_id])


def _agent_ids(session):
    return {r["AGENT_KEY"]: r["AGENT_ID"] for r in _q(session, f"SELECT agent_key, agent_id FROM {DB}.CFG_AGENTS")}


# ------------------------------------------------------------------ INSTALL_AGENTS
def install_agents(session):
    out = {}
    existing = {}
    r = _req("GET", "/v2/agents", params={"limit": 100})
    if r.status_code == 200:
        for a in r.json().get("items", []):
            existing[a.get("agent_name") or a.get("name")] = a.get("id")
    for key, fname in [("account_brief", "account_brief.json"), ("brand_signals", "brand_signals.json")]:
        spec = json.loads(session.file.get_stream(f"@{DB}.CODE/agents/{fname}").read().decode("utf-8"))
        name = spec["agent_name"]
        agent_id = existing.get(name)
        if not agent_id:
            r = _req("POST", "/v2/agents", body=spec, timeout=90)
            if r.status_code >= 300:
                return {"error": f"create {name} failed: http {r.status_code} {r.text[:300]}"}
            agent_id = r.json().get("id")
            out[key] = "created"
        else:
            out[key] = "found"
        _q(session, f"DELETE FROM {DB}.CFG_AGENTS WHERE agent_key = ?", [key])
        _q(session, f"INSERT INTO {DB}.CFG_AGENTS (agent_key, agent_name, agent_id, installed_at) SELECT ?, ?, ?, CURRENT_TIMESTAMP()",
           [key, name, agent_id])
        out[key + "_id"] = agent_id
    return out


# ------------------------------------------------------------------ START
def _submit_wsa(agent_id, text, effort=None):
    body = {"input": text + "\n\nFull report: research from scratch, do not reuse earlier runs."}
    if effort:
        body["effort"] = effort
    r = _req("POST", f"/v2/agents/{agent_id}/runs", body=body, timeout=60)
    if r.status_code >= 300:
        raise RuntimeError(f"agent run failed: http {r.status_code} {r.text[:200]}")
    return r.json().get("id")


def start(session, company, domain, market, include_maps):
    ids = _agent_ids(session)
    if "account_brief" not in ids:
        return {"error": "Agents are not installed. Run CALL NIMBLE_INTEL.CORE.INSTALL_AGENTS() first."}
    company_id = _slug(company)
    market = (market or "US").upper()
    _q(session, f"DELETE FROM {DB}.COMPANIES WHERE company_id = ?", [company_id])
    for t in ["JOBS", "CFG_BRANDS", "CFG_PROMPTS", "CFG_KEYWORDS", "RAW_AGENT", "RAW_LLM", "RAW_SERP", "RAW_NEWS",
              "RAW_SOCIAL", "RAW_MAPS_PLACES", "RAW_MAPS_REVIEWS", "REVIEWS_ENRICHED", "NEWS_ENRICHED", "SOCIAL_ENRICHED"]:
        _q(session, f"DELETE FROM {DB}.{t} WHERE company_id = ?", [company_id])
    _q(session, f"""INSERT INTO {DB}.COMPANIES (company_id, company, domain, market, include_maps, status, created_at)
        SELECT ?, ?, ?, ?, ?, 'brief', CURRENT_TIMESTAMP()""", [company_id, company, domain, market, include_maps])
    run_id = _submit_wsa(ids["account_brief"], f"{company} ({domain})")
    _job(session, company_id, "account_brief", "wsa", "ab", status="running", remote_id=run_id, agent_id=ids["account_brief"],
         payload={"input": f"{company} ({domain})"})
    return {"company_id": company_id, "status": "brief", "account_brief_run": run_id,
            "next": "POLL_TASK advances the run every 2 minutes. Track progress in NIMBLE_INTEL.MART.V_JOB_STATUS."}


# ------------------------------------------------------------------ fan-out after the account brief
CONFIG_PROMPT = """You configure brand monitoring for {company} ({domain}) in the {market} market.
Industry: {industry}. Description: {description}
Competitors the research found: {rivals}

Return one JSON object with these keys:
- "rivals": the 3 most direct competitors of {company} in {market}, as [{{"name": ..., "domain": ...}}]. Prefer the list above. Use the brand name customers know, such as "Verizon" or "Xfinity Mobile", never a legal name such as "Verizon Communications Inc.". Use the domain of that consumer brand.
- "aliases": an object mapping {company} and each rival name to 2 to 5 lowercase strings customers use to name that brand (brand name, short name, main sub-brands). Never include a string that is also an ordinary word or a generic category word; write "visible wireless", never "visible".
- "domains": an object mapping {company} and each rival name to the list of websites that brand owns, main consumer site first.
- "prompts": 20 questions a customer in {market} would ask an AI assistant while choosing in this category. Never name a brand.
- "keywords": 30 Google search queries for this category without brand names: generic, comparison and purchase-intent queries.
- "has_locations": true if customers visit physical stores or branches of these brands.
- "location_word": the word to add to a brand name on Google Maps, such as "store" or "bank branch".
Reply with the JSON object only."""


def _cortex_json(session, prompt):
    row = _q(session, "SELECT AI_COMPLETE('claude-sonnet-4-5', ?) AS r", [prompt])[0]["R"]
    text = row if isinstance(row, str) else json.dumps(row)
    for _ in range(2):  # AI_COMPLETE can return the answer as a JSON-encoded string
        try:
            v = json.loads(text)
        except ValueError:
            break
        if isinstance(v, dict):
            return v
        if isinstance(v, str):
            text = v
    text = re.sub(r"^```(json)?|```$", "", text.strip(), flags=re.M)
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0)) if m else {}


def fan_out(session, company_id):
    for t in ["CFG_BRANDS", "CFG_PROMPTS", "CFG_KEYWORDS"]:  # safe to retry after a partial fan-out
        _q(session, f"DELETE FROM {DB}.{t} WHERE company_id = ?", [company_id])
    _q(session, f"DELETE FROM {DB}.JOBS WHERE company_id = ? AND label <> 'ab'", [company_id])
    c = _q(session, f"SELECT * FROM {DB}.COMPANIES WHERE company_id = ?", [company_id])[0]
    brief = _q(session, f"SELECT payload FROM {DB}.RAW_AGENT WHERE company_id = ? AND label = 'ab'", [company_id])
    content = json.loads(brief[0]["PAYLOAD"]) if brief else {}
    co = (content.get("company") or [{}])[0]
    rivals = [r for r in content.get("rivals", []) if r.get("name") and r.get("name") != "none_found"]
    units = [u for u in content.get("units", []) if u.get("name") and u.get("name") != "none_found"][:4]
    cfg = _cortex_json(session, CONFIG_PROMPT.format(
        company=c["COMPANY"], domain=c["DOMAIN"], market=c["MARKET"], industry=co.get("industry", ""),
        description=co.get("description", ""), rivals=", ".join(f"{r['name']} ({r.get('domain', '')})" for r in rivals) or "none found"))
    picked = (cfg.get("rivals") or [{"name": r["name"], "domain": r.get("domain", "")} for r in rivals])[:3]
    aliases = cfg.get("aliases") or {}
    doms = cfg.get("domains") or {}
    def _doms(name, first):
        out = [d.lower() for d in ([first] if first else []) + list(doms.get(name) or []) if d]
        return ",".join(dict.fromkeys(out))
    brands = [(c["COMPANY"], _doms(c["COMPANY"], c["DOMAIN"]), True)] + [(r["name"], _doms(r["name"], r.get("domain", "")), False) for r in picked]
    rows = []
    for name, dom, focal in brands:
        al = [a.lower() for a in (aliases.get(name) or []) if a] or [name.lower()]
        if name.lower() not in al:
            al.insert(0, name.lower())
        rows.append([company_id, _slug(name), name, (dom or "").lower(), focal, al])
    _insert(session, "CFG_BRANDS", ["company_id", "brand_id", "brand", "domain", "is_focal", "aliases:v"], rows)
    _insert(session, "CFG_PROMPTS", ["company_id", "prompt_id", "prompt"],
            [[company_id, i + 1, p] for i, p in enumerate((cfg.get("prompts") or [])[:20])])
    _insert(session, "CFG_KEYWORDS", ["company_id", "keyword_id", "keyword"],
            [[company_id, i + 1, k] for i, k in enumerate((cfg.get("keywords") or [])[:30])])
    include_maps = c["INCLUDE_MAPS"]
    if include_maps is None:
        include_maps = bool(cfg.get("has_locations"))
    _q(session, f"UPDATE {DB}.COMPANIES SET include_maps = ?, location_word = ?, industry = ? WHERE company_id = ?",
       [include_maps, cfg.get("location_word") or "store", co.get("industry"), company_id])

    ids = _agent_ids(session)
    for u in units:
        text = f"{c['COMPANY']} ({c['DOMAIN']}) — {u['name']}. Focus on this unit's leaders, data stack and initiatives."
        try:
            rid = _submit_wsa(ids["account_brief"], text)
            _job(session, company_id, "unit_brief", "wsa", "ab__" + _slug(u["name"])[:40], "running", rid, ids["account_brief"], {"input": text})
        except Exception as e:  # noqa: BLE001
            _job(session, company_id, "unit_brief", "wsa", "ab__" + _slug(u["name"])[:40], "failed", payload={"input": text, "error": str(e)[:300]})
    for name, dom, focal in brands:
        text = f"{name} ({dom.split(',')[0]}), market: {c['MARKET']}"
        try:
            rid = _submit_wsa(ids["brand_signals"], text)
            _job(session, company_id, "brand_scan", "wsa", "bs__" + _slug(name), "running", rid, ids["brand_signals"], {"input": text})
        except Exception as e:  # noqa: BLE001
            _job(session, company_id, "brand_scan", "wsa", "bs__" + _slug(name), "failed", payload={"input": text, "error": str(e)[:300]})
    prompts = (cfg.get("prompts") or [])[:20]
    with ThreadPoolExecutor(8) as ex:
        subs = list(ex.map(lambda a: _submit_llm(*a), [(e, i + 1, p, c["MARKET"]) for e in LLM_ENGINES for i, p in enumerate(prompts)]))
    for engine, pid, prompt, tid, err in subs:
        _job(session, company_id, "ai_answers", "llm", f"{engine}__{pid}", "running" if tid else "failed", tid,
             payload={"engine": engine, "prompt_id": pid, "prompt": prompt, "error": err})
    for step in ["serp", "news", "social"] + (["maps_places"] if include_maps else []):
        _job(session, company_id, step, "sync", step)
    _q(session, f"UPDATE {DB}.COMPANIES SET status = 'collecting' WHERE company_id = ?", [company_id])


def _submit_llm(engine, prompt_id, prompt, market):
    params = {"prompt": prompt}
    if engine == "chatgpt":
        params["country_code"] = market
    try:
        r = _req("POST", "/v1/agents/async", body={"agent": engine, "params": params}, timeout=60)
        if r.status_code >= 300:
            return engine, prompt_id, prompt, None, f"http {r.status_code}"
        return engine, prompt_id, prompt, (r.json().get("task") or {}).get("id"), None
    except Exception as e:  # noqa: BLE001
        return engine, prompt_id, prompt, None, str(e)[:200]


# ------------------------------------------------------------------ remote polling
def _check_remote(job):
    kind, rid = job["KIND"], job["REMOTE_ID"]
    try:
        if kind == "wsa":
            r = _req("GET", f"/v2/agents/{job['AGENT_ID']}/runs/{rid}", timeout=30)
            st = (r.json() or {}).get("status") if r.status_code == 200 else None
            if st == "completed":
                res = _req("GET", f"/v2/agents/{job['AGENT_ID']}/runs/{rid}/result", timeout=60)
                if res.status_code == 200:
                    return "done", ((res.json().get("output") or {}).get("content")), None
                return "running", None, None
            if st in ("failed", "cancelled"):
                return "failed", None, st
            return "running", None, None
        r = _req("GET", f"/v1/tasks/{rid}", timeout=30)
        st = ((r.json() or {}).get("task") or {}).get("state") if r.status_code == 200 else None
        if st == "success":
            res = _req("GET", f"/v1/tasks/{rid}/results", timeout=60)
            parsing = ((res.json() or {}).get("data") or {}).get("parsing") if res.status_code == 200 else None
            return ("done", parsing, None) if parsing else ("failed", None, "empty result")
        if st in ("failed", "error", "cancelled"):
            return "failed", None, st
        return "running", None, None
    except Exception as e:  # noqa: BLE001
        return "running", None, str(e)[:200]


def _store_remote(session, job, content):
    inp = json.loads(job["INPUT"]) if isinstance(job["INPUT"], str) else (job["INPUT"] or {})
    if job["KIND"] == "wsa":
        label = job["LABEL"]
        brand_id = label[4:] if label.startswith("bs__") else None
        _q(session, f"DELETE FROM {DB}.RAW_AGENT WHERE company_id = ? AND label = ?", [job["COMPANY_ID"], label])
        _insert(session, "RAW_AGENT", ["company_id", "label", "step", "brand_id", "payload:v", "fetched_at"],
                [[job["COMPANY_ID"], label, job["STEP"], brand_id, content, _now()]])
        return
    answer = content.get("markdown") or content.get("answer") or ""
    if not answer.strip():
        raise ValueError("empty answer")
    _insert(session, "RAW_LLM", ["company_id", "engine", "prompt_id", "prompt", "answer", "sources:v", "ads:v", "fetched_at"],
            [[job["COMPANY_ID"], inp.get("engine"), inp.get("prompt_id"), inp.get("prompt"), answer,
              content.get("sources") or [], content.get("ads") or [], _now()]])


def _retry(session, job, reason):
    inp = json.loads(job["INPUT"]) if isinstance(job["INPUT"], str) else (job["INPUT"] or {})
    if job["ATTEMPTS"] >= MAX_ATTEMPTS:
        _set_job(session, job["JOB_ID"], "failed", reason)
        return
    try:
        if job["KIND"] == "wsa":
            rid = _submit_wsa(job["AGENT_ID"], inp["input"], effort="x-high")
        else:
            _, _, _, rid, err = _submit_llm(inp["engine"], inp["prompt_id"], inp["prompt"], "US")
            if not rid:
                raise RuntimeError(err)
        _q(session, f"""UPDATE {DB}.JOBS SET remote_id = ?, attempts = attempts + 1, status = 'running', error = ?,
            updated_at = CURRENT_TIMESTAMP() WHERE job_id = ?""", [rid, f"retry after: {reason}", job["JOB_ID"]])
    except Exception as e:  # noqa: BLE001
        _set_job(session, job["JOB_ID"], "failed", f"{reason}; retry failed: {str(e)[:150]}")


# ------------------------------------------------------------------ synchronous collectors
def _serp(body, timeout=120):
    """One SERP call; a timeout or error returns no entities so one slow query never fails the whole step."""
    try:
        r = _req("POST", "/v1/serp", body=dict(body, parse=True), timeout=timeout)
        if r.status_code != 200:
            return {}
        return ((r.json().get("data") or {}).get("parsing") or {}).get("entities") or {}
    except Exception:  # noqa: BLE001
        return {}


def _brands(session, company_id):
    rows = _q(session, f"SELECT brand_id, brand, domain, is_focal, aliases FROM {DB}.CFG_BRANDS WHERE company_id = ?", [company_id])
    return [{"id": r["BRAND_ID"], "name": r["BRAND"], "domain": r["DOMAIN"], "focal": r["IS_FOCAL"],
             "aliases": json.loads(r["ALIASES"]) if isinstance(r["ALIASES"], str) else r["ALIASES"]} for r in rows]


def collect_serp(session, company_id, market):
    """Google results for every keyword and every prompt: organic, paid ads and the AI Overview."""
    qs = [("keyword", r["KEYWORD"]) for r in _q(session, f"SELECT keyword FROM {DB}.CFG_KEYWORDS WHERE company_id = ?", [company_id])]
    qs += [("prompt", r["PROMPT"]) for r in _q(session, f"SELECT prompt FROM {DB}.CFG_PROMPTS WHERE company_id = ?", [company_id])]

    def one(q):
        ents = _serp({"search_engine": "google_search", "query": q[1], "country": market, "locale": "en"})
        keep = {k: v for k, v in ents.items() if k in ("OrganicResult", "Ad", "AIOverview")}
        return [company_id, q[0], q[1], keep, _now()]
    with ThreadPoolExecutor(10) as ex:
        rows = [r for r in ex.map(one, qs) if r[3]]
    return _insert(session, "RAW_SERP", ["company_id", "query_type", "query", "entities:v", "fetched_at"], rows)


def collect_news(session, company_id, market):
    def one(b):
        ents = _serp({"search_engine": "google_news", "query": b["name"], "country": market, "locale": "en"})
        out = []
        for n in ents.get("NewsResult", []) or []:
            src = (n.get("source") or [{}])
            out.append([company_id, b["id"], n.get("title"), (src[0] or {}).get("name") if src else None,
                        (n.get("date") or "")[:10] or None, n.get("link"), _now()])
        return out
    with ThreadPoolExecutor(4) as ex:
        rows = [r for batch in ex.map(one, _brands(session, company_id)) for r in batch]
    return _insert(session, "RAW_NEWS", ["company_id", "brand_id", "title", "source", "published", "url", "fetched_at"], rows)


def collect_social(session, company_id, market):
    jobs = [(b, a) for b in _brands(session, company_id) for a in SOCIAL_ANGLES]

    def one(ba):
        b, angle = ba
        try:
            return _social_one(b, angle)
        except Exception:  # noqa: BLE001
            return []

    def _social_one(b, angle):
        r = _req("POST", "/v1/search", body={"query": f"{b['name']} {angle}".strip(), "include_domains": ["reddit.com"],
                                              "search_depth": "lite", "max_results": 20, "time_range": "year"}, timeout=60)
        if r.status_code != 200:
            return []
        return [[company_id, b["id"], x.get("title"), x.get("description"), x.get("url"), _now()]
                for x in r.json().get("results", []) if "/comments/" in (x.get("url") or "")]
    with ThreadPoolExecutor(8) as ex:
        rows, seen = [], set()
        for batch in ex.map(one, jobs):
            for r in batch:
                if (r[1], r[4]) not in seen:
                    seen.add((r[1], r[4]))
                    rows.append(r)
    return _insert(session, "RAW_SOCIAL", ["company_id", "brand_id", "title", "description", "url", "fetched_at"], rows)


def collect_maps_places(session, company_id, market, location_word):
    jobs = [(b, m) for b in _brands(session, company_id) for m in METROS]

    def one(bm):
        b, metro = bm
        ents = _serp({"search_engine": "google_maps_search", "query": f"{b['name']} {location_word} {metro}", "country": market}, timeout=150)
        out = []
        for x in ents.get("SearchResult", []) or []:
            title = (x.get("title") or "").lower()
            if x.get("sponsored") or not any(a in title for a in b["aliases"]):
                continue
            rs = x.get("review_summary") or {}
            out.append([company_id, b["id"], metro, x.get("place_id"), x.get("title"), x.get("address"),
                        rs.get("overall_rating") or x.get("rating"), rs.get("review_count") or x.get("number_of_reviews"),
                        rs.get("ratings_count") or {}, x.get("place_url"), _now()])
        return out
    with ThreadPoolExecutor(10) as ex:
        rows, seen = [], set()
        for batch in ex.map(one, jobs):
            for r in batch:
                if r[3] and r[3] not in seen:
                    seen.add(r[3])
                    rows.append(r)
    for r in rows:
        try:
            r[6] = float(str(r[6]).split()[0]) if r[6] is not None else None
        except ValueError:
            r[6] = None
    return _insert(session, "RAW_MAPS_PLACES", ["company_id", "brand_id", "metro", "place_id", "place_name", "address",
                                                "rating", "review_count", "stars:v", "url", "fetched_at"], rows)


def collect_maps_reviews(session, company_id, market):
    places = _q(session, f"""SELECT brand_id, metro, place_id FROM {DB}.RAW_MAPS_PLACES WHERE company_id = ?
        QUALIFY ROW_NUMBER() OVER (PARTITION BY brand_id, metro ORDER BY review_count DESC NULLS LAST) <= 3""", [company_id])

    def one(p):
        ents = _serp({"search_engine": "google_maps_reviews", "place_id": p["PLACE_ID"], "country": market}, timeout=150)
        return [[company_id, p["BRAND_ID"], p["METRO"], p["PLACE_ID"], v.get("review_id"), v.get("rating"),
                 (v.get("description") or "").replace("\n", " ").strip(), v.get("relative_time"), v.get("review_maps_link"), _now()]
                for v in ents.get("Review", []) or [] if v.get("description")]
    with ThreadPoolExecutor(10) as ex:
        rows = [r for batch in ex.map(one, places) for r in batch]
    return _insert(session, "RAW_MAPS_REVIEWS", ["company_id", "brand_id", "metro", "place_id", "review_id", "rating",
                                                 "text", "relative_time", "url", "fetched_at"], rows)


SYNC_TABLES = {"serp": "RAW_SERP", "news": "RAW_NEWS", "social": "RAW_SOCIAL",
               "maps_places": "RAW_MAPS_PLACES", "maps_reviews": "RAW_MAPS_REVIEWS"}


def _run_sync(session, job, company):
    step, cid, market = job["STEP"], job["COMPANY_ID"], company["MARKET"]
    if step in SYNC_TABLES:  # a retried step replaces its rows, so a partial first attempt never double-counts
        _q(session, f"DELETE FROM {DB}.{SYNC_TABLES[step]} WHERE company_id = ?", [cid])
    if step == "serp":
        return collect_serp(session, cid, market)
    if step == "news":
        return collect_news(session, cid, market)
    if step == "social":
        return collect_social(session, cid, market)
    if step == "maps_places":
        n = collect_maps_places(session, cid, market, company["LOCATION_WORD"] or "store")
        _job(session, cid, "maps_reviews", "sync", "maps_reviews")
        return n
    if step == "maps_reviews":
        return collect_maps_reviews(session, cid, market)
    raise ValueError("unknown step " + step)


# ------------------------------------------------------------------ BUILD
THEMES = [("price_value", "prices, deals, plans or value for money"),
          ("product_quality", "the product or service itself"),
          ("customer_service", "helpfulness, problem resolution, rudeness or sales pressure of staff"),
          ("digital_experience", "the mobile app, website or online account"),
          ("reliability", "outages, coverage, errors, things not working"),
          ("fees_billing", "fees, charges, bills or refunds"),
          ("speed_wait", "waiting time, queues, slow service or appointments"),
          ("staff_location", "the store or branch itself: named staff, hours, cleanliness, parking"),
          ("trust_security", "fraud, security, account freezes, feeling misled or scammed")]


def build(session, company_id):
    labels = "ARRAY_CONSTRUCT(" + ",".join(f"OBJECT_CONSTRUCT('label','{k}','description','{d}')" for k, d in THEMES) + ")"
    cats = "[" + ",".join(f"'{k}'" for k, _ in THEMES) + "]"
    task = "OBJECT_CONSTRUCT('output_mode','multi','task_description','Which topics does this customer text about a brand talk about?')"
    for t in ["REVIEWS_ENRICHED", "SOCIAL_ENRICHED", "NEWS_ENRICHED"]:
        _q(session, f"DELETE FROM {DB}.{t} WHERE company_id = ?", [company_id])
    _q(session, f"""INSERT INTO {DB}.REVIEWS_ENRICHED
        SELECT company_id, brand_id, metro, place_id, review_id, rating, text, url,
               AI_CLASSIFY(text, {labels}, {task}):labels, AI_SENTIMENT(text, {cats}), CURRENT_TIMESTAMP()
        FROM {DB}.RAW_MAPS_REVIEWS WHERE company_id = ?""", [company_id])
    _q(session, f"""INSERT INTO {DB}.SOCIAL_ENRICHED
        SELECT company_id, brand_id, title, description, url,
               AI_CLASSIFY(title || '. ' || COALESCE(description, ''), {labels}, {task}):labels,
               AI_SENTIMENT(title || '. ' || COALESCE(description, ''), {cats}), CURRENT_TIMESTAMP()
        FROM {DB}.RAW_SOCIAL WHERE company_id = ?""", [company_id])
    _q(session, f"""INSERT INTO {DB}.NEWS_ENRICHED
        SELECT company_id, brand_id, title, source, published, url,
               AI_SENTIMENT(title):categories[0]:sentiment::STRING, CURRENT_TIMESTAMP()
        FROM {DB}.RAW_NEWS WHERE company_id = ? AND published >= DATEADD(day, -90, CURRENT_DATE())""", [company_id])
    _q(session, f"UPDATE {DB}.COMPANIES SET status = 'ready', ready_at = CURRENT_TIMESTAMP() WHERE company_id = ?", [company_id])
    return {"company_id": company_id, "status": "ready"}


# ------------------------------------------------------------------ POLL
def poll(session):
    budget_seconds = 480
    t0 = time.time()
    log = {"checked": 0, "done": 0, "failed": 0, "sync": [], "fan_out": [], "built": []}
    open_jobs = _q(session, f"SELECT * FROM {DB}.JOBS WHERE status = 'running' AND kind IN ('wsa', 'llm')")
    with ThreadPoolExecutor(16) as ex:
        checks = list(ex.map(_check_remote, open_jobs))
    for job, (st, content, err) in zip(open_jobs, checks):
        log["checked"] += 1
        if st == "done":
            try:
                _store_remote(session, job, content)
                _set_job(session, job["JOB_ID"], "done")
                log["done"] += 1
            except Exception as e:  # noqa: BLE001
                _retry(session, job, str(e)[:150])
        elif st == "failed":
            _retry(session, job, err or "failed")
            log["failed"] += 1
    companies = {r["COMPANY_ID"]: r for r in _q(session, f"SELECT * FROM {DB}.COMPANIES WHERE status IN ('brief', 'collecting')")}
    for cid, c in companies.items():
        if c["STATUS"] == "brief":
            ab = _q(session, f"SELECT status FROM {DB}.JOBS WHERE company_id = ? AND label = 'ab'", [cid])
            if ab and ab[0]["STATUS"] == "done":
                try:
                    fan_out(session, cid)
                    log["fan_out"].append(cid)
                except Exception as e:  # noqa: BLE001
                    _q(session, f"UPDATE {DB}.COMPANIES SET error = ? WHERE company_id = ?", [f"fan-out: {str(e)[:250]}", cid])
            elif ab and ab[0]["STATUS"] == "failed":
                _q(session, f"UPDATE {DB}.COMPANIES SET status = 'failed', error = 'account brief failed' WHERE company_id = ?", [cid])
    companies = {r["COMPANY_ID"]: r for r in _q(session, f"SELECT * FROM {DB}.COMPANIES WHERE status = 'collecting'")}
    for job in _q(session, f"SELECT * FROM {DB}.JOBS WHERE status = 'queued' AND kind = 'sync' ORDER BY created_at"):
        if time.time() - t0 > budget_seconds or job["COMPANY_ID"] not in companies:
            continue
        _set_job(session, job["JOB_ID"], "running")
        try:
            n = _run_sync(session, job, companies[job["COMPANY_ID"]])
            _set_job(session, job["JOB_ID"], "done", f"{n} rows")
            log["sync"].append(f"{job['COMPANY_ID']}:{job['STEP']}={n}")
        except Exception as e:  # noqa: BLE001
            if job["ATTEMPTS"] < MAX_ATTEMPTS:  # retry a failed collector once on the next poll
                _q(session, f"""UPDATE {DB}.JOBS SET status = 'queued', attempts = attempts + 1, error = ?,
                    updated_at = CURRENT_TIMESTAMP() WHERE job_id = ?""", [f"retry after: {str(e)[:250]}", job["JOB_ID"]])
            else:
                _set_job(session, job["JOB_ID"], "failed", str(e)[:300])
    for cid in companies:
        left = _q(session, f"SELECT COUNT(*) AS n FROM {DB}.JOBS WHERE company_id = ? AND status IN ('queued', 'running')", [cid])[0]["N"]
        if left == 0:
            build(session, cid)
            log["built"].append(cid)
    return log
