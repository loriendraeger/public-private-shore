-- AD HOC (not part of the pipeline). Run with ./export.sh.
-- Every county parcel whose owner looks like a conservancy or land trust (on our shore
-- or not), with every V12 parcel/tax field plus shoreline context. The broad pattern
-- deliberately includes look-alikes (HOAs, LLCs) to check the ownership rule against.
-- Used for the decision (2026-10-17) to classify land trusts as other_public.
SELECT
  r.fid AS parcel_id, r.stateid, r.parcelid, r.taxparcelid, r.parceldate, r.taxrollyear,
  r.ownernme1, r.ownernme2,
  r.pstladress AS tax_billing_address,
  r.siteadress AS site_address, r.landmarkname, r.placename, r.zipcode, r.zip4,
  r.schooldist, r.schooldistno,
  r.propclass, r.auxclass,
  r.cntassdvalue AS assessed_total, r.lndvalue AS assessed_land, r.impvalue AS assessed_improvements,
  r.mflvalue AS mfl_value, r.estfmkvalue AS est_fair_market_value,
  r.netprpta AS net_property_tax, r.grsprpta AS gross_property_tax,
  r.assdacres AS assessed_acres, r.deedacres AS deed_acres, r.gisacres AS gis_acres,
  round((ST_Area(r.geom) / 4046.86)::numeric, 2) AS computed_acres,
  ST_Area(r.geom) / 4046.86 >= 1 AS one_acre_plus,
  r.parcelsrc, r.loaddate,
  sh.shore_m IS NOT NULL AS on_shore, sh.waterbody, sh.shore_m, sh.segment_ids,
  r.geom
FROM raw.parcels r
LEFT JOIN LATERAL (
  SELECT string_agg(DISTINCT s.waterbody, ', ') AS waterbody,
         round(sum(s.length_m)::numeric, 1) AS shore_m,
         string_agg(s.segment_id::text, ',') AS segment_ids
  FROM analysis.shore_segments s WHERE r.fid = ANY (s.parcel_ids)
) sh ON true
WHERE upper(r.ownernme1) ~ '(CONSERVANCY|LAND TRUST)'
