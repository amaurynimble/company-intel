-- 07_app.sql: the dashboard. deploy.py uploads app/streamlit_app.py to the stage first.
CREATE STAGE IF NOT EXISTS NIMBLE_INTEL.APP.APP_STAGE;
CREATE OR REPLACE STREAMLIT NIMBLE_INTEL.APP.COMPANY_INTEL
  ROOT_LOCATION = '@NIMBLE_INTEL.APP.APP_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = NIMBLE_INTEL_WH
  TITLE = 'Company intelligence'
  COMMENT = 'Nimble company intelligence: account brief, AI visibility, search, ads, share of voice and reviews';
