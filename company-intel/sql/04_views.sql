-- 04_views.sql: every table the dashboard and the Cortex Agent read. All views span all companies.
USE SCHEMA NIMBLE_INTEL.MART;

-- Brands with a normalized host used to attribute search results and citations.
CREATE OR REPLACE VIEW V_BRANDS AS
SELECT company_id, brand_id, brand, is_focal, aliases,
       SPLIT_PART(REGEXP_REPLACE(LOWER(SPLIT_PART(domain, ',', 1)), '^(https?://)?(www\\.)?', ''), '/', 1) AS host
FROM NIMBLE_INTEL.CORE.CFG_BRANDS;

-- A brand can own several sites (domain holds a comma-separated list). Used to attribute results and citations.
CREATE OR REPLACE VIEW V_BRAND_HOSTS AS
SELECT b.company_id, b.brand_id, b.brand, b.is_focal,
       SPLIT_PART(REGEXP_REPLACE(LOWER(TRIM(d.value::STRING)), '^(https?://)?(www\\.)?', ''), '/', 1) AS host
FROM NIMBLE_INTEL.CORE.CFG_BRANDS b, LATERAL FLATTEN(input => SPLIT(b.domain, ',')) d
WHERE TRIM(d.value::STRING) <> '';

CREATE OR REPLACE VIEW V_COMPANIES AS
SELECT c.company_id, c.company, c.domain, c.market, c.industry, c.include_maps, c.status, c.created_at, c.ready_at
FROM NIMBLE_INTEL.CORE.COMPANIES c;

CREATE OR REPLACE VIEW V_JOB_STATUS AS
SELECT j.company_id, c.company, c.status AS company_status, j.step,
       COUNT(*) AS jobs, COUNT_IF(j.status = 'done') AS done, COUNT_IF(j.status = 'running') AS running,
       COUNT_IF(j.status = 'queued') AS queued, COUNT_IF(j.status = 'failed') AS failed,
       MIN(j.created_at) AS started_at, MAX(j.updated_at) AS last_update
FROM NIMBLE_INTEL.CORE.JOBS j JOIN NIMBLE_INTEL.CORE.COMPANIES c ON c.company_id = j.company_id
GROUP BY 1, 2, 3, 4;

-- ------------------------------------------------------------------ account brief sections
CREATE OR REPLACE VIEW V_ACCOUNT_ITEMS AS
SELECT a.company_id, IFF(a.label = 'ab', 'company', SUBSTR(a.label, 5)) AS run_scope, s.key AS section, i.index AS item_index, i.value AS item
FROM NIMBLE_INTEL.CORE.RAW_AGENT a,
     LATERAL FLATTEN(input => a.payload) s,
     LATERAL FLATTEN(input => s.value) i
WHERE a.step IN ('account_brief', 'unit_brief')
  AND NOT CONTAINS(LOWER(i.value::STRING), '"none_found"');

CREATE OR REPLACE VIEW V_ACCOUNT_COMPANY AS
SELECT company_id, item:name::STRING AS name, item:industry::STRING AS industry, item:hq::STRING AS hq,
       TRY_TO_DOUBLE(item:revenue_usd::STRING) AS revenue_usd, item:revenue_period::STRING AS revenue_period,
       TRY_TO_NUMBER(item:employees::STRING) AS employees, item:ticker::STRING AS ticker,
       item:description::STRING AS description, item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'company' AND run_scope = 'company';

CREATE OR REPLACE VIEW V_ACCOUNT_UNITS AS
SELECT company_id, item:name::STRING AS unit, item:description::STRING AS description, item:head::STRING AS head,
       TRY_TO_NUMBER(item:employees::STRING) AS employees, item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'units' AND run_scope = 'company';

CREATE OR REPLACE VIEW V_ACCOUNT_LEADERS AS
SELECT company_id, item:name::STRING AS name, item:title::STRING AS title, item:function::STRING AS function,
       item:unit::STRING AS unit, item:since::STRING AS since, item:linkedin_url::STRING AS linkedin_url, item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'leaders'
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id, LOWER(item:name::STRING) ORDER BY IFF(run_scope = 'company', 0, 1)) = 1;

