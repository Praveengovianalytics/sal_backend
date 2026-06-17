-- SAL Phase 0 seed — one tenant, one customer (Aisha V.) with holdings, value, consent, identifiers, agents.
-- Deterministic UUIDs so the slice is reproducible.

INSERT INTO cic.tenants (id, code, display_name) VALUES
  ('11111111-1111-1111-1111-111111111111', 'sg-consumer', 'Singtel SG Consumer')
ON CONFLICT (code) DO NOTHING;

INSERT INTO cic.source_systems (code, display_name, kind) VALUES
  ('mcp','Master Customer Profile','profile'),
  ('udp_lakehouse','UDP Lakehouse','lakehouse'),
  ('ascend','Project Ascend','decisioning'),
  ('lms','Loyalty Management System','loyalty')
ON CONFLICT (code) DO NOTHING;

INSERT INTO cic.customer_taxonomy (tenant_id, facet, code, label) VALUES
  (NULL,'segment','consumer','Consumer'),
  (NULL,'value_band','high','High value'),
  (NULL,'lifecycle','active','Active'),
  (NULL,'service_type','mobile','Mobile'),
  (NULL,'service_type','fibre','Fibre'),
  (NULL,'address_type','home','Home')
ON CONFLICT DO NOTHING;

-- Household + customer
INSERT INTO cic.households (id, tenant_id, postal_token, size) VALUES
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','tok_postal_520123', 3)
ON CONFLICT DO NOTHING;

INSERT INTO cic.customers (
  id, tenant_id, mcp_party_uid, name_token, age_band, gender, segment_code, household_id,
  tenure_months, loyalty_tier_code, clv_band, value_segment, lifecycle_code, primary_language,
  customer_type, lob_description, tenure_range, lifecycle_value, loyalty_prestige_status,
  active_subscription_count, is_multiservice, circle3_eligible, last_interaction_at, as_of
) VALUES (
  '33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111',
  '99999999-9999-9999-9999-999999999999','tok_Aisha_V','35_49','F','consumer',
  '22222222-2222-2222-2222-222222222222', 84,'prestige','high','high','active','en-SG',
  'Consumer','Mobile Postpaid+Broadband','5+ Years','HV','P', 2, TRUE, TRUE, now() - interval '2 days', now()
) ON CONFLICT (tenant_id, mcp_party_uid) DO NOTHING;

INSERT INTO cic.customer_identifiers (tenant_id, customer_id, id_type, id_value) VALUES
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','mcp_party_uid','99999999-9999-9999-9999-999999999999'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','nric_token','tok_S1234567A'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','msta_id','msta_aisha_001'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','service_no','tok_8400_0001')
ON CONFLICT DO NOTHING;

INSERT INTO cic.customer_address (tenant_id, customer_id, address_type, block_house_id, street_name, floor_unit, building_name, postal_code_token, developer_name) VALUES
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','Home','123','Tampines Ave 5','#12-345','HDB Tampines','tok_postal_520123','HDB')
ON CONFLICT DO NOTHING;

INSERT INTO cic.customer_billing_profile (customer_id, tenant_id, credit_class, credit_rating, account_category, billing_cycle) VALUES
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Gold','2','External','Cycle 13')
ON CONFLICT DO NOTHING;

INSERT INTO cic.customer_preference (customer_id, tenant_id, dn_survey) VALUES
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111', TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO cic.subscriptions (tenant_id, customer_id, subscription_external_id, service_type_code, plan_code, plan_name, mrc, activated_at) VALUES
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','1734951','mobile','CORE_5G','Core 5G 200GB', 45.00, now() - interval '7 years'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','1734952','fibre','FIBRE_1G','1Gbps Fibre Broadband', 49.90, now() - interval '3 years')
ON CONFLICT DO NOTHING;

INSERT INTO cic.value_metrics (customer_id, tenant_id, arpu, arpu_band, clv, margin_band, as_of) VALUES
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111', 94.90,'high', 4200.00,'high', now())
ON CONFLICT DO NOTHING;

INSERT INTO cic.consent (tenant_id, customer_id, purpose, status, consent_basis) VALUES
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','personalisation','opted_in','pdpa'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','cross_sell','opted_in','pdpa'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','marketing','opted_out','pdpa')
ON CONFLICT DO NOTHING;

-- Agents + MCP tool bindings (Phase 0)
INSERT INTO cic.agents (tenant_id, code, display_name, version, runtime) VALUES
  (NULL,'context_assembler','Context Assembler','1.0.0','agentic_layer_python')
ON CONFLICT DO NOTHING;

INSERT INTO cic.agent_mcp_tool_bindings (agent_code, mcp_tool, access, purpose_scope) VALUES
  ('context_assembler','mcp_resolve_identity','read','{personalisation}'),
  ('context_assembler','mcp_get_customer_360','read','{personalisation}'),
  ('context_assembler','mcp_assemble_context','read','{personalisation}')
ON CONFLICT DO NOTHING;

INSERT INTO cic.data_freshness (tenant_id, entity_type, source_system, last_loaded_at, recency_target) VALUES
  ('11111111-1111-1111-1111-111111111111','customers','mcp', now(), 'near_rt'),
  ('11111111-1111-1111-1111-111111111111','value_metrics','ascend', now(), 't-4')
ON CONFLICT DO NOTHING;
