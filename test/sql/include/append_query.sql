-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- canary for results diff
-- this should be the only output of the results diff
SELECT setting, current_setting(setting) AS value from (VALUES ('timescaledb.disable_optimizations'),('timescaledb.enable_chunk_append')) v(setting);

-- query should exclude all chunks with optimization on
:PREFIX
SELECT * FROM append_test WHERE time > now_s() + '1 month'
ORDER BY time DESC;

--query should exclude all chunks and be a MergeAppend
:PREFIX
SELECT * FROM append_test WHERE time > now_s() + '1 month'
ORDER BY time DESC limit 1;

-- when optimized, the plan should be a constraint-aware append and
-- cover only one chunk. It should be a backward index scan due to
-- descending index on time. Should also skip the main table, since it
-- cannot hold tuples
:PREFIX
SELECT * FROM append_test WHERE time > now_s() - interval '2 months';

-- adding ORDER BY and LIMIT should turn the plan into an optimized
-- ordered append plan
:PREFIX
SELECT * FROM append_test WHERE time > now_s() - interval '2 months'
ORDER BY time LIMIT 3;

-- no optimized plan for queries with restrictions that can be
-- constified at planning time. Regular planning-time constraint
-- exclusion should occur.
:PREFIX
SELECT * FROM append_test WHERE time > now_i() - interval '2 months'
ORDER BY time;

-- currently, we cannot distinguish between stable and volatile
-- functions as far as applying our modified plan. However, volatile
-- function should not be pre-evaluated to constants, so no chunk
-- exclusion should occur.
:PREFIX
SELECT * FROM append_test WHERE time > now_v() - interval '2 months'
ORDER BY time;

-- prepared statement output should be the same regardless of
-- optimizations
PREPARE query_opt AS
SELECT * FROM append_test WHERE time > now_s() - interval '2 months'
ORDER BY time;

:PREFIX EXECUTE query_opt;

DEALLOCATE query_opt;

-- aggregates should produce same output
:PREFIX
SELECT date_trunc('year', time) t, avg(temp) FROM append_test
WHERE time > now_s() - interval '4 months'
GROUP BY t
ORDER BY t DESC;

-- querying outside the time range should return nothing. This tests
-- that ConstraintAwareAppend can handle the case when an Append node
-- is turned into a Result node due to no children
:PREFIX
SELECT date_trunc('year', time) t, avg(temp)
FROM append_test
WHERE time < '2016-03-22'
AND date_part('dow', time) between 1 and 5
GROUP BY t
ORDER BY t DESC;

-- a parameterized query can safely constify params, so won't be
-- optimized by constraint-aware append since regular constraint
-- exclusion works just fine
PREPARE query_param AS
SELECT * FROM append_test WHERE time > $1 ORDER BY time;

:PREFIX
EXECUTE query_param(now_s() - interval '2 months');
DEALLOCATE query_param;

--test with cte
:PREFIX
WITH data AS (
    SELECT time_bucket(INTERVAL '30 day', TIME) AS btime, AVG(temp) AS VALUE
    FROM append_test
    WHERE
        TIME > now_s() - INTERVAL '400 day'
    AND colorid > 0
    GROUP BY btime
),
period AS (
    SELECT time_bucket(INTERVAL '30 day', TIME) AS btime
      FROM  GENERATE_SERIES('2017-03-22T01:01:01', '2017-08-23T01:01:01', INTERVAL '30 day') TIME
  )
SELECT period.btime, VALUE
    FROM period
    LEFT JOIN DATA USING (btime)
    ORDER BY period.btime;

WITH data AS (
    SELECT time_bucket(INTERVAL '30 day', TIME) AS btime, AVG(temp) AS VALUE
    FROM append_test
    WHERE
        TIME > now_s() - INTERVAL '400 day'
    AND colorid > 0
    GROUP BY btime
),
period AS (
    SELECT time_bucket(INTERVAL '30 day', TIME) AS btime
      FROM  GENERATE_SERIES('2017-03-22T01:01:01', '2017-08-23T01:01:01', INTERVAL '30 day') TIME
  )
SELECT period.btime, VALUE
    FROM period
    LEFT JOIN DATA USING (btime)
    ORDER BY period.btime;

-- force nested loop join with no materialization. This tests that the
-- inner ConstraintAwareScan supports resetting its scan for every
-- iteration of the outer relation loop
set enable_hashjoin = 'off';
set enable_mergejoin = 'off';
set enable_material = 'off';

