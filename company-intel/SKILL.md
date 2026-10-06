---
name: company-intel
description: |
  Researches any company from live Nimble web data, inside Snowflake, from one company name. It runs
  a Nimble account-brief agent (leaders, business units, data stack, strategy, trigger events, rivals,
  Snowflake angles), then measures the company against 3 rivals: share of AI answer in ChatGPT, Gemini
  and Google AI Overviews, share of Google search results and paid ads, share of news coverage, Reddit
  and Google Maps review sentiment by theme, ratings by channel, market moves and risks. Results land
  in NIMBLE_INTEL tables, a Streamlit dashboard and a Cortex Agent. Use when someone says "research
  <company>", "company intel on <company>", "account brief for <company>", "how does <company> compare
  with its competitors", "add <company> to the company intelligence dashboard". Do NOT use for a
  one-off web search with no Snowflake destination.
---

# Company intelligence: research a company in Snowflake (Cortex Code)

One call does the whole job: `CALL NIMBLE_INTEL.CORE.RESEARCH('<company>', '<domain>', '<market>', <include_maps>)`.
The procedure returns in seconds. A task called `POLL_TASK` then advances the research every 2 minutes
until the company reaches `ready`, which takes 30 to 60 minutes. Every company shares the same tables,
dashboard and agent; a new company adds rows.

Everything in this folder is what the skill installs:
- `sql/00_setup.sql` to `sql/07_app.sql`: the objects, run in order.
- `python/nimble_intel.py`: the procedure code, uploaded to `@NIMBLE_INTEL.CORE.CODE`.
- `agents/*.json`: the two Nimble Web Search Agents, created on the customer's Nimble key.
- `app/streamlit_app.py`: the dashboard.

