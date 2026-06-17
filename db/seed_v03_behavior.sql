-- v0.3 C360 "behavior" block: MC360 XSELL behavioural features for Aisha (local stand-in for Databricks;
-- resolved on demand by the ML-Agent via resolve_features). Re-runnable. Promo/usage values illustrative.
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';

DELETE FROM cic.mc360_feature_catalog WHERE feature_code IN
 ('data_used_gb','data_allowance_gb','mobile_split_pct','voice_mou_p4w','sms_count_p4w','app_sessions_p4w',
  'roam_country','roam_days_p12w','port_in_risk','arpu_trend_pct','arpu_slope_dir','payment_card','autopay');
INSERT INTO cic.mc360_feature_catalog (feature_code, grain, domain, data_type, unit, is_pii, databricks_view) VALUES
 ('data_used_gb','ctct','usage','double','gb', FALSE,'vw_cross_sell_cust_usage_and_consumption'),
 ('data_allowance_gb','ctct','usage','double','gb', FALSE,'vw_cross_sell_subs_usage_and_consumption'),
 ('mobile_split_pct','ctct','usage','int','pct', FALSE,'vw_cross_sell_cust_usage_and_consumption'),
 ('voice_mou_p4w','ctct','usage','int','minutes', FALSE,'vw_cross_sell_ctct_behaviour_and_weblogs'),
 ('sms_count_p4w','ctct','usage','int','count', FALSE,'vw_cross_sell_ctct_behaviour_and_weblogs'),
 ('app_sessions_p4w','ctct','behaviour','int','count', FALSE,'vw_cross_sell_ctct_behaviour_and_weblogs'),
 ('roam_country','ctct','roaming','string','code', FALSE,'vw_cross_sell_ctct_roaming'),
 ('roam_days_p12w','ctct','roaming','int','days', FALSE,'vw_cross_sell_ctct_roaming'),
 ('port_in_risk','ctct','competitor','string','band', TRUE,'vw_cross_sell_ctct_competitor_weekly'),
 ('arpu_trend_pct','cust','billing','int','pct', FALSE,'vw_cross_sell_cust_billing'),
 ('arpu_slope_dir','cust','billing','string','dir', FALSE,'vw_cross_sell_cust_billing'),
 ('payment_card','cust','billing','string','issuer', TRUE,'vw_cross_sell_cust_billing'),
 ('autopay','cust','billing','int','flag', FALSE,'vw_cross_sell_cust_billing');

DELETE FROM cic.mc360_feature_store_local
 WHERE entity_ref='33333333-3333-3333-3333-333333333333'
   AND feature_code IN ('data_used_gb','data_allowance_gb','mobile_split_pct','voice_mou_p4w','sms_count_p4w',
   'app_sessions_p4w','roam_country','roam_days_p12w','port_in_risk','arpu_trend_pct','arpu_slope_dir','payment_card','autopay');
INSERT INTO cic.mc360_feature_store_local (entity_grain, entity_ref, feature_code, value, period_key) VALUES
 ('ctct','33333333-3333-3333-3333-333333333333','data_used_gb','178','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','data_allowance_gb','200','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','mobile_split_pct','64','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','voice_mou_p4w','318','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','sms_count_p4w','41','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','app_sessions_p4w','12','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','roam_country','Japan','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','roam_days_p12w','6','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','port_in_risk','medium','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','arpu_trend_pct','-6','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','arpu_slope_dir','down','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','payment_card','DBS','20260615'),
 ('ctct','33333333-3333-3333-3333-333333333333','autopay','1','20260615');
