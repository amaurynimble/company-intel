# Company intelligence for Snowflake

This repository holds a Cortex Code skill. The skill researches any company inside your Snowflake account, using live web data from Nimble.

You type `/company-intel Chase` in Cortex Code, and the skill does the rest. It runs these steps in Snowflake:

1. The skill first runs an account brief agent on the company. The agent returns business units, the leaders who buy data and AI, data and cloud vendors, strategy, recent trigger events, rivals and risks. Every item links to its source page.
2. The skill picks 3 rivals and measures the company against them on four signals:
   - **Share of AI answer:** how often ChatGPT, Gemini and Google AI Overviews name each brand when they answer 20 category questions.
   - **Share of search:** organic Google results, paid ads and AI Overviews across 30 category keywords.
   - **Share of voice:** the skill measures news coverage and sentiment over 90 days, plus Reddit sentiment.
   - **Customer voice:** the skill compares ratings by channel, review themes and Google Maps location ratings by metro.
3. Snowflake Cortex classifies review, Reddit and news text by theme and sentiment.
4. The results appear in a Streamlit dashboard and a Cortex Agent, and every company shares the same tables.

The full research takes 30 to 60 minutes per company. The call that starts it returns in seconds.

## Requirements

- You need a Snowflake account with Cortex Code, Cortex Agents and `AI_COMPLETE` access to `claude-sonnet-4-5`.
- You need the `ACCOUNTADMIN` role for the one-time install. The install creates a network rule, a secret and an external access integration.
- You need a Nimble API key. You can get one at https://online.nimbleway.com/account-settings/api-keys. The skill creates two Nimble Web Search Agents on this key.

## Install the skill in Cortex Code

```bash
cortex skill add amaurynimble/company-intel
```

Then open Cortex Code and type `/company-intel <company name>`. On the first run, the skill finds that the Snowflake objects are missing. It asks for your consent and your Nimble key, then installs everything. The key is stored only in a Snowflake secret.

## Research a company

In Cortex Code:

```
/company-intel T-Mobile
```

The skill proposes the domain, the market and whether to include Google Maps, and it waits for your confirmation.

In a SQL worksheet, run the same research directly:

```sql
CALL NIMBLE_INTEL.CORE.RESEARCH('T-Mobile', 't-mobile.com', 'US', TRUE);
```

The last argument sets whether Google Maps is included. Use `TRUE` for brands with stores or branches, `FALSE` for brands sold through other retailers, or `NULL` to let Cortex decide. To follow progress, run this query:

```sql
SELECT step, jobs, done, running, queued, failed FROM NIMBLE_INTEL.MART.V_JOB_STATUS WHERE company_id = 't_mobile';
```

## What you get

| Object | What it is |
|---|---|
| `NIMBLE_INTEL.APP.COMPANY_INTEL` | The Streamlit dashboard. It has six tabs (Account brief, Overview, AI visibility, Search and ads, Share of voice, Customer voice) and a chat with the agent. |
| `NIMBLE_INTEL.APP.COMPANY_INTEL_ANALYST` | The Cortex Agent, also listed in Snowflake Intelligence. It answers from the research and can search the live web through Nimble. |
| `NIMBLE_INTEL.APP.COMPANY_INTEL_SV` | The semantic view behind the agent. |
| `NIMBLE_INTEL.MART` | One view per data set, including `V_METRICS`, `V_INSIGHTS`, `V_ACCOUNT_*` and `V_AI_*`. |
| `NIMBLE_INTEL.CORE` | Configuration, the job queue, raw results and Cortex output. |

## Repository layout

| Path | Purpose |
|---|---|
| `company-intel/SKILL.md` | The skill instructions that Cortex Code follows. |
| `company-intel/sql/00_setup.sql` to `07_app.sql` | The Snowflake objects, created in this order. |
| `company-intel/python/nimble_intel.py` | The stored procedure code: `INSTALL_AGENTS`, `RESEARCH`, `POLL` and `BUILD`. |
| `company-intel/agents/*.json` | The two Nimble Web Search Agent definitions. |
| `company-intel/app/` | The Streamlit app, the cockpit page and the Streamlit version pin. |

## Install by hand, without Cortex Code

Run these steps as `ACCOUNTADMIN` from SnowSQL or the Snowflake CLI, from inside the `company-intel` folder:

1. Run `sql/00_setup.sql` after you replace `<<NIMBLE_API_KEY>>` with your key.
2. Run `sql/01_schema.sql`.
3. Upload the code and agent definitions:
   ```sql
   PUT file://python/nimble_intel.py @NIMBLE_INTEL.CORE.CODE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   PUT file://agents/account_brief.json @NIMBLE_INTEL.CORE.CODE/agents AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   PUT file://agents/brand_signals.json @NIMBLE_INTEL.CORE.CODE/agents AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
   ```
4. Run `sql/02_procs.sql`, then `CALL NIMBLE_INTEL.CORE.INSTALL_AGENTS();`.
5. Run `sql/03_task.sql`, `sql/04_views.sql`, `sql/05_semantic_view.sql` and `sql/06_agent.sql`.
6. Create the stage with `CREATE STAGE IF NOT EXISTS NIMBLE_INTEL.APP.APP_STAGE;`. Upload the four files in `app/` with `PUT ... @NIMBLE_INTEL.APP.APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE`, then run `sql/07_app.sql`.

## Cost per company

One company uses these Nimble calls:

- 9 Web Search Agent runs at high effort.
- 40 ChatGPT and Gemini answers.
- 50 Google searches.
- 4 Google News searches.
- About 20 Reddit searches.
- About 160 Google Maps calls, when Maps is included.

On the Snowflake side, a serverless-sized task runs every 2 minutes while research is in progress. It uses the `NIMBLE_INTEL_WH` warehouse and stops working once no company is in progress. Cortex classification runs once per company.

## Limits

- Reddit results are a sample of threads found by search. Their count shows coverage, not total conversation volume.
- Google AI Overviews come from the Google search results for the same questions.
- Cortex picks the 3 rivals from the account brief. To change them, edit `NIMBLE_INTEL.CORE.CFG_BRANDS` before the brand step runs, or call `RESEARCH` again.
