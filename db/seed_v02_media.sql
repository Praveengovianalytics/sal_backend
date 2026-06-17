-- v0.2 UI/UX (UX-DR-001): seed offer_catalogue.meta.media for the demo offers so the image-led canvas
-- renders locally. URLs point at the frontend's bundled SVG art (/products/*.svg); swap for a CDN in prod.
-- Idempotent: merges into existing meta (preserves product_code).
SET app.current_tenant = '11111111-1111-1111-1111-111111111111';

UPDATE cic.offer_catalogue SET meta = jsonb_set(coalesce(meta,'{}'::jsonb), '{media}',
  '{"hero":"/products/iphone16.svg","thumb":"/products/iphone16.svg","alt":"Apple iPhone 16 128GB",
    "variants":{"blue":"/products/iphone16.svg","black":"/products/iphone16.svg"}}'::jsonb)
  WHERE offer_id='OFFER_RECON_DEVICE';

UPDATE cic.offer_catalogue SET meta = jsonb_set(coalesce(meta,'{}'::jsonb), '{media}',
  '{"hero":"/products/sim.svg","alt":"Plan-only recontract"}'::jsonb)
  WHERE offer_id='OFFER_PLANONLY_RECON';

UPDATE cic.offer_catalogue SET meta = jsonb_set(coalesce(meta,'{}'::jsonb), '{media}',
  '{"hero":"/products/fibre.svg","alt":"5Gbps Fibre upgrade"}'::jsonb)
  WHERE offer_id='OFFER_FIBRE_UP';

UPDATE cic.offer_catalogue SET meta = jsonb_set(coalesce(meta,'{}'::jsonb), '{media}',
  '{"hero":"/products/generic.svg","alt":"Roam 30GB add-on"}'::jsonb)
  WHERE offer_id='OFFER_ROAM_ADDON';
