-- v0.3: extra grounded knowledge so the conversation assistant can answer product questions end-to-end.
-- Re-runnable: removes these titles first, then re-inserts. (Backend rebuilds the Milvus RAG index at startup.)
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';
DELETE FROM cic.knowledge_doc WHERE source = 'v0.3_seed';

INSERT INTO cic.knowledge_doc (tenant_id, title, body, category, source) VALUES
 ('11111111-1111-1111-1111-111111111111',
  'Recon iPhone 16 bundle — what is included',
  'The recontract iPhone 16 bundle is $79/mo over 24 months (usual price $96). It includes the iPhone 16 128GB device, a 5G mobile plan, and a 30GB roaming add-on. A $20 loyalty voucher (V20RECON) can be applied. Paying the bill on a DBS or Singtel-UOB card unlocks extra cashback and 10GB more data. Personal plans only; corporate and NTUC plans are excluded.',
  'product', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'Value vs competitor (price objection)',
  'When a customer says a competitor is cheaper, compare like-for-like. The recon iPhone 16 bundle includes the device and roaming, not just a SIM. With the $20 voucher and Circle multi-service discount it typically works out about $8/mo better than Competitor X over 24 months. Acknowledge the concern, ask what the competitor quote includes, then reframe on total value rather than discounting first.',
  'sales', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'Roaming add-on (ReadyRoam 30GB)',
  'The roaming add-on gives 30GB of regional roaming data for travel, $15/mo, attached to an active Singtel mobile line. Best attached at point of sale when the customer mentions upcoming travel. It is a monthly recurring add-on until cancelled.',
  'product', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'Device protection (MobileSwop)',
  'MobileSwop device protection covers screen and device damage and swaps, about $9.90/mo via Asurion. Enrolment is only available within roughly 30 days of device activation or upgrade, so offer it at point of sale next to the new device.',
  'product', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'PayLater and instalments',
  'Singtel PayLater lets customers spread the device cost at 0% over up to 36 months. The customer must own a Singtel service and have no more than 3 plans on the NRIC. A bank 0% instalment plan is an alternative if the customer prefers their credit card.',
  'product', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'Circle 3.0 family bundle savings',
  'Singtel Circle gives 10% off with 2 services and 15% off with 3 services (mobile, fibre, TV) held under the same NRIC, and can nominate up to 5 mobile lines. Family lines on another telco can be ported in for free, usually within one working day; do not cancel the old line first.',
  'product', 'v0.3_seed'),
 ('11111111-1111-1111-1111-111111111111',
  'Bank card promotions (DBS, UOB, Citi)',
  'Several promotions are unlocked by paying the bill on a participating bank card. The Singtel-UOB card gives around 12% cashback plus fee waivers; DBS cards give a rebate when paid at the Singtel kiosk; OCBC, Citi and HSBC telco promotions vary. Always ask which card the customer has before pricing an offer, as it changes the final value. Verify current rates as promotions change.',
  'policy', 'v0.3_seed');
