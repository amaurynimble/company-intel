"""Builds the cockpit payload for one company from NIMBLE_INTEL.MART.

build(company_id, q) -> dict, where q(sql, params) returns a list of dicts with lowercase keys.
Used by streamlit_app.py inside Snowflake and by tools that render the cockpit outside it.
"""
from collections import defaultdict
from datetime import date, datetime

M = "NIMBLE_INTEL.MART"
C = "NIMBLE_INTEL.CORE"


def _clean(v):
    if isinstance(v, (date, datetime)):
        return v.isoformat()[:10]
    if hasattr(v, "is_integer") or type(v).__name__ == "Decimal":
        try:
            f = float(v)
            return None if f != f else round(f, 2)
        except (TypeError, ValueError):
            return None
    return v


def _rows(q, sql, params=None):
    return [{k: _clean(v) for k, v in r.items()} for r in q(sql, params or [])]


SECTION_ORDER = ["company", "units", "leaders", "stack", "strategy", "news", "risks"]


def _sources(q, cid):
    """Every page cited by the account brief, deduplicated by URL, with the sections it supports."""
    rows = _rows(q, f"""SELECT section, item:source_url::STRING AS url,
                               COALESCE(item:headline::STRING, item:initiative::STRING, item:vendor::STRING, item:name::STRING,
                                        item:unit::STRING, LEFT(item:detail::STRING, 120)) AS label,
                               COALESCE(item:date::STRING, item:since::STRING) AS d
                        FROM {M}.V_ACCOUNT_ITEMS
                        WHERE company_id = ? AND STARTSWITH(item:source_url::STRING, 'http')""", [cid])
    by_url = {}
    for r in rows:
        u = r["url"].strip()
        s = by_url.setdefault(u, {"url": u, "sections": [], "labels": [], "date": None})
        if r["section"] not in s["sections"]:
            s["sections"].append(r["section"])
        if r["label"] and r["label"] not in s["labels"]:
            s["labels"].append(r["label"])
        d = r["d"] if r["d"] and str(r["d"])[:4].isdigit() else None
        if d and (not s["date"] or d > s["date"]):
            s["date"] = d[:10]
    out = list(by_url.values())
    for s in out:
        s["sections"].sort(key=lambda x: SECTION_ORDER.index(x) if x in SECTION_ORDER else 99)
    out.sort(key=lambda s: (SECTION_ORDER.index(s["sections"][0]) if s["sections"][0] in SECTION_ORDER else 99, s["url"]))
    return out


