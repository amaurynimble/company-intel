-- 05_semantic_view.sql: the model Cortex Analyst and the agent query. Covers every company in NIMBLE_INTEL.
CREATE OR REPLACE FUNCTION NIMBLE_INTEL.APP.WEB_SEARCH(QUERY STRING, FOCUS STRING)
  RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11' PACKAGES = ('requests') HANDLER = 'main'
  EXTERNAL_ACCESS_INTEGRATIONS = (NIMBLE_INTEL_ACCESS) SECRETS = ('nimble_key' = NIMBLE_INTEL.CORE.NIMBLE_KEY)
  COMMENT = 'Live web search through Nimble, used by the company intelligence agent'
AS
'
import _snowflake, requests
def main(query, focus):
    body = {"query": query, "max_results": 8, "search_depth": "lite"}
    if focus and focus != "general":
        body["focus"] = focus
    r = requests.post("https://sdk.nimbleway.com/v1/search", json=body, timeout=60,
                      headers={"Authorization": "Bearer " + _snowflake.get_generic_secret_string("nimble_key"),
                               "X-Client-Source": "snowflake-company-intel"})
    if r.status_code != 200:
        return {"error": r.status_code}
    return [{"title": x.get("title"), "url": x.get("url"), "snippet": (x.get("description") or "")[:400],
             "date": (x.get("additional_data") or {}).get("publish_date")} for x in r.json().get("results", [])]
';