CREATE OR REPLACE VIEW V_ACCOUNT_STACK AS
SELECT company_id, run_scope, item:vendor::STRING AS vendor, item:layer::STRING AS layer, item:status::STRING AS status,
       item:unit::STRING AS unit, item:evidence_type::STRING AS evidence_type, item:evidence::STRING AS evidence,
       TRY_TO_DATE(item:date::STRING) AS evidence_date, item:source_url::STRING AS source_url,
       CASE
         WHEN LOWER(item:vendor::STRING) LIKE '%snowflake%' THEN 'Snowflake'
         WHEN LOWER(item:vendor::STRING) LIKE '%databricks%' THEN 'Databricks'
         WHEN REGEXP_LIKE(LOWER(item:vendor::STRING), '.*(aws|amazon web services|redshift|amazon emr|s3).*') THEN 'AWS'
         WHEN REGEXP_LIKE(LOWER(item:vendor::STRING), '.*(azure|synapse|fabric).*') THEN 'Microsoft Azure'
         WHEN REGEXP_LIKE(LOWER(item:vendor::STRING), '.*(google cloud|bigquery|gcp|vertex).*') THEN 'Google Cloud'
         WHEN LOWER(item:vendor::STRING) LIKE '%teradata%' THEN 'Teradata'
         WHEN LOWER(item:vendor::STRING) LIKE '%oracle%' THEN 'Oracle'
         WHEN REGEXP_LIKE(LOWER(item:vendor::STRING), '^sap.*| sap .*') THEN 'SAP'
         WHEN LOWER(item:vendor::STRING) LIKE '%salesforce%' THEN 'Salesforce'
         WHEN LOWER(item:vendor::STRING) LIKE '%palantir%' THEN 'Palantir'
         WHEN REGEXP_LIKE(LOWER(item:vendor::STRING), '.*(openai|chatgpt).*') THEN 'OpenAI'
         WHEN LOWER(item:vendor::STRING) LIKE '%nvidia%' THEN 'NVIDIA'
         WHEN LOWER(item:vendor::STRING) LIKE '%tableau%' THEN 'Tableau'
         WHEN LOWER(item:vendor::STRING) LIKE '%power bi%' THEN 'Power BI'
         ELSE TRIM(SPLIT_PART(item:vendor::STRING, '(', 1))
       END AS vendor_group
FROM V_ACCOUNT_ITEMS WHERE section = 'stack';

CREATE OR REPLACE VIEW V_ACCOUNT_STACK_SUMMARY AS
SELECT company_id, vendor_group AS vendor,
       ARRAY_AGG(DISTINCT layer) AS layers,
       ARRAY_AGG(DISTINCT unit) AS units,
       COUNT(*) AS evidence_count,
       DECODE(MIN(DECODE(status, 'in_use', 0, 'migrating_to', 1, 'evaluating', 2, 'migrating_from', 3, 9)),
              0, 'in_use', 1, 'migrating_to', 2, 'evaluating', 3, 'migrating_from', 'unknown') AS status,
       MAX(evidence_date) AS latest_date,
       MAX_BY(evidence, COALESCE(evidence_date, '1900-01-01'::DATE)) AS example,
       MAX_BY(source_url, COALESCE(evidence_date, '1900-01-01'::DATE)) AS source_url
FROM V_ACCOUNT_STACK GROUP BY 1, 2;

CREATE OR REPLACE VIEW V_ACCOUNT_NEWS AS
SELECT company_id, run_scope, TRY_TO_DATE(item:date::STRING) AS event_date, item:type::STRING AS event_type,
       item:headline::STRING AS headline, item:summary::STRING AS summary, item:unit::STRING AS unit, item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'news'
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id, LOWER(LEFT(item:headline::STRING, 40)) ORDER BY IFF(run_scope = 'company', 0, 1)) = 1;

CREATE OR REPLACE VIEW V_ACCOUNT_STRATEGY AS
SELECT company_id, run_scope, item:initiative::STRING AS initiative, item:summary::STRING AS summary,
       item:data_ai_link::STRING AS data_ai_link, item:unit::STRING AS unit, TRY_TO_DATE(item:date::STRING) AS stated_date,
       item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'strategy'
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id, LOWER(LEFT(item:initiative::STRING, 30)) ORDER BY IFF(run_scope = 'company', 0, 1)) = 1;

CREATE OR REPLACE VIEW V_ACCOUNT_ANGLES AS
SELECT company_id, run_scope, item:angle::STRING AS angle, item:product::STRING AS snowflake_product,
       item:based_on::STRING AS based_on, item:unit::STRING AS unit, item:talking_point::STRING AS talking_point
