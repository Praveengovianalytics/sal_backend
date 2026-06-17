-- Phase 1 seed — past interactions for Aisha + grounded FAQ knowledge docs.
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';  -- not needed as superuser, kept for clarity

INSERT INTO cic.interaction_event (tenant_id, customer_id, channel_code, type, subject, sentiment, resolved, occurred_at) VALUES
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','eshop','cart_drop','Viewed iPhone 16, abandoned cart', 0.10, FALSE, now() - interval '3 days'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','care','care_call','Asked about recontract options', 0.40, TRUE, now() - interval '2 days'),
  ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','retail','store_visit','Compared plans, left to think', -0.20, FALSE, now() - interval '12 hours')
ON CONFLICT DO NOTHING;

INSERT INTO cic.knowledge_doc (tenant_id, title, body, category, source) VALUES
  ('11111111-1111-1111-1111-111111111111',
   'Recontract (recon) eligibility',
   'A mobile line is eligible to recontract when it is within 3 months of contract end or already out of contract. Check the contract end date in C360. Recontracting resets the commitment term (typically 24 months) and may bundle a device on instalment. Prestige and high-value customers can be offered priority recon slots.',
   'policy','STpedia'),
  ('11111111-1111-1111-1111-111111111111',
   'Voucher application and expiry',
   'Vouchers from the Loyalty Management System (LMS) must be applied before expiry and only on eligible plans. Always surface an expiring voucher during the sale. A voucher cannot be combined with certain promotional discounts; check the voucher conditions. If a voucher cannot be applied, explain why to the customer.',
   'policy','LMS'),
  ('11111111-1111-1111-1111-111111111111',
   'Circle 3.0 eligibility',
   'Circle 3.0 gives higher discounts when a customer holds more than one Singtel service (mobile, fibre, TV). Eligibility requires same-NRIC accounts. Port-in customers can receive up to 25% off the monthly plan. Multi-service households qualify for convergence bundles.',
   'product','STpedia'),
  ('11111111-1111-1111-1111-111111111111',
   'eSIM and SIM change',
   'Customers can convert a physical SIM to eSIM in-store or via MySingtel. eSIM activation requires identity verification (eKYC). A physical-to-eSIM swap keeps the same number and plan.',
   'support','STpedia'),
  ('11111111-1111-1111-1111-111111111111',
   'Device exchange and trade-in',
   'Eligible devices can be traded in to offset a new device on a recontract. The trade-in value depends on model and condition. Device care add-ons can be attached at point of sale.',
   'product','STpedia')
ON CONFLICT DO NOTHING;
