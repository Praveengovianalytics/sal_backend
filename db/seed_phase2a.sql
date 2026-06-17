-- Phase 2a seed — offers, Ascend propensity/eligibility, voucher, competitor price, MC360 features.
-- Plus a 2nd customer "Ben" with uplift_segment=do_not_disturb to demonstrate suppression.
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';

-- Offers (one with missing_bo_ids → must be excluded as not-bookable)
INSERT INTO cic.offer_catalogue (tenant_id, offer_id, title, family_code, service_type_code, scenario_code, price, usual_price, discount_pct, status_code, valid_from, valid_to, boid, dq_flags, as_of) VALUES
  ('11111111-1111-1111-1111-111111111111','OFFER_RECON_DEVICE','Recon + iPhone 16 + Roam 30GB','mobile_device','mobile','recon', 79.00, 95.00, 0.1684,'active', current_date - 30, current_date + 60, '{3626115,4138085}', NULL, now()),
  ('11111111-1111-1111-1111-111111111111','OFFER_PLANONLY_RECON','Plan-only Recon (keep voucher)','mobile_device','mobile','recon', 45.00, 49.90, 0.0982,'active', current_date - 30, current_date + 60, '{3626115}', NULL, now()),
  ('11111111-1111-1111-1111-111111111111','OFFER_FIBRE_UP','5Gbps Fibre upgrade','fibre','fibre','recon', 59.90, 69.90, 0.1431,'active', current_date - 30, current_date + 60, '{5001}', NULL, now()),
  ('11111111-1111-1111-1111-111111111111','OFFER_ROAM_ADDON','Roam 30GB add-on','other','mobile','addon', 15.00, 18.00, 0.1667,'active', current_date - 30, current_date + 60, '{6001}', NULL, now()),
  ('11111111-1111-1111-1111-111111111111','OFFER_FAMILY_MULTILINE','Family multi-line + Disney+','sim_only','mobile','circle3', 22.00, 28.00, 0.2143,'active', current_date - 30, current_date + 60, NULL, '{missing_bo_ids}', now())
ON CONFLICT DO NOTHING;

INSERT INTO cic.competitor_price (tenant_id, plan_ref, competitor, monthly_price, source_feed, as_of) VALUES
  ('11111111-1111-1111-1111-111111111111','iphone_bundle','Competitor X', 87.00,'external_feed', now()),
  ('11111111-1111-1111-1111-111111111111','iphone_bundle','Competitor B', 84.00,'external_feed', now())
ON CONFLICT DO NOTHING;

-- Aisha: persuadable, recon/circle3/addon eligible, $20 voucher expiring
INSERT INTO cic.propensity_score (customer_id, tenant_id, churn_risk, accept_propensity, attach_propensity, uplift_segment, model_version, scored_at) VALUES
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111', 0.18000, 0.69000, 0.62000,'persuadable','mobile_uplift_v3', now())
ON CONFLICT DO NOTHING;
INSERT INTO cic.eligibility (customer_id, tenant_id, scenario_code, eligible, reason_codes, valid_until, as_of) VALUES
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','recon', TRUE, '{contract_ending_18d}', now()+interval '60 days', now()),
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','circle3', TRUE, '{multi_service,same_nric}', now()+interval '60 days', now()),
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','addon', TRUE, '{}', now()+interval '60 days', now())
ON CONFLICT DO NOTHING;
INSERT INTO cic.voucher (tenant_id, voucher_code, customer_id, type, value, expiry, conditions, applicable, as_of) VALUES
  ('11111111-1111-1111-1111-111111111111','V20RECON','33333333-3333-3333-3333-333333333333','recon_discount', 20.00, current_date + 14, '{"min_plan":"any"}', TRUE, now())
ON CONFLICT DO NOTHING;

-- MC360 features (local Databricks stand-in) + catalog
INSERT INTO cic.mc360_feature_catalog (feature_code, grain, domain, data_type, unit, is_pii, databricks_view) VALUES
  ('mobl_data_overage_p12w','ctct','usage','int','count', FALSE,'vw_cross_sell_subs_usage_and_consumption'),
  ('competitor_calls_p6w','ctct','competitor','int','count', FALSE,'vw_cross_sell_ctct_competitor_weekly'),
  ('device_view_count_p3w','ctct','behaviour','int','count', FALSE,'vw_cross_sell_ctct_behaviour_and_weblogs')
ON CONFLICT DO NOTHING;
INSERT INTO cic.mc360_feature_store_local (entity_grain, entity_ref, feature_code, value, period_key) VALUES
  ('ctct','33333333-3333-3333-3333-333333333333','mobl_data_overage_p12w','3','20260615'),
  ('ctct','33333333-3333-3333-3333-333333333333','competitor_calls_p6w','2','20260615'),
  ('ctct','33333333-3333-3333-3333-333333333333','device_view_count_p3w','3','20260615')
ON CONFLICT DO NOTHING;

-- Ben: do_not_disturb (suppression demo)
INSERT INTO cic.customers (id, tenant_id, mcp_party_uid, name_token, segment_code, tenure_months, value_segment, lifecycle_code, active_subscription_count) VALUES
  ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','88888888-8888-8888-8888-888888888888','tok_Ben_T','consumer', 30,'medium','active', 1)
ON CONFLICT (tenant_id, mcp_party_uid) DO NOTHING;
INSERT INTO cic.customer_identifiers (tenant_id, customer_id, id_type, id_value) VALUES
  ('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444444','msta_id','msta_ben_002')
ON CONFLICT DO NOTHING;
INSERT INTO cic.consent (tenant_id, customer_id, purpose, status, consent_basis) VALUES
  ('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444444','personalisation','opted_in','pdpa')
ON CONFLICT DO NOTHING;
INSERT INTO cic.value_metrics (customer_id, tenant_id, arpu, arpu_band, clv, as_of) VALUES
  ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111', 38.00,'medium', 900.00, now())
ON CONFLICT DO NOTHING;
INSERT INTO cic.propensity_score (customer_id, tenant_id, churn_risk, accept_propensity, attach_propensity, uplift_segment, model_version, scored_at) VALUES
  ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111', 0.22000, 0.10000, 0.08000,'do_not_disturb','mobile_uplift_v3', now())
ON CONFLICT DO NOTHING;
INSERT INTO cic.eligibility (customer_id, tenant_id, scenario_code, eligible, reason_codes, valid_until, as_of) VALUES
  ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','recon', TRUE, '{}', now()+interval '60 days', now())
ON CONFLICT DO NOTHING;