FROM V_ACCOUNT_ITEMS WHERE section = 'angles';

CREATE OR REPLACE VIEW V_ACCOUNT_RISKS AS
SELECT company_id, run_scope, TRY_TO_DATE(item:date::STRING) AS event_date, item:type::STRING AS risk_type,
       item:severity::STRING AS severity, item:detail::STRING AS detail, item:source_url::STRING AS source_url
FROM V_ACCOUNT_ITEMS WHERE section = 'risks'
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id, LOWER(LEFT(item:detail::STRING, 40)) ORDER BY IFF(run_scope = 'company', 0, 1)) = 1;

-- ------------------------------------------------------------------ brand signal agent sections
CREATE OR REPLACE VIEW V_BRAND_ITEMS AS
SELECT a.company_id, a.brand_id, b.brand, b.is_focal, s.key AS section, i.value AS item
FROM NIMBLE_INTEL.CORE.RAW_AGENT a
JOIN V_BRANDS b ON b.company_id = a.company_id AND b.brand_id = a.brand_id,
     LATERAL FLATTEN(input => a.payload) s,
     LATERAL FLATTEN(input => s.value) i
WHERE a.step = 'brand_scan' AND NOT CONTAINS(LOWER(i.value::STRING), '"none_found"');

CREATE OR REPLACE VIEW V_BRAND_RATINGS AS
SELECT company_id, brand_id, brand, is_focal, item:channel::STRING AS channel, item:profile::STRING AS profile,
       TRY_TO_DOUBLE(item:rating::STRING) AS rating, COALESCE(TRY_TO_DOUBLE(item:scale::STRING), 5) AS scale,
       TRY_TO_DOUBLE(item:rating::STRING) / NULLIF(COALESCE(TRY_TO_DOUBLE(item:scale::STRING), 5), 0) * 5 AS rating_5,
       TRY_TO_NUMBER(item:review_count::STRING) AS review_count, item:source_url::STRING AS source_url
FROM V_BRAND_ITEMS WHERE section = 'ratings' AND TRY_TO_DOUBLE(item:rating::STRING) IS NOT NULL;

CREATE OR REPLACE VIEW V_BRAND_THEMES AS
SELECT company_id, brand_id, brand, is_focal, item:theme::STRING AS theme, item:subtheme::STRING AS subtheme,
       item:sentiment::STRING AS sentiment, item:quote::STRING AS quote, item:channel::STRING AS channel, item:source_url::STRING AS source_url
FROM V_BRAND_ITEMS WHERE section = 'themes';

CREATE OR REPLACE VIEW V_BRAND_SUMMARIES AS
SELECT company_id, brand_id, brand, is_focal, item:channel::STRING AS channel, item:ai_summary::STRING AS ai_summary, item:source_url::STRING AS source_url
FROM V_BRAND_ITEMS WHERE section = 'summaries';

CREATE OR REPLACE VIEW V_BRAND_MOVES AS
SELECT company_id, brand_id, brand, is_focal, TRY_TO_DATE(item:date::STRING) AS move_date, item:type::STRING AS move_type,
       item:headline::STRING AS headline, item:source_url::STRING AS source_url
FROM V_BRAND_ITEMS WHERE section = 'moves';

CREATE OR REPLACE VIEW V_BRAND_RISKS AS
SELECT company_id, brand_id, brand, is_focal, TRY_TO_DATE(item:date::STRING) AS event_date, item:type::STRING AS risk_type,
       item:severity::STRING AS severity, item:detail::STRING AS detail, item:source_url::STRING AS source_url
FROM V_BRAND_ITEMS WHERE section = 'risks';

-- ------------------------------------------------------------------ AI answers (ChatGPT, Gemini, Google AI Overview)
CREATE OR REPLACE VIEW V_AI_ANSWERS AS
SELECT company_id, engine, prompt_id, prompt, answer, sources
FROM NIMBLE_INTEL.CORE.RAW_LLM
UNION ALL
SELECT s.company_id, 'google_ai_overview', NULL, s.query,
       ARRAY_TO_STRING(TRANSFORM(s.entities:AIOverview[0]:blocks, x -> x:content::STRING), '\n'), NULL
FROM NIMBLE_INTEL.CORE.RAW_SERP s
WHERE s.query_type = 'prompt' AND s.entities:AIOverview IS NOT NULL;

