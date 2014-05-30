/*
  Copyright (c) 2010-2014, GEM Foundation.

  OpenQuake is free software: you can redistribute it and/or modify it
  under the terms of the GNU Affero General Public License as published
  by the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  OpenQuake is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU Affero General Public License
  along with OpenQuake.  If not, see <http://www.gnu.org/licenses/>.
*/


CREATE OR REPLACE FUNCTION format_exc(operation TEXT, error TEXT, tab_name TEXT) RETURNS TEXT AS $$
BEGIN
    RETURN operation || ': error: ' || error || ' (' || tab_name || ')';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_last_update() RETURNS TRIGGER
LANGUAGE plpgsql AS
$$
DECLARE
BEGIN
    NEW.last_update := timezone('UTC'::text, now());
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION refresh_last_update() IS
'Refresh the ''last_update'' time stamp whenever a row is updated.';


CREATE AGGREGATE array_concat(anyarray)(sfunc=array_cat, stype=anyarray, initcond='{}');


----- statistical helpers

CREATE TYPE moment AS (
  n bigint,
  sum double precision,
  sum2 double precision);

CREATE FUNCTION moment_from_array(double precision[])
RETURNS moment AS $$
SELECT sum(1), sum(v), sum(v * v) FROM unnest($1) AS v
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION stats_from_moment(moment)
RETURNS TABLE(n BIGINT, avg DOUBLE PRECISION, std DOUBLE PRECISION) AS $$
SELECT $1.n, $1.sum / $1.n,
       sqrt(($1.sum2 - $1.sum ^ 2 / $1.n) / ($1.n - 1))
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION moment_add(moment, moment)
RETURNS moment AS $$
SELECT $1.n + $2.n, $1.sum + $2.sum, $1.sum2 + $2.sum2
$$ LANGUAGE sql;

CREATE AGGREGATE moment_sum(moment)(
   sfunc=moment_add, stype=moment, initcond='(0,0,0)');

-- typical usage is a SELECT * FROM hzrdr.gmf_stats WHERE output_id=2;
CREATE VIEW hzrdr.gmf_stats AS
SELECT output_id, gmf_id, imt, sa_period, sa_damping,
      (stats).n, (stats).avg, (stats).std FROM (
  SELECT output_id, b.id as gmf_id, imt, sa_period, sa_damping,
  stats_from_moment(moment_sum(moment_from_array(gmvs))) AS stats
  FROM hzrdr.gmf_data as a
  INNER JOIN hzrdr.gmf AS b
  ON a.gmf_id=b.id
  GROUP BY output_id, b.id, imt, sa_period, sa_damping) AS x;


-- typical usage is
--   select ses_rup_id, tag, trt_model_id, gsim, imt,
--   array_length(site_indices, 1) as num_sites,
--   array_length(ground_motion_field, 1) as num_gmvs
--   from hzrdr.gmf_view where rlz_id=1 and ses_ordinal=1 order by tag;
CREATE OR REPLACE VIEW hzrdr.gmf_view AS
   SELECT d.id as ses_rup_id, d.tag, b.trt_model_id,
   ses_collection_id, ses_id AS ses_ordinal,
   a.gsim, imt, site_indices, ground_motion_field, rlz_id
   FROM hzrdr.assoc_lt_rlz_trt_model AS a,
   hzrdr.probabilistic_rupture AS b,
   hzrdr.gmf_rupture AS c,
   hzrdr.ses_rupture AS d,
   hzrdr.lt_realization AS e
   WHERE c.rupture_id=d.id
   AND d.id=c.rupture_id
   AND d.rupture_id=b.id
   AND a.trt_model_id=b.trt_model_id
   AND c.gsim=a.gsim
   AND a.rlz_id=e.id;