## Rules
- **Never install silently.** The install needs `ACCOUNTADMIN`, explicit consent and the user's own
  Nimble API key (from https://online.nimbleway.com/account-settings/api-keys). The key goes only into
  the Snowflake secret. Never echo it or write it to a file.
- **Confirm the intake before running.** Show the company, domain, market and the Google Maps choice,
  and wait for a yes. A wrong domain sends the agents after the wrong company.
- **Never block on the run.** `RESEARCH` returns at once. Report progress from `V_JOB_STATUS` when
  the user asks, and point them to the dashboard, where sections appear as each step finishes.
- **Re-running a company replaces its data.** Ask before calling `RESEARCH` for a company that
  already appears in `NIMBLE_INTEL.CORE.COMPANIES`.

## Phase 0: preflight
1. `SELECT CURRENT_ROLE(), CURRENT_ACCOUNT();`
2. Check the install:
   ```sql
   SHOW PROCEDURES LIKE 'RESEARCH' IN SCHEMA NIMBLE_INTEL.CORE;
   SELECT agent_key, agent_id FROM NIMBLE_INTEL.CORE.CFG_AGENTS;
   ```
   If both return rows, go to Phase 1.
3. **Install, when missing.** Check `SELECT CURRENT_AVAILABLE_ROLES();` for `ACCOUNTADMIN`. Without it,
   stop and tell the user an admin must run this phase. With it, ask for consent and the Nimble key, then:
   1. `USE ROLE ACCOUNTADMIN;` and run `sql/00_setup.sql` with `<<NIMBLE_API_KEY>>` replaced by the key.
   2. Run `sql/01_schema.sql`.
   3. Upload the code and agent specs:
      ```sql
      PUT file://<skill_dir>/python/nimble_intel.py @NIMBLE_INTEL.CORE.CODE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
      PUT file://<skill_dir>/agents/account_brief.json @NIMBLE_INTEL.CORE.CODE/agents AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
      PUT file://<skill_dir>/agents/brand_signals.json @NIMBLE_INTEL.CORE.CODE/agents AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
      ```
   4. Run `sql/02_procs.sql`, then `CALL NIMBLE_INTEL.CORE.INSTALL_AGENTS();`. It returns `created` or
      `found` for each agent. An error here usually means the key is wrong.
   5. Run `sql/03_task.sql`, `sql/04_views.sql`, `sql/05_semantic_view.sql` and `sql/06_agent.sql`.
   6. `PUT file://<skill_dir>/app/streamlit_app.py @NIMBLE_INTEL.APP.APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;`
      (create the stage first with `CREATE STAGE IF NOT EXISTS NIMBLE_INTEL.APP.APP_STAGE;`), then run `sql/07_app.sql`.
4. **Cortex model.** The procedure generates prompts and keywords with `AI_COMPLETE('claude-sonnet-4-5', ...)`.
   Run `SELECT AI_COMPLETE('claude-sonnet-4-5', 'ping');`. If the region lacks it, suggest
   `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` (ACCOUNTADMIN).

## Phase 1: intake
1. Ask for the company name if the user did not give it.
2. Propose the official domain, the market (default `US`) and whether to include Google Maps.
   Include Maps when customers visit stores or branches (telecom, banks, retail, restaurants).
   Leave it out for brands sold through other retailers, such as packaged goods. Pass `NULL` to let
   the procedure decide from the account brief.
3. Check whether the company was researched before:
   `SELECT company_id, status, ready_at FROM NIMBLE_INTEL.CORE.COMPANIES WHERE company ILIKE '<company>';`
4. Show the proposal and wait for confirmation.

## Phase 2: run
```sql
CALL NIMBLE_INTEL.CORE.RESEARCH('<company>', '<domain>', '<market>', <TRUE|FALSE|NULL>);
```
Tell the user what happens next, in this order:
1. The account brief agent researches the company (5 to 15 minutes).
2. The procedure picks 3 rivals, writes 20 category questions and 30 category keywords with Cortex, and
   starts the rest in parallel:
   - one account brief per large business unit;
   - one brand agent run per brand;
   - 40 ChatGPT and Gemini answers;
   - Google results with paid ads and AI Overviews;
   - Google News;
   - Reddit;
   - Google Maps locations and reviews, when included.
3. When everything has finished, Cortex classifies review, Reddit and news text and the company becomes `ready`.

## Phase 3: track and deliver
- Progress: `SELECT step, jobs, done, running, queued, failed FROM NIMBLE_INTEL.MART.V_JOB_STATUS WHERE company_id = '<id>';`
- Failed steps are retried once at a higher effort; a failed step leaves its section empty and the rest still builds.
- When `status = 'ready'`, deliver three things:
  - **Dashboard:** `SHOW STREAMLITS IN SCHEMA NIMBLE_INTEL.APP;`, then the app URL.
  - **Agent:** `COMPANY_INTEL_ANALYST`, in Snowflake Intelligence under Agents.
  - **Headline:** `SELECT headline FROM NIMBLE_INTEL.MART.V_INSIGHTS WHERE company_id = '<id>' LIMIT 3;`

## Lifecycle
- **Refresh a company:** call `RESEARCH` again with the same name. It replaces that company's data.
- **Change the questions or keywords:** edit `NIMBLE_INTEL.CORE.CFG_PROMPTS` or `CFG_KEYWORDS`. A refresh
  regenerates them, so record edits before refreshing.
- **Stop all work:** `ALTER TASK NIMBLE_INTEL.CORE.POLL_TASK SUSPEND;`

## Data model
- `NIMBLE_INTEL.CORE`: config (`COMPANIES`, `CFG_*`), `JOBS`, raw results (`RAW_*`) and Cortex output (`*_ENRICHED`).
- `NIMBLE_INTEL.MART`:
  - one view per account brief section (`V_ACCOUNT_*`) and brand agent section (`V_BRAND_*`);
  - AI answers (`V_AI_*`), Google results (`V_SERP_*`) and themes (`V_THEME_*`);
  - `V_METRICS` (long format), `V_SHARE_OF_VOICE`, `V_INSIGHTS` and `V_JOB_STATUS`.
- `NIMBLE_INTEL.APP`: the semantic view `COMPANY_INTEL_SV`, the agent `COMPANY_INTEL_ANALYST`, the
  search function `WEB_SEARCH` and the Streamlit app `COMPANY_INTEL`.