-- One row per answer and brand. Text and aliases are normalized to spaced lowercase tokens before matching.
CREATE OR REPLACE VIEW V_AI_MENTIONS AS
WITH a AS (
  SELECT company_id, engine, prompt, ' ' || REGEXP_REPLACE(LOWER(answer), '[^a-z0-9&+]+', ' ') || ' ' AS norm FROM V_AI_ANSWERS
), m AS (
  SELECT a.company_id, a.engine, a.prompt, b.brand_id, b.brand, b.is_focal,
         MIN(NULLIF(POSITION(' ' || TRIM(REGEXP_REPLACE(LOWER(al.value::STRING), '[^a-z0-9&+]+', ' ')) || ' ' IN a.norm), 0)) AS first_pos
  FROM a JOIN V_BRANDS b ON b.company_id = a.company_id, LATERAL FLATTEN(input => b.aliases) al
  GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT m.*, first_pos IS NOT NULL AS mentioned,
       IFF(first_pos IS NULL, NULL, RANK() OVER (PARTITION BY company_id, engine, prompt ORDER BY first_pos NULLS LAST)) AS mention_rank
FROM m;

CREATE OR REPLACE VIEW V_AI_CITATIONS AS
SELECT a.company_id, a.engine, a.prompt, s.value:url::STRING AS url,
       REGEXP_SUBSTR(LOWER(s.value:url::STRING), '^https?://(www\\.)?([^/:?#]+)', 1, 1, 'e', 2) AS cited_host
FROM V_AI_ANSWERS a, LATERAL FLATTEN(input => a.sources) s
WHERE a.sources IS NOT NULL;

CREATE OR REPLACE VIEW V_AI_TOP_SOURCES AS
SELECT company_id, engine, cited_host, COUNT(*) AS citations,
       COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY company_id, engine) * 100 AS share_pct
FROM V_AI_CITATIONS WHERE cited_host IS NOT NULL GROUP BY 1, 2, 3;

-- ------------------------------------------------------------------ Google search: organic, paid ads, AI Overview
CREATE OR REPLACE VIEW V_SERP_RESULTS AS
SELECT s.company_id, s.query_type, s.query, r.value:entity_type::STRING AS result_type, r.value:position::INT AS position,
       r.value:title::STRING AS title,
       COALESCE(REGEXP_SUBSTR(LOWER(r.value:displayed_url::STRING), 'https?://(www\\.)?([^ /›]+)', 1, 1, 'e', 2),
                REGEXP_SUBSTR(LOWER(r.value:url::STRING), '^https?://(www\\.)?([^/:?#]+)', 1, 1, 'e', 2)) AS result_host
FROM NIMBLE_INTEL.CORE.RAW_SERP s,
     LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(s.entities:OrganicResult, []), COALESCE(s.entities:Ad, []))) r;

CREATE OR REPLACE VIEW V_SERP_ATTRIBUTED AS
SELECT r.*, b.brand_id, b.brand, b.is_focal
FROM V_SERP_RESULTS r
LEFT JOIN V_BRAND_HOSTS b ON b.company_id = r.company_id AND b.host <> ''
  AND (r.result_host = b.host OR ENDSWITH(r.result_host, '.' || b.host))
QUALIFY ROW_NUMBER() OVER (PARTITION BY r.company_id, r.query, r.result_type, r.position, r.title ORDER BY b.brand_id NULLS LAST) = 1;