:PREFIX
SELECT * FROM append_test a INNER JOIN join_test j ON (a.colorid = j.colorid)
WHERE a.time > now_s() - interval '3 hours' AND j.time > now_s() - interval '3 hours';

reset enable_hashjoin;
reset enable_mergejoin;
reset enable_material;

-- test constraint_exclusion with date time dimension and DATE/TIMESTAMP/TIMESTAMPTZ constraints
-- the queries should all have 3 chunks
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::date ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::timestamp ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::timestamptz ORDER BY time;

-- test Const OP Var
-- the queries should all have 3 chunks
:PREFIX SELECT * FROM metrics_date WHERE '2000-01-15'::date < time ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE '2000-01-15'::timestamp < time ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE '2000-01-15'::timestamptz < time ORDER BY time;

-- test 2 constraints
-- the queries should all have 2 chunks
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::date AND time < '2000-01-21'::date ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::timestamp AND time < '2000-01-21'::timestamp ORDER BY time;
:PREFIX SELECT * FROM metrics_date WHERE time > '2000-01-15'::timestamptz AND time < '2000-01-21'::timestamptz ORDER BY time;

-- test constraint_exclusion with timestamp time dimension and DATE/TIMESTAMP/TIMESTAMPTZ constraints
-- the queries should all have 3 chunks
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::date ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::timestamp ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::timestamptz ORDER BY time;

-- test Const OP Var
-- the queries should all have 3 chunks
:PREFIX SELECT * FROM metrics_timestamp WHERE '2000-01-15'::date < time ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE '2000-01-15'::timestamp < time ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE '2000-01-15'::timestamptz < time ORDER BY time;

-- test 2 constraints
-- the queries should all have 2 chunks
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::date AND time < '2000-01-21'::date ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::timestamp AND time < '2000-01-21'::timestamp ORDER BY time;
:PREFIX SELECT * FROM metrics_timestamp WHERE time > '2000-01-15'::timestamptz AND time < '2000-01-21'::timestamptz ORDER BY time;

-- test constraint_exclusion with timestamptz time dimension and DATE/TIMESTAMP/TIMESTAMPTZ constraints
-- the queries should all have 3 chunks
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::date ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::timestamp ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::timestamptz ORDER BY time;

-- test Const OP Var
-- the queries should all have 3 chunks
:PREFIX SELECT time FROM metrics_timestamptz WHERE '2000-01-15'::date < time ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE '2000-01-15'::timestamp < time ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE '2000-01-15'::timestamptz < time ORDER BY time;

-- test 2 constraints
-- the queries should all have 2 chunks
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::date AND time < '2000-01-21'::date ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::timestamp AND time < '2000-01-21'::timestamp ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > '2000-01-15'::timestamptz AND time < '2000-01-21'::timestamptz ORDER BY time;

-- test CURRENT_DATE
-- should be 0 chunks
:PREFIX SELECT time FROM metrics_date WHERE time > CURRENT_DATE ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamp WHERE time > CURRENT_DATE ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > CURRENT_DATE ORDER BY time;

-- test CURRENT_TIMESTAMP
-- should be 0 chunks
:PREFIX SELECT time FROM metrics_date WHERE time > CURRENT_TIMESTAMP ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamp WHERE time > CURRENT_TIMESTAMP ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > CURRENT_TIMESTAMP ORDER BY time;

-- test now()
-- should be 0 chunks
:PREFIX SELECT time FROM metrics_date WHERE time > now() ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamp WHERE time > now() ORDER BY time;
:PREFIX SELECT time FROM metrics_timestamptz WHERE time > now() ORDER BY time;

-- query with tablesample and planner exclusion
:PREFIX
SELECT * FROM metrics_date TABLESAMPLE BERNOULLI(5) REPEATABLE(0)
WHERE time > '2000-01-15'
ORDER BY time DESC;

-- query with tablesample and startup exclusion
:PREFIX
SELECT * FROM metrics_date TABLESAMPLE BERNOULLI(5) REPEATABLE(0)
WHERE time > '2000-01-15'::text::date
ORDER BY time DESC;

-- test runtime exclusion

-- test runtime exclusion with LATERAL and 2 hypertables
:PREFIX SELECT m1.time, m2.time FROM metrics_timestamptz m1 LEFT JOIN LATERAL(SELECT time FROM metrics_timestamptz m2 WHERE m1.time = m2.time LIMIT 1) m2 ON true ORDER BY m1.time;