CREATE OR REPLACE SEMANTIC VIEW NIMBLE_INTEL.APP.COMPANY_INTEL_SV
  tables (
    METRICS as NIMBLE_INTEL.MART.V_METRICS
      with synonyms=('brand metrics','kpis','scores','signals')
      comment='One row per company, brand, metric and dimension. Metrics: share_of_ai_answer_pct, ai_first_mention_pct, ai_citation_share_pct (dimension = engine: chatgpt, gemini, google_ai_overview), search_top10_share_pct, search_keyword_coverage_pct, search_avg_position, paid_ad_share_pct, paid_ads_seen, ai_overview_rate_pct, news_per_day, news_net_sentiment_pct, reddit_threads, reddit_net_sentiment_pct, app_rating, review_site_rating, location_rating, reputation_score, pct_locations_below_3_5, pct_negative_location_reviews, review_net_sentiment_pct, risk_index_90d, moves_90d, campaigns_90d. is_focal is true for the researched company and false for its rivals.',
    VOICE as NIMBLE_INTEL.MART.V_SHARE_OF_VOICE
      with synonyms=('share of voice','news coverage','media share')
      comment='Share of news coverage per brand within the company and its rivals, from Google News over the last 90 days.',
    THEMES as NIMBLE_INTEL.MART.V_THEME_SCORES
      with synonyms=('review themes','complaints','what customers say','sentiment by topic')
      comment='Customer themes from Google Maps reviews and Reddit threads, classified by Cortex. net_sentiment runs from -100 to +100.',
    QUOTES as NIMBLE_INTEL.MART.V_THEME_MENTIONS
      with synonyms=('reviews','customer quotes','reddit posts','review text')
      comment='One row per review or Reddit thread and theme, with the text and its sentiment.',
    AI as NIMBLE_INTEL.MART.V_AI_MENTIONS
      with synonyms=('ai answers','chatgpt answers','gemini answers','llm visibility')
      comment='One row per AI answer and brand: whether the brand is named and its rank among brands named in that answer.',
    SOURCES as NIMBLE_INTEL.MART.V_AI_TOP_SOURCES
      with synonyms=('ai sources','citations','cited sites')
      comment='Websites cited by AI answers for the category questions, per engine.',
    STACK as NIMBLE_INTEL.MART.V_ACCOUNT_STACK
      with synonyms=('data stack','tech stack','vendors','cloud','data platform')
      comment='Data, cloud and AI vendors used by the researched company, with the business unit and the evidence. vendor_group normalizes names such as Snowflake, Databricks, AWS, Microsoft Azure, Google Cloud.',
    LEADERS as NIMBLE_INTEL.MART.V_ACCOUNT_LEADERS
      with synonyms=('decision makers','executives','buyers','contacts')
      comment='Executives who buy data, AI, technology and marketing, with title, function and business unit.',
    EVENTS as NIMBLE_INTEL.MART.V_ACCOUNT_NEWS
      with synonyms=('trigger events','company news','earnings','executive changes')
      comment='Trigger events from the last 12 months for the researched company.',
    MOVES as NIMBLE_INTEL.MART.V_BRAND_MOVES
      with synonyms=('competitor moves','launches','campaigns','pricing changes')
      comment='Market moves by the company and its rivals in the last 12 months.',
    RISKS as NIMBLE_INTEL.MART.V_BRAND_RISKS
      with synonyms=('risk events','outages','lawsuits','regulatory actions')
      comment='Risk events by the company and its rivals in the last 12 months, with severity.'
  )
  dimensions (
    METRICS.M_COMPANY as company_id with synonyms=('company','account') comment='Researched company id, such as t_mobile.',
    METRICS.M_BRAND as brand with synonyms=('brand','competitor','rival'),
    METRICS.M_IS_FOCAL as is_focal with synonyms=('our brand','focal brand'),
    METRICS.M_METRIC as metric with synonyms=('kpi','measure'),
    METRICS.M_DIMENSION as dimension with synonyms=('engine','channel') comment='AI engine for AI metrics, empty otherwise.',
    VOICE.V_COMPANY as company_id with synonyms=('company'),
    VOICE.V_BRAND as brand with synonyms=('brand','competitor'),
    THEMES.T_COMPANY as company_id with synonyms=('company'),
    THEMES.T_BRAND as brand with synonyms=('brand','competitor'),
    THEMES.T_SOURCE as source with synonyms=('source','channel') comment='google_maps or reddit.',
    THEMES.T_THEME as theme with synonyms=('topic','theme') comment='price_value, product_quality, customer_service, digital_experience, reliability, fees_billing, speed_wait, staff_location, trust_security.',
    QUOTES.Q_COMPANY as company_id with synonyms=('company'),
    QUOTES.Q_BRAND_ID as brand_id with synonyms=('brand'),
    QUOTES.Q_SOURCE as source with synonyms=('source'),
    QUOTES.Q_THEME as theme with synonyms=('topic'),
    QUOTES.Q_SENTIMENT as sentiment with synonyms=('tone') comment='positive, negative, mixed or neutral.',
    QUOTES.Q_TEXT as text with synonyms=('quote','review text'),
    AI.A_COMPANY as company_id with synonyms=('company'),
    AI.A_ENGINE as engine with synonyms=('ai engine','llm','model') comment='chatgpt, gemini or google_ai_overview.',
    AI.A_PROMPT as prompt with synonyms=('question','category question'),
    AI.A_BRAND as brand with synonyms=('brand','competitor'),
    AI.A_MENTIONED as mentioned with synonyms=('named','mentioned'),
    SOURCES.S_COMPANY as company_id with synonyms=('company'),
    SOURCES.S_ENGINE as engine with synonyms=('ai engine'),
    SOURCES.S_HOST as cited_host with synonyms=('website','domain','source site'),
    STACK.K_COMPANY as company_id with synonyms=('company'),
    STACK.K_VENDOR as vendor_group with synonyms=('vendor','platform','tool'),
    STACK.K_LAYER as layer with synonyms=('stack layer') comment='cloud, warehouse, lakehouse, bi, ml_ai, cdp_martech, etl, other.',
    STACK.K_STATUS as status with synonyms=('usage status') comment='in_use, evaluating, migrating_from, migrating_to.',
    STACK.K_UNIT as unit with synonyms=('business unit','division'),
    STACK.K_EVIDENCE as evidence with synonyms=('proof'),
    LEADERS.L_COMPANY as company_id with synonyms=('company'),
    LEADERS.L_NAME as name with synonyms=('person','executive'),
    LEADERS.L_TITLE as title with synonyms=('role','job title'),
    LEADERS.L_FUNCTION as function with synonyms=('department') comment='exec, data, it, marketing, digital, finance, other.',
    LEADERS.L_UNIT as unit with synonyms=('business unit','division'),
    EVENTS.E_COMPANY as company_id with synonyms=('company'),
    EVENTS.E_DATE as event_date with synonyms=('date'),
    EVENTS.E_TYPE as event_type with synonyms=('event type') comment='earnings, exec_change, m_and_a, layoffs, partnership, launch, regulatory, other.',
    EVENTS.E_HEADLINE as headline with synonyms=('event','news'),
    MOVES.MV_COMPANY as company_id with synonyms=('company'),
    MOVES.MV_BRAND as brand with synonyms=('brand','competitor'),
    MOVES.MV_DATE as move_date with synonyms=('date'),
    MOVES.MV_TYPE as move_type with synonyms=('move type') comment='pricing, launch, campaign, partnership, m_and_a, expansion, other.',
    MOVES.MV_HEADLINE as headline with synonyms=('move','launch'),
    RISKS.R_COMPANY as company_id with synonyms=('company'),
    RISKS.R_BRAND as brand with synonyms=('brand','competitor'),
    RISKS.R_DATE as event_date with synonyms=('date'),
    RISKS.R_SEVERITY as severity with synonyms=('severity') comment='high, medium or low.',
    RISKS.R_DETAIL as detail with synonyms=('risk','event')
  )
  metrics (
    METRICS.METRIC_VALUE as AVG(metrics.value) with synonyms=('value','score','rate')
      comment='Value of the metric. Always filter metric (and dimension for AI metrics) before reading it.',
    VOICE.SHARE_OF_VOICE as AVG(voice.share_of_voice_pct) with synonyms=('share of voice','news share'),
    VOICE.NEWS_PER_DAY as AVG(voice.news_per_day) with synonyms=('articles per day','news volume'),
    THEMES.THEME_NET_SENTIMENT as AVG(themes.net_sentiment) with synonyms=('net sentiment','theme sentiment'),
    THEMES.THEME_MENTIONS as SUM(themes.mentions) with synonyms=('mentions','complaint volume'),
    AI.AI_ANSWERS as COUNT(ai.prompt) with synonyms=('answers'),
    AI.AI_SHARE_OF_ANSWER as AVG(IFF(ai.mentioned, 100, 0)) with synonyms=('share of ai answer','ai visibility','mention rate')
      comment='Percent of AI answers that name the brand. Group by engine and brand.',
    SOURCES.CITATIONS as SUM(sources.citations) with synonyms=('citations','times cited'),
    STACK.STACK_EVIDENCE as COUNT(stack.vendor_group) with synonyms=('mentions','evidence count'),
    LEADERS.LEADER_COUNT as COUNT(leaders.name) with synonyms=('number of executives'),
    EVENTS.EVENT_COUNT as COUNT(events.headline) with synonyms=('number of events'),
    MOVES.MOVE_COUNT as COUNT(moves.headline) with synonyms=('number of moves','launch count'),
    RISKS.RISK_COUNT as COUNT(risks.detail) with synonyms=('number of risks')
  );