-- ------------------------------------------------------------------ long-format metrics
CREATE OR REPLACE VIEW V_METRICS AS
WITH b AS (SELECT company_id, brand_id, brand, is_focal FROM V_BRANDS),
ai AS (
  SELECT company_id, brand_id, engine,
         COUNT_IF(mentioned) / NULLIF(COUNT(*), 0) * 100 AS share,
         COUNT_IF(mention_rank = 1) / NULLIF(COUNT(*), 0) * 100 AS first_share,
         AVG(mention_rank) AS avg_rank, COUNT(*) AS answers
  FROM V_AI_MENTIONS GROUP BY 1, 2, 3
),
cit AS (
  SELECT c.company_id, b.brand_id, c.engine,
         COUNT_IF(EXISTS_HOST) / NULLIF(COUNT(*), 0) * 100 AS share
  FROM (SELECT c.company_id, c.engine, c.url, b.brand_id,
               MAX(IFF(c.cited_host = h.host OR ENDSWITH(c.cited_host, '.' || h.host), 1, 0)) = 1 AS EXISTS_HOST
        FROM V_AI_CITATIONS c JOIN V_BRANDS b ON b.company_id = c.company_id
        LEFT JOIN V_BRAND_HOSTS h ON h.company_id = b.company_id AND h.brand_id = b.brand_id
        GROUP BY 1, 2, 3, 4) c
  JOIN V_BRANDS b ON b.company_id = c.company_id AND b.brand_id = c.brand_id GROUP BY 1, 2, 3
),
org AS (
  SELECT r.company_id, b.brand_id,
         COUNT_IF(r.brand_id = b.brand_id) / NULLIF(COUNT(*), 0) * 100 AS top10_share,
         COUNT(DISTINCT IFF(r.brand_id = b.brand_id, r.query, NULL)) / NULLIF(COUNT(DISTINCT r.query), 0) * 100 AS coverage,
         AVG(IFF(r.brand_id = b.brand_id, r.position, NULL)) AS avg_position
  FROM V_SERP_ATTRIBUTED r JOIN V_BRANDS b ON b.company_id = r.company_id
  WHERE r.result_type = 'OrganicResult' AND r.query_type = 'keyword'
  GROUP BY 1, 2
),
ads AS (
  SELECT r.company_id, b.brand_id,
         COUNT_IF(r.brand_id = b.brand_id) AS brand_ads, COUNT(*) AS all_ads
  FROM V_SERP_ATTRIBUTED r JOIN V_BRANDS b ON b.company_id = r.company_id
  WHERE r.result_type = 'Ad' GROUP BY 1, 2
),
aio AS (
  SELECT company_id, COUNT_IF(entities:AIOverview IS NOT NULL) / NULLIF(COUNT(*), 0) * 100 AS rate
  FROM NIMBLE_INTEL.CORE.RAW_SERP GROUP BY 1
),
news AS (
  SELECT company_id, brand_id, COUNT(*) AS n,
         COUNT(*) / GREATEST(DATEDIFF(day, MIN(published), MAX(published)) + 1, 1) AS per_day,
         (COUNT_IF(sentiment = 'positive') - COUNT_IF(sentiment = 'negative')) / NULLIF(COUNT(*), 0) * 100 AS net
  FROM NIMBLE_INTEL.CORE.NEWS_ENRICHED GROUP BY 1, 2
),
social AS (
  SELECT company_id, brand_id, COUNT(*) AS n,
         (COUNT_IF(sentiment:categories[0]:sentiment::STRING = 'positive') - COUNT_IF(sentiment:categories[0]:sentiment::STRING = 'negative'))
           / NULLIF(COUNT(*), 0) * 100 AS net
  FROM NIMBLE_INTEL.CORE.SOCIAL_ENRICHED GROUP BY 1, 2
),
apps AS (
  SELECT company_id, brand_id, SUM(rating_5 * COALESCE(review_count, 1)) / NULLIF(SUM(COALESCE(review_count, 1)), 0) AS v
  FROM V_BRAND_RATINGS WHERE channel IN ('app_store', 'google_play') GROUP BY 1, 2
),
sites AS (
  SELECT company_id, brand_id, AVG(rating_5) AS v
  FROM V_BRAND_RATINGS WHERE channel NOT IN ('app_store', 'google_play', 'glassdoor') GROUP BY 1, 2
),
locs AS (
  SELECT company_id, brand_id, AVG(rating) AS v, COUNT(*) AS n, COUNT_IF(rating < 3.5) / COUNT(*) * 100 AS below,
         SUM(COALESCE(stars:"1"::INT, 0) + COALESCE(stars:"2"::INT, 0)) / NULLIF(SUM(IFF(stars:"1" IS NULL, 0, review_count)), 0) * 100 AS neg
  FROM NIMBLE_INTEL.CORE.RAW_MAPS_PLACES WHERE rating IS NOT NULL GROUP BY 1, 2
),
rev AS (
  SELECT company_id, brand_id, COUNT(*) AS n,
         (COUNT_IF(sentiment:categories[0]:sentiment::STRING = 'positive') - COUNT_IF(sentiment:categories[0]:sentiment::STRING = 'negative'))
           / NULLIF(COUNT(*), 0) * 100 AS net
  FROM NIMBLE_INTEL.CORE.REVIEWS_ENRICHED GROUP BY 1, 2
),
risk AS (
  SELECT company_id, brand_id,
         SUM(IFF(event_date >= DATEADD(day, -90, CURRENT_DATE()), DECODE(severity, 'high', 3, 'medium', 2, 1), 0)) AS idx
  FROM V_BRAND_RISKS GROUP BY 1, 2
),
mv AS (
  SELECT company_id, brand_id, COUNT_IF(move_date >= DATEADD(day, -90, CURRENT_DATE())) AS n90,
         COUNT_IF(move_type = 'campaign' AND move_date >= DATEADD(day, -90, CURRENT_DATE())) AS c90
  FROM V_BRAND_MOVES GROUP BY 1, 2
),
long AS (
  SELECT company_id, brand_id, 'share_of_ai_answer_pct' AS metric, engine AS dimension, share AS value, answers || ' answers' AS basis FROM ai
  UNION ALL SELECT company_id, brand_id, 'ai_first_mention_pct', engine, first_share, answers || ' answers' FROM ai
  UNION ALL SELECT company_id, brand_id, 'ai_avg_mention_rank', engine, avg_rank, 'rank among brands named in the answer' FROM ai
  UNION ALL SELECT company_id, brand_id, 'ai_citation_share_pct', engine, share, 'share of cited links on the brand site' FROM cit
  UNION ALL SELECT company_id, brand_id, 'search_top10_share_pct', '', top10_share, 'organic top-10 results on category keywords' FROM org
  UNION ALL SELECT company_id, brand_id, 'search_keyword_coverage_pct', '', coverage, 'keywords where the brand ranks in the top 10' FROM org
  UNION ALL SELECT company_id, brand_id, 'search_avg_position', '', avg_position, 'average organic position when ranked' FROM org
  UNION ALL SELECT company_id, brand_id, 'paid_ad_share_pct', '', brand_ads / NULLIF(all_ads, 0) * 100, all_ads || ' paid results seen' FROM ads
  UNION ALL SELECT company_id, brand_id, 'paid_ads_seen', '', brand_ads, 'paid Google results on category queries' FROM ads
  UNION ALL SELECT a.company_id, b.brand_id, 'ai_overview_rate_pct', '', a.rate, 'share of Google queries showing an AI Overview' FROM aio a JOIN b ON b.company_id = a.company_id AND b.is_focal
  UNION ALL SELECT company_id, brand_id, 'news_per_day', '', per_day, n || ' Google News articles' FROM news
  UNION ALL SELECT company_id, brand_id, 'news_net_sentiment_pct', '', net, n || ' headlines, Cortex AI_SENTIMENT' FROM news
  UNION ALL SELECT company_id, brand_id, 'reddit_threads', '', n, 'threads found in the last 12 months (sample)' FROM social
  UNION ALL SELECT company_id, brand_id, 'reddit_net_sentiment_pct', '', net, n || ' threads, Cortex AI_SENTIMENT' FROM social
  UNION ALL SELECT company_id, brand_id, 'app_rating', '', v, 'App Store and Google Play, weighted by ratings' FROM apps
  UNION ALL SELECT company_id, brand_id, 'review_site_rating', '', v, 'Trustpilot, Yelp, BBB and similar' FROM sites
  UNION ALL SELECT company_id, brand_id, 'location_rating', '', v, n || ' Google Maps locations' FROM locs
  UNION ALL SELECT company_id, brand_id, 'pct_locations_below_3_5', '', below, n || ' Google Maps locations' FROM locs
  UNION ALL SELECT company_id, brand_id, 'pct_negative_location_reviews', '', neg, '1 and 2 star share of location reviews' FROM locs
  UNION ALL SELECT company_id, brand_id, 'review_net_sentiment_pct', '', net, n || ' Google Maps reviews, Cortex AI_SENTIMENT' FROM rev
  UNION ALL SELECT company_id, brand_id, 'risk_index_90d', '', idx, 'high 3, medium 2, low 1' FROM risk
  UNION ALL SELECT company_id, brand_id, 'moves_90d', '', n90, 'market moves found by the agent' FROM mv
  UNION ALL SELECT company_id, brand_id, 'campaigns_90d', '', c90, 'campaign launches found by the agent' FROM mv
)
SELECT l.company_id, l.brand_id, b.brand, b.is_focal, l.metric, l.dimension, l.value, l.basis
FROM long l JOIN b ON b.company_id = l.company_id AND b.brand_id = l.brand_id
UNION ALL
SELECT r.company_id, r.brand_id, b.brand, b.is_focal, 'reputation_score', '', AVG(r.v), COUNT(*) || ' channel groups (apps, review sites, locations)'
FROM (SELECT company_id, brand_id, v FROM apps UNION ALL SELECT company_id, brand_id, v FROM sites UNION ALL SELECT company_id, brand_id, v FROM locs) r
JOIN b ON b.company_id = r.company_id AND b.brand_id = r.brand_id
GROUP BY 1, 2, 3, 4;