def build(cid, q):
    co = _rows(q, f"SELECT * FROM {M}.V_COMPANIES WHERE company_id = ?", [cid])
    if not co:
        return {}
    brands = _rows(q, f"SELECT brand_id, brand, is_focal, host FROM {M}.V_BRANDS WHERE company_id = ? ORDER BY is_focal DESC, brand", [cid])
    metrics = _rows(q, f"SELECT brand_id, metric, dimension, value FROM {M}.V_METRICS WHERE company_id = ?", [cid])
    m = defaultdict(dict)
    for r in metrics:
        m[r["brand_id"]][r["metric"] + ("|" + r["dimension"] if r["dimension"] else "")] = r["value"]

    # AI answers: brands named in each answer, in the order they appear
    ai = defaultdict(lambda: defaultdict(list))
    for r in _rows(q, f"""SELECT engine, prompt, brand_id, mention_rank FROM {M}.V_AI_MENTIONS
                          WHERE company_id = ? AND mentioned ORDER BY engine, prompt, mention_rank""", [cid]):
        ai[r["prompt"]][r["engine"]].append(r["brand_id"])
    prompts = [{"prompt": p, "engines": dict(e)} for p, e in sorted(ai.items())]
    asked = _rows(q, f"SELECT DISTINCT engine, prompt FROM {M}.V_AI_ANSWERS WHERE company_id = ?", [cid])
    asked_by_prompt = defaultdict(list)
    for r in asked:
        asked_by_prompt[r["prompt"]].append(r["engine"])
    for p in prompts:
        p["asked"] = sorted(asked_by_prompt.get(p["prompt"], []))
    unanswered = [{"prompt": p, "engines": {}, "asked": sorted(e)} for p, e in asked_by_prompt.items() if p not in ai]
    sources = _rows(q, f"""SELECT cited_host, SUM(citations) AS citations FROM {M}.V_AI_TOP_SOURCES WHERE company_id = ?
                           GROUP BY 1 ORDER BY 2 DESC LIMIT 10""", [cid])

    # Google: best organic position per keyword and brand
    kw = [r["keyword"] for r in _rows(q, f"SELECT keyword FROM {C}.CFG_KEYWORDS WHERE company_id = ? ORDER BY keyword_id", [cid])]
    pos = defaultdict(dict)
    for r in _rows(q, f"""SELECT query, brand_id, MIN(position) AS position FROM {M}.V_SERP_ATTRIBUTED
                          WHERE company_id = ? AND result_type = 'OrganicResult' AND query_type = 'keyword' AND brand_id IS NOT NULL
                          GROUP BY 1, 2""", [cid]):
        pos[r["query"]][r["brand_id"]] = r["position"]
    keywords = [{"keyword": k, "positions": pos.get(k, {})} for k in kw]
    aio = _rows(q, f"""SELECT query, entities:AIOverview IS NOT NULL AS has_aio, ARRAY_SIZE(COALESCE(entities:Ad, [])) AS ads
                       FROM {C}.RAW_SERP WHERE company_id = ? AND query_type = 'keyword'""", [cid])
    for k in keywords:
        hit = next((a for a in aio if a["query"] == k["keyword"]), {})
        k["aio"] = bool(hit.get("has_aio"))
        k["ads"] = hit.get("ads") or 0

    sov = _rows(q, f"SELECT brand_id, share_of_voice_pct, news_per_day FROM {M}.V_SHARE_OF_VOICE WHERE company_id = ?", [cid])
    headlines = _rows(q, f"""SELECT brand_id, title, source, published, url, sentiment FROM {C}.NEWS_ENRICHED
                             WHERE company_id = ? ORDER BY published DESC NULLS LAST LIMIT 16""", [cid])
    moves = _rows(q, f"""SELECT brand_id, move_date, move_type, headline, source_url FROM {M}.V_BRAND_MOVES
                         WHERE company_id = ? AND move_date IS NOT NULL ORDER BY move_date DESC LIMIT 12""", [cid])
    risks = _rows(q, f"""SELECT brand_id, event_date, severity, risk_type, detail, source_url FROM {M}.V_BRAND_RISKS
                         WHERE company_id = ? AND event_date IS NOT NULL ORDER BY event_date DESC LIMIT 10""", [cid])

    ratings = _rows(q, f"""SELECT brand_id, channel, AVG(rating_5) AS rating, SUM(review_count) AS reviews FROM {M}.V_BRAND_RATINGS
                           WHERE company_id = ? AND channel <> 'glassdoor' GROUP BY 1, 2""", [cid])
    themes = _rows(q, f"SELECT brand_id, source, theme, mentions, net_sentiment FROM {M}.V_THEME_SCORES WHERE company_id = ?", [cid])
    metros = _rows(q, f"""SELECT brand_id, metro, AVG(rating) AS rating, COUNT(*) AS locations FROM {C}.RAW_MAPS_PLACES
                          WHERE company_id = ? AND rating IS NOT NULL GROUP BY 1, 2""", [cid])
    focal = next((b["brand_id"] for b in brands if b["is_focal"]), None)
    quotes = _rows(q, f"""SELECT source, theme, sentiment, quote, url FROM {M}.V_THEME_QUOTES
                          WHERE company_id = ? AND brand_id = ? AND sentiment IN ('positive', 'negative')
                          QUALIFY ROW_NUMBER() OVER (PARTITION BY sentiment ORDER BY LENGTH(quote) DESC) <= 4""", [cid, focal])
    summaries = _rows(q, f"SELECT channel, ai_summary, source_url FROM {M}.V_BRAND_SUMMARIES WHERE company_id = ? AND is_focal LIMIT 3", [cid])

    account = {
        "company": (_rows(q, f"SELECT * FROM {M}.V_ACCOUNT_COMPANY WHERE company_id = ?", [cid]) or [{}])[0],
        "units": _rows(q, f"SELECT unit, head, description FROM {M}.V_ACCOUNT_UNITS WHERE company_id = ?", [cid]),
        "leaders": _rows(q, f"""SELECT name, title, function, unit, linkedin_url FROM {M}.V_ACCOUNT_LEADERS WHERE company_id = ?
                                ORDER BY DECODE(function, 'data', 0, 'it', 1, 'marketing', 2, 'digital', 3, 'exec', 4, 5) LIMIT 12""", [cid]),
        "stack": _rows(q, f"""SELECT vendor, status, ARRAY_TO_STRING(layers, ', ') AS layers, ARRAY_TO_STRING(units, ' | ') AS units,
                                     evidence_count, latest_date, example, source_url
                              FROM {M}.V_ACCOUNT_STACK_SUMMARY WHERE company_id = ?
                              ORDER BY vendor IN ('Snowflake', 'Databricks') DESC, evidence_count DESC LIMIT 14""", [cid]),
        "angles": _rows(q, f"SELECT unit, angle, snowflake_product, talking_point FROM {M}.V_ACCOUNT_ANGLES WHERE company_id = ? LIMIT 6", [cid]),
        "events": _rows(q, f"""SELECT event_date, event_type, headline, unit, source_url FROM {M}.V_ACCOUNT_NEWS
                               WHERE company_id = ? AND event_date IS NOT NULL ORDER BY event_date DESC LIMIT 10""", [cid]),
        "strategy": _rows(q, f"SELECT initiative, data_ai_link, unit FROM {M}.V_ACCOUNT_STRATEGY WHERE company_id = ? LIMIT 6", [cid]),
        "sources": _sources(q, cid),
    }
    jobs = _rows(q, f"SELECT step, jobs, done, running, queued, failed FROM {M}.V_JOB_STATUS WHERE company_id = ?", [cid])
    insights = _rows(q, f"SELECT area, tag, headline, quote, source_url FROM {M}.V_INSIGHTS WHERE company_id = ?", [cid])
    return {
        "company": co[0], "brands": brands, "metrics": m, "insights": insights,
        "ai": {"prompts": prompts + unanswered, "sources": sources},
        "search": {"keywords": keywords},
        "voice": {"sov": sov, "headlines": headlines, "moves": moves, "risks": risks},
        "cx": {"ratings": ratings, "themes": themes, "metros": metros, "quotes": quotes, "summaries": summaries},
        "account": account, "jobs": jobs,
    }
