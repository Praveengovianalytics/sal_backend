-- v0.3 conversation assistant (FR-QUAL/FR-TNC): seed offer eligibility QUALIFIERS + a simple T&C block
-- into offer_catalogue.meta (JSONB — no migration). Promo specifics are illustrative — verify live.
-- meta.qualifiers[] = { id, ask, axis, hard_gate, unlocks[], source }
-- meta.tnc          = { catch, expiry, bullets[ {icon,text} ] }
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';

-- Recon + iPhone 16 (device recontract): hard gates = recontract window, personal plan, 24-mo term;
-- soft gate = bank card (unlocks cashback + extra data).
UPDATE cic.offer_catalogue SET meta = meta
  || jsonb_build_object(
       'qualifiers', '[
         {"id":"recontract_window","ask":"Recontracting today (not a brand-new line)?","axis":"status","hard_gate":true},
         {"id":"personal_plan","ask":"On a personal plan (not corporate/NTUC)?","axis":"plan_tier","hard_gate":true},
         {"id":"term_24","ask":"OK to stay on a 24-month plan?","axis":"status","hard_gate":true},
         {"id":"card_uob","ask":"Have the Singtel-UOB card (or DBS)?","axis":"bank_card","hard_gate":false,"unlocks":["12% cashback","extra 10GB"]}
       ]'::jsonb,
       'tnc', '{"catch":"Charge the bill to your DBS/UOB card to keep the perks.","expiry":"2026-08-15",
                "bullets":[{"icon":"card","text":"DBS/UOB card; bill auto-charged"},
                           {"icon":"user","text":"Personal plans only; corporate/NTUC excluded"},
                           {"icon":"lock","text":"24-month term; early-exit fees apply"},
                           {"icon":"date","text":"Offer ends 15 Aug 2026"}]}'::jsonb)
  WHERE offer_id='OFFER_RECON_DEVICE';

-- Plan-only recon (SIM-only): no device lock-in; bank card optional.
UPDATE cic.offer_catalogue SET meta = meta
  || jsonb_build_object(
       'qualifiers', '[
         {"id":"recontract_window","ask":"Recontracting today (not a brand-new line)?","axis":"status","hard_gate":true},
         {"id":"own_device","ask":"Keeping your current phone (SIM-only)?","axis":"status","hard_gate":true},
         {"id":"card_uob","ask":"Have the Singtel-UOB card (or DBS)?","axis":"bank_card","hard_gate":false,"unlocks":["12% cashback"]}
       ]'::jsonb,
       'tnc', '{"catch":"SIM-only, no device lock-in. Keep your number and phone.","expiry":"2026-08-15",
                "bullets":[{"icon":"check","text":"No device contract"},
                           {"icon":"card","text":"Card cashback if paid on DBS/UOB"},
                           {"icon":"date","text":"Offer ends 15 Aug 2026"}]}'::jsonb)
  WHERE offer_id='OFFER_PLANONLY_RECON';

-- Fibre upgrade (convergence): same-NRIC for Circle bundle; address-serviceable.
UPDATE cic.offer_catalogue SET meta = meta
  || jsonb_build_object(
       'qualifiers', '[
         {"id":"same_nric","ask":"Mobile + fibre under the same NRIC?","axis":"identity","hard_gate":true},
         {"id":"serviceable","ask":"Is the home address fibre-serviceable?","axis":"status","hard_gate":true},
         {"id":"circle_bundle","ask":"Bundle with mobile for Circle savings?","axis":"plan_tier","hard_gate":false,"unlocks":["10% off 2 services","15% off 3"]}
       ]'::jsonb,
       'tnc', '{"catch":"Bundle mobile + fibre under one NRIC for the deepest Circle discount.","expiry":"2026-08-15",
                "bullets":[{"icon":"user","text":"Same NRIC for Circle bundle"},
                           {"icon":"check","text":"10% off 2 services, 15% off 3"},
                           {"icon":"lock","text":"24-month broadband term"},
                           {"icon":"date","text":"Offer ends 15 Aug 2026"}]}'::jsonb)
  WHERE offer_id='OFFER_FIBRE_UP';

-- Roaming add-on (upsell): travel timing; attaches to an active line.
UPDATE cic.offer_catalogue SET meta = meta
  || jsonb_build_object(
       'qualifiers', '[
         {"id":"active_line","ask":"Adding to an active Singtel mobile line?","axis":"status","hard_gate":true},
         {"id":"travel_soon","ask":"Travelling soon?","axis":"status","hard_gate":false}
       ]'::jsonb,
       'tnc', '{"catch":"30GB regional roaming; activate before you fly.","expiry":"2026-08-15",
                "bullets":[{"icon":"check","text":"30GB regional roaming data"},
                           {"icon":"lock","text":"Monthly recurring until cancelled"},
                           {"icon":"date","text":"Offer ends 15 Aug 2026"}]}'::jsonb)
  WHERE offer_id='OFFER_ROAM_ADDON';