-- Share of voice: each brand's news rate divided by the sum across the company's brands.
CREATE OR REPLACE VIEW V_SHARE_OF_VOICE AS
SELECT company_id, brand_id, brand, is_focal, value AS news_per_day,
       value / NULLIF(SUM(value) OVER (PARTITION BY company_id), 0) * 100 AS share_of_voice_pct
FROM V_METRICS WHERE metric = 'news_per_day';

-- Review and Reddit themes, one row per text and theme, keeping only themes AI_CLASSIFY found.
CREATE OR REPLACE VIEW V_THEME_MENTIONS AS
SELECT e.company_id, e.brand_id, 'google_maps' AS source, e.review_id AS item_id, t.value::STRING AS theme,
       COALESCE(s.value:sentiment::STRING, 'unknown') AS sentiment, e.text, e.url
FROM NIMBLE_INTEL.CORE.REVIEWS_ENRICHED e, LATERAL FLATTEN(input => e.themes) t, LATERAL FLATTEN(input => e.sentiment:categories) s
WHERE s.value:name::STRING = t.value::STRING
UNION ALL
SELECT e.company_id, e.brand_id, 'reddit', e.url, t.value::STRING, COALESCE(s.value:sentiment::STRING, 'unknown'),
       e.title || '. ' || COALESCE(e.description, ''), e.url