-- test runtime exclusion does not activate for constraints on non-partitioning columns
-- should not use runtime exclusion
:PREFIX SELECT * FROM append_test a LEFT JOIN LATERAL(SELECT * FROM join_test j WHERE a.colorid = j.colorid ORDER BY time DESC LIMIT 1) j ON true ORDER BY a.time LIMIT 1;

-- test runtime exclusion with LATERAL and generate_series
:PREFIX SELECT g.time FROM generate_series('2000-01-01'::timestamptz, '2000-02-01'::timestamptz, '1d'::interval) g(time) LEFT JOIN LATERAL(SELECT time FROM metrics_timestamptz m WHERE m.time=g.time LIMIT 1) m ON true;
:PREFIX SELECT * FROM generate_series('2000-01-01'::timestamptz,'2000-02-01'::timestamptz,'1d'::interval) AS g(time) INNER JOIN LATERAL (SELECT time FROM metrics_timestamptz m WHERE time=g.time) m ON true;
:PREFIX SELECT * FROM generate_series('2000-01-01'::timestamptz,'2000-02-01'::timestamptz,'1d'::interval) AS g(time) INNER JOIN LATERAL (SELECT time FROM metrics_timestamptz m WHERE time=g.time ORDER BY time) m ON true;
:PREFIX SELECT * FROM generate_series('2000-01-01'::timestamptz,'2000-02-01'::timestamptz,'1d'::interval) AS g(time) INNER JOIN LATERAL (SELECT time FROM metrics_timestamptz m WHERE time>g.time + '1 day' ORDER BY time LIMIT 1) m ON true;

-- test runtime exclusion with subquery
:PREFIX SELECT m1.time FROM metrics_timestamptz m1 WHERE m1.time=(SELECT max(time) FROM metrics_timestamptz);

-- test runtime exclusion with correlated subquery
:PREFIX SELECT m1.time, (SELECT m2.time FROM metrics_timestamptz m2 WHERE m2.time < m1.time ORDER BY m2.time DESC LIMIT 1) FROM metrics_timestamptz m1 WHERE m1.time < '2000-01-10' ORDER BY m1.time;

-- test EXISTS
:PREFIX SELECT m1.time FROM metrics_timestamptz m1 WHERE EXISTS(SELECT 1 FROM metrics_timestamptz m2 WHERE m1.time < m2.time) ORDER BY m1.time DESC limit 1000;

-- test constraint exclusion for subqueries with append
-- should include 2 chunks
:PREFIX SELECT time FROM (SELECT time FROM metrics_timestamptz WHERE time < '2000-01-10'::text::timestamptz ORDER BY time) m;

-- test constraint exclusion for subqueries with mergeappend
-- should include 2 chunks
:PREFIX SELECT device_id, time FROM (SELECT device_id, time FROM metrics_timestamptz WHERE time < '2000-01-10'::text::timestamptz ORDER BY device_id, time) m;

-- test prepared statements
-- executor startup exclusion with no chunks excluded
PREPARE prep AS SELECT time FROM metrics_timestamptz WHERE time < now() AND device_id = 1 ORDER BY time;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
DEALLOCATE prep;

-- executor startup exclusion with chunks excluded
PREPARE prep AS SELECT time FROM metrics_timestamptz WHERE time < '2000-01-10'::text::timestamptz AND device_id = 1 ORDER BY time;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
DEALLOCATE prep;

-- runtime exclusion with LATERAL and 2 hypertables
PREPARE prep AS SELECT m1.time, m2.time FROM metrics_timestamptz m1 LEFT JOIN LATERAL(SELECT time FROM metrics_timestamptz m2 WHERE m1.time = m2.time LIMIT 1) m2 ON true ORDER BY m1.time;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
DEALLOCATE prep;

-- executor startup exclusion with subquery
PREPARE prep AS SELECT time FROM (SELECT time FROM metrics_timestamptz WHERE time < '2000-01-10'::text::timestamptz ORDER BY time) m;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
DEALLOCATE prep;

-- test constraint exclusion for subqueries with mergeappend
PREPARE prep AS SELECT device_id, time FROM (SELECT device_id, time FROM metrics_timestamptz WHERE time < '2000-01-10'::text::timestamptz ORDER BY device_id, time) m;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
:PREFIX EXECUTE prep;
DEALLOCATE prep;

