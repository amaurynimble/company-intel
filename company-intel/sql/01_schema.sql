-- 01_schema.sql: tables shared by every company. A new company adds rows, never objects.
CREATE SCHEMA IF NOT EXISTS NIMBLE_INTEL.MART;
CREATE SCHEMA IF NOT EXISTS NIMBLE_INTEL.APP;
CREATE STAGE IF NOT EXISTS NIMBLE_INTEL.CORE.CODE;
USE SCHEMA NIMBLE_INTEL.CORE;
CREATE TABLE IF NOT EXISTS CFG_AGENTS (agent_key STRING, agent_name STRING, agent_id STRING, installed_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS COMPANIES (company_id STRING, company STRING, domain STRING, market STRING, include_maps BOOLEAN,
  location_word STRING, industry STRING, status STRING, error STRING, created_at TIMESTAMP_LTZ, ready_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS CFG_BRANDS (company_id STRING, brand_id STRING, brand STRING, domain STRING, is_focal BOOLEAN, aliases VARIANT);
CREATE TABLE IF NOT EXISTS CFG_PROMPTS (company_id STRING, prompt_id INT, prompt STRING);
CREATE TABLE IF NOT EXISTS CFG_KEYWORDS (company_id STRING, keyword_id INT, keyword STRING);
CREATE TABLE IF NOT EXISTS JOBS (job_id STRING, company_id STRING, step STRING, kind STRING, label STRING, remote_id STRING,
  agent_id STRING, status STRING, attempts INT, input VARIANT, error STRING, created_at TIMESTAMP_LTZ, updated_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_AGENT (company_id STRING, label STRING, step STRING, brand_id STRING, payload VARIANT, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_LLM (company_id STRING, engine STRING, prompt_id INT, prompt STRING, answer STRING, sources VARIANT,
  ads VARIANT, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_SERP (company_id STRING, query_type STRING, query STRING, entities VARIANT, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_NEWS (company_id STRING, brand_id STRING, title STRING, source STRING, published DATE, url STRING, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_SOCIAL (company_id STRING, brand_id STRING, title STRING, description STRING, url STRING, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_MAPS_PLACES (company_id STRING, brand_id STRING, metro STRING, place_id STRING, place_name STRING,
  address STRING, rating FLOAT, review_count INT, stars VARIANT, url STRING, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS RAW_MAPS_REVIEWS (company_id STRING, brand_id STRING, metro STRING, place_id STRING, review_id STRING,
  rating INT, text STRING, relative_time STRING, url STRING, fetched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS REVIEWS_ENRICHED (company_id STRING, brand_id STRING, metro STRING, place_id STRING, review_id STRING,
  rating INT, text STRING, url STRING, themes VARIANT, sentiment VARIANT, enriched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS SOCIAL_ENRICHED (company_id STRING, brand_id STRING, title STRING, description STRING, url STRING,
  themes VARIANT, sentiment VARIANT, enriched_at TIMESTAMP_LTZ);
CREATE TABLE IF NOT EXISTS NEWS_ENRICHED (company_id STRING, brand_id STRING, title STRING, source STRING, published DATE, url STRING,
  sentiment STRING, enriched_at TIMESTAMP_LTZ);