FROM NIMBLE_INTEL.CORE.SOCIAL_ENRICHED e, LATERAL FLATTEN(input => e.themes) t, LATERAL FLATTEN(input => e.sentiment:categories) s
WHERE s.value:name::STRING = t.value::STRING;

CREATE OR REPLACE VIEW V_THEME_SCORES AS
SELECT m.company_id, m.brand_id, b.brand, b.is_focal, m.source, m.theme, COUNT(*) AS mentions,
       (COUNT_IF(m.sentiment = 'positive') - COUNT_IF(m.sentiment = 'negative')) / COUNT(*) * 100 AS net_sentiment
FROM V_THEME_MENTIONS m JOIN V_BRANDS b ON b.company_id = m.company_id AND b.brand_id = m.brand_id
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE OR REPLACE VIEW V_THEME_GAPS AS
SELECT f.company_id, f.brand_id, f.brand, f.source, f.theme, f.mentions, f.net_sentiment,
       AVG(r.net_sentiment) AS rivals_net_sentiment, f.net_sentiment - AVG(r.net_sentiment) AS gap
FROM V_THEME_SCORES f JOIN V_THEME_SCORES r
  ON r.company_id = f.company_id AND r.source = f.source AND r.theme = f.theme AND NOT r.is_focal AND r.mentions >= 10
WHERE f.is_focal AND f.mentions >= 10
GROUP BY 1, 2, 3, 4, 5, 6, 7;

-- One representative quote per brand, source, theme and sentiment (closest to 160 characters).
CREATE OR REPLACE VIEW V_THEME_QUOTES AS
SELECT company_id, brand_id, source, theme, sentiment, LEFT(text, 220) AS quote, url
FROM V_THEME_MENTIONS WHERE LENGTH(text) >= 40
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id, brand_id, source, theme, sentiment ORDER BY ABS(LENGTH(text) - 160)) = 1;

-- ------------------------------------------------------------------ insight cards (fixed rules, so the same data gives the same cards)
CREATE OR REPLACE VIEW V_INSIGHTS AS
WITH m AS (SELECT * FROM V_METRICS),
focal AS (SELECT company_id, brand FROM V_BRANDS WHERE is_focal),
ai AS (
  SELECT company_id, dimension AS engine, brand, is_focal, value,
         ROW_NUMBER() OVER (PARTITION BY company_id, dimension ORDER BY value DESC) AS rk
  FROM m WHERE metric = 'share_of_ai_answer_pct'
),
eng AS (SELECT engine, DECODE(engine, 'chatgpt', 'ChatGPT', 'gemini', 'Gemini', 'google_ai_overview', 'Google AI Overviews', engine) AS label FROM (SELECT DISTINCT engine FROM ai))
SELECT a.company_id, 'ai_visibility' AS area, IFF(f.value >= a.value, 'opportunity', 'risk') AS tag,
       e.label || ' names ' || f.brand || ' in ' || ROUND(f.value) || '% of category answers, against ' || ROUND(a.value) || '% for ' || a.brand AS headline,
       'share_of_ai_answer_pct[' || a.engine || ']' AS metric, NULL AS quote, NULL AS source_url
FROM ai a JOIN ai f ON f.company_id = a.company_id AND f.engine = a.engine AND f.is_focal
JOIN eng e ON e.engine = a.engine
WHERE a.rk = 1 AND NOT a.is_focal
UNION ALL
SELECT a.company_id, 'ai_visibility', 'trend',
       e.label || ' names ' || a.brand || ' first in ' || ROUND(a.value) || '% of category answers, more than any rival',
       'ai_first_mention_pct[' || a.engine || ']', NULL, NULL
FROM (SELECT company_id, dimension AS engine, brand, is_focal, value,
             ROW_NUMBER() OVER (PARTITION BY company_id, dimension ORDER BY value DESC) AS rk
      FROM m WHERE metric = 'ai_first_mention_pct') a JOIN eng e ON e.engine = a.engine
WHERE a.rk = 1 AND a.is_focal
UNION ALL
SELECT s.company_id, 'search', IFF(s.value >= l.value, 'opportunity', 'risk'),
       s.brand || ' holds ' || TO_VARCHAR(ROUND(s.value, 1)) || '% of organic top-10 results on category searches, against ' || TO_VARCHAR(ROUND(l.value, 1)) || '% for ' || l.brand,
       'search_top10_share_pct', NULL, NULL
FROM m s JOIN (SELECT company_id, brand, value FROM m WHERE metric = 'search_top10_share_pct' AND NOT is_focal
               QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY value DESC) = 1) l ON l.company_id = s.company_id
WHERE s.metric = 'search_top10_share_pct' AND s.is_focal
UNION ALL
SELECT company_id, 'ads', 'competitor',
       brand || ' bought ' || ROUND(value) || ' of the paid Google results seen on category searches, the most of any brand',
       'paid_ads_seen', NULL, NULL
FROM m WHERE metric = 'paid_ads_seen' AND value > 0
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY value DESC) = 1
UNION ALL
SELECT company_id, 'share_of_voice', IFF(share_of_voice_pct >= 25, 'trend', 'risk'),
       brand || ' gets ' || ROUND(share_of_voice_pct) || '% of news coverage among its brand set, at ' || ROUND(news_per_day, 1) || ' articles a day',
       'share_of_voice_pct', NULL, NULL
FROM V_SHARE_OF_VOICE WHERE is_focal
UNION ALL
SELECT g.company_id, 'reviews', 'risk',
       'Customers rate ' || DECODE(g.theme, 'price_value', 'price and value', 'product_quality', 'product quality',
         'customer_service', 'customer service', 'digital_experience', 'the app and website', 'reliability', 'reliability',
         'fees_billing', 'fees and billing', 'speed_wait', 'wait times', 'staff_location', 'stores and branches',
         'trust_security', 'trust and security', REPLACE(g.theme, '_', ' ')) || ' ' || ROUND(ABS(g.gap)) || ' net sentiment points below the rival average in ' ||
       DECODE(g.source, 'google_maps', 'Google Maps reviews', 'Reddit threads'),
       'theme_gap[' || g.theme || ']', q.quote, q.url
FROM V_THEME_GAPS g
LEFT JOIN V_THEME_QUOTES q ON q.company_id = g.company_id AND q.brand_id = g.brand_id AND q.source = g.source
  AND q.theme = g.theme AND q.sentiment = 'negative'
WHERE g.gap < 0
QUALIFY ROW_NUMBER() OVER (PARTITION BY g.company_id ORDER BY g.gap) = 1
UNION ALL
SELECT company_id, 'risk', 'risk', LEFT(detail, 200), 'risk_index_90d', NULL, source_url
FROM V_BRAND_RISKS WHERE is_focal AND severity = 'high'
QUALIFY ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY event_date DESC NULLS LAST) = 1;
