# Generates JSON for three type of reports:
# - K001 - Globally aggregated
# - K002 - Workload type (first word analysis)
# - K003 - TOP queries by total time

# json_object - currently generated json
# prev_json_object - previously generated json

LISTLIMIT=100

set -u -e -o pipefail

error_handler() {
  echo "^^^ ERROR at line: ['${BASH_LINENO[0]}']" >&2
  echo >&2
}
trap error_handler ERR

if [[ -z ${JSON_REPORTS_DIR+x} ]]; then
  echo "FATAL: variable 'JSON_REPORTS_DIR' is empty" >&2 exit 1
fi

if [[ "${SSDBNAME}" != "None" ]]; then
  change_db_cmd="\connect ${SSDBNAME}
                "
else
  change_db_cmd=""
fi


tmp_dir="${JSON_REPORTS_DIR}/tmp_K000"
mkdir -p "${tmp_dir}"

results_cnt="0"
# fname_prefix generated by formula "json_files_cnt + 1"
for file in "${tmp_dir}"/[1-9]*_${ALIAS_INDEX}.json; do
  if [[ -f "${file}" ]]; then
    results_cnt=$(( results_cnt + 1 ))
  fi
done

fname_prefix=$(( results_cnt + 1 ))
prev_fname_prefix=$(( fname_prefix - 1 ))

# remove some symbols from observerd database name
simple_dbname=${DBNAME//[-, ,~,]/_}

cur_snapshot_fname="${tmp_dir}/${fname_prefix}_${simple_dbname}_${ALIAS_INDEX}.json"
prev_snapshot_fname="${tmp_dir}/${prev_fname_prefix}_${simple_dbname}_${ALIAS_INDEX}.json"

# read previous result and build prev_json_object
if [[ -f "${prev_snapshot_fname}" ]]; then
  prev_json_object=$(cat "${prev_snapshot_fname}")
fi

# check pg_stat_kcache availability
err_code="0"
res=$(${CHECK_HOST_CMD} "${_PSQL} -f -" <<'SQL' >/dev/null 2>&1
\${change_db_cmd}
select from pg_stat_kcache limit 1 -- the fastest way
SQL
) || err_code="$?"

# main query to save statistics
if [[ "${err_code}" -ne "0" ]]; then
  # WITHOUT pg_stat_kcache
  QUERY="
    select
      /* rownum in snapshot may be not equal to resulting rownum */
      row_number() over (order by total_time desc) as rownum,
      /* pg_stat_statements_part */
      left(query, 50000) as query, /*  obsolete left ? check pg_stat_statements for cutting */
      calls,
      total_time,
      /*
      min_time,
      max_time,
      mean_time
      stddev_time
      */
      rows,
      shared_blks_hit,
      shared_blks_read,
      shared_blks_dirtied,
      shared_blks_written,
      local_blks_hit,
      local_blks_read,
      local_blks_dirtied,
      local_blks_written,
      temp_blks_read,
      temp_blks_written,
      blk_read_time,
      blk_write_time,
      queryid,
      /*
      save hash
      */
      md5( queryid::text || dbid::text || userid::text ) as md5
    from pg_stat_statements s
    order by total_time desc
    limit ${LISTLIMIT}
  "
else
  # WITH pg_stat_kcache
  QUERY="
    select
      /* rownum in snapshot may be not equal to resulting rownum */
      row_number() over (order by total_time desc) as rownum,
      /* pg_stat_statements_part */
      left(query, 50000) as query, /*  obsolete left ? check pg_stat_statements for cutting */
      calls,
      total_time,
      /*
      min_time,
      max_time,
      mean_time
      stddev_time
      */
      rows,
      shared_blks_hit,
      shared_blks_read,
      shared_blks_dirtied,
      shared_blks_written,
      local_blks_hit,
      local_blks_read,
      local_blks_dirtied,
      local_blks_written,
      temp_blks_read,
      temp_blks_written,
      blk_read_time,
      blk_write_time,
      queryid,
      /* kcache part */
      k.reads as kcache_reads,
      k.writes as kcache_writes,
      k.user_time::bigint * 1000 as kcache_user_time_ms,
      k.system_time::bigint * 1000 as kcache_system_time_ms,
      /* save hash */
      md5(queryid::text || dbid::text || userid::text) as md5
    from pg_stat_statements s
    join pg_stat_kcache() k using(queryid, dbid, userid)
    order by total_time desc
    limit ${LISTLIMIT}
  "
fi

# take snapshot and save as a json object
json_object=$(${CHECK_HOST_CMD} "${_PSQL} -f -" <<SQL
  ${change_db_cmd}
  with data as (
    ${QUERY}
  )
  select json_build_object(
    'snapshot_timestamptz'::text, to_json(now()::timestamptz)::json,
    'snapshot_timestamptz_s'::text, to_json(extract('epoch' from now()::timestamptz))::json,
    'queries', json_object_agg(data.md5, data.*)
  )
  from data
SQL
             )

# save to file
jq -r . <<<${json_object} > "${cur_snapshot_fname}"

res=""

if [[ "${prev_fname_prefix}" -eq "0" ]]; then
  echo "ERROR: need two checks to compare results. Please run whole check for this epoch again." >&2
  echo "NOTICE: ^^ this is not a real error. Just run check again." >&2
  exit 1
fi

# calculate time diff in seconds between checks
start_seconds=$(jq -r '.snapshot_timestamptz_s' "${prev_snapshot_fname}")
start_seconds_rnd=$(printf "%.0f\n" "${start_seconds}")
end_seconds=$(jq -r '.snapshot_timestamptz_s' "${cur_snapshot_fname}")
end_seconds_rnd=$(printf "%.0f\n" "${end_seconds}")

period_seconds_rnd=$(( end_seconds_rnd - start_seconds_rnd ))

if [[ "period_seconds_rnd" -le "0" ]]; then
  echo "ERROR: Period between snapshots is 0 seconds" >&2
  exit 1
fi

# generate sub_sql
sub_sql=" "
sub_sql_sum_s1=" "
sub_sql_sum_s2=" "
sub_sql_sum_delta=" "
for key in \
           calls \
           total_time \
           rows \
           shared_blks_hit \
           shared_blks_read \
           shared_blks_dirtied \
           shared_blks_written \
           local_blks_hit \
           local_blks_read \
           local_blks_dirtied \
           local_blks_written \
           temp_blks_read \
           temp_blks_written \
           blk_read_time \
           blk_write_time \
           kcache_reads \
           kcache_writes \
           kcache_user_time_ms \
           kcache_system_time_ms ;
                                   do
  sub_sql="${sub_sql}
    sum((s2.obj->>'${key}')::numeric) - sum((s1.obj->>'${key}')::numeric) as diff_${key},
    (sum((s2.obj->>'${key}')::numeric) - sum((s1.obj->>'${key}')::numeric)) / nullif((select seconds from delta ), 0) as per_sec_${key},
    (sum((s2.obj->>'${key}')::numeric) - sum((s1.obj->>'${key}')::numeric)) / nullif((sum((s2.obj->>'calls')::numeric) - sum((s1.obj->>'calls')::numeric)), 0) as per_call_${key},
    round(100 * (sum((s2.obj->>'${key}')::numeric) - sum((s1.obj->>'${key}')::numeric))::numeric / nullif((select sum_delta_${key} from sum_delta), 0), 2) as ratio_${key},
  "
  sub_sql_sum_s1="${sub_sql_sum_s1}
    sum((s1.obj->>'${key}')::numeric) as sum_${key},"
  sub_sql_sum_s2="${sub_sql_sum_s2}
    sum((s2.obj->>'${key}')::numeric) as sum_${key},"
  sub_sql_sum_delta="${sub_sql_sum_delta}
    sum((s2.obj->>'${key}')::numeric - (s1.obj->>'${key}')::numeric) as sum_delta_${key},"
done

sql="
  with snap1(j) as (
    select \$snap1\$
       ${prev_json_object}
    \$snap1\$::json
  ), snap2(j) as (
    select \$snap2\$
       ${json_object}
    \$snap2\$::json
  ), delta(seconds) as (
    select
      (select j->>'snapshot_timestamptz_s' from snap2)::numeric
       - (select j->>'snapshot_timestamptz_s' from snap1)::numeric
  ), s1(md5, obj) as (
    select _.*
    from snap1, lateral json_each(j->'queries') as _
  ), s2(md5, obj) as (
    select _.*
    from snap2, lateral json_each(j->'queries') as _
  ), si as (  -- let's create si as intersection of s1 and s2 (si contains all query groups which both s1 and s2 have)
        select s1.md5
        from s1
        intersect
        select s2.md5
        from s2
  ), sum_si_s1 as ( -- calculate sum(calls) and sum(total_time) for si-s1
    select
        sum((s1.obj->>'calls')::numeric) as sum_calls,
        sum((s1.obj->>'total_time')::numeric) as sum_total_time,
        1 as key
    from s1
    where s1.md5 in (select md5 from si)
  ), sum_si_s2 as ( -- calculate sum(calls) and sum(total_time) for si-s2
    select
        sum((s2.obj->>'calls')::numeric) as sum_calls,
        sum((s2.obj->>'total_time')::numeric) as sum_total_time,
        1 as key
    from s2
    where s2.md5 in (select md5 from si)
  ), sum_s1 as (
    select
      ${sub_sql_sum_s1}
      1 as key
    from s1
  ), sum_s2 as (
    select
      ${sub_sql_sum_s2}
      1 as key
    from s2
  ), diff1 as (   -- the difference between sum for si and sum for s1
    select
      abs(sum_s1.sum_calls - sum_si_s1.sum_calls) as sum_calls,
      abs(sum_s1.sum_total_time - sum_si_s1.sum_total_time) as sum_total_time,
      key
    from sum_s1
    join sum_si_s1 using (key)
  ), diff2 as (   -- the difference between sum for si and sum for s2
    select
      abs(sum_s2.sum_calls - sum_si_s2.sum_calls) as sum_calls,
      abs(sum_s2.sum_total_time - sum_si_s2.sum_total_time) as sum_total_time,
      key
    from sum_s2
    join sum_si_s2 using (key)
  ), diff_calc_rel_err as (
    select
      abs(sum_si_s2.sum_calls - sum_si_s1.sum_calls) as sum_calls,
      abs(sum_si_s2.sum_total_time - sum_si_s1.sum_total_time) as sum_total_time,
      key
    from sum_si_s2
    join sum_si_s1 using (key)
  ), calc_error as ( -- absolute error with respect to calls metric is calculated as: (diff1(calls) + diff2(calls)) / 2
    select
        (diff1.sum_calls + diff2.sum_calls)::numeric / 2 as absolute_error_calls,
        (diff1.sum_total_time + diff2.sum_total_time)::numeric / 2 as absolute_error_total_time,
        case when (select sum_calls from diff_calc_rel_err) = 0 then 0 else
            (((diff1.sum_calls + diff2.sum_calls) / 2) * 100) / (select sum_calls from diff_calc_rel_err)
        end as relative_error_calls,
        case when (select sum_total_time from diff_calc_rel_err) = 0 then 0 else
            (((diff1.sum_total_time + diff2.sum_total_time) / 2) * 100) / (select sum_total_time from diff_calc_rel_err)
        end as relative_error_total_time
    from diff1
    join diff2 using (key)
  ), sum_delta as (
    select
      ${sub_sql_sum_delta}
      '' as _
    from s1
    join s2 using(md5)
  ), queries_pre as (
    select
      ${sub_sql}
      s1.md5 as md5,
      s1.obj->>'queryid' as queryid,
      s1.obj->>'query' as query
    from s1
    join s2 using(md5)
    group by s1.md5, s1.obj->>'queryid', s1.obj->>'query'
  ), queries as (
    -- K003
    select
      row_number() over(order by diff_total_time desc) as rownum,
      *
    from queries_pre
    order by diff_total_time desc
  ), aggregated as (
    -- globally aggregated metrics (K001)
    select
      ${sub_sql}
      '' as _
    from s1
    join s2 using(md5)
  ), workload_type_pre as (
    -- query type is defined by the first word (K002)
    select
      case lower(regexp_replace(s1.obj->>'query', '^\W*(\w+)\W+.*$',  '\1'))
        when 'select' then
          case
            when s1.obj->>'query' ~* 'for\W+(no\W+key\W+)?update' then 'select ... for [no key] update'
            when s1.obj->>'query' ~* 'for\W+(key\W+)?share' then 'select ... for [key] share'
            else 'select'
          end
        else lower(regexp_replace(s1.obj->>'query', '^\W*(\w+)\W+.*$',  '\1'))
      end as word,
      ${sub_sql}
      '' as _
    from s1
    join s2 using(md5)
    group by 1
  ), workload_type as (
    select
      row_number() over(order by diff_total_time desc) as rownum,
      *
    from workload_type_pre
    order by diff_total_time desc
  )
  select json_build_object(
    'start_timestamptz'::text, (select j->'snapshot_timestamptz' from snap1),
    'end_timestamptz'::text, (select j->'snapshot_timestamptz' from snap2),
    'period_seconds'::text, ( select (snap2.j->>'snapshot_timestamptz_s')::numeric - (snap1.j->>'snapshot_timestamptz_s')::numeric from snap1, snap2 ),
    'period_age'::text, ( select (snap2.j->>'snapshot_timestamptz')::timestamptz - (snap1.j->>'snapshot_timestamptz')::timestamptz from snap1, snap2 ),
    'absolute_error_calls'::text, (select absolute_error_calls from calc_error),
    'absolute_error_total_time'::text, (select absolute_error_total_time from calc_error),
    'relative_error_calls'::text, (select relative_error_calls from calc_error),
    'relative_error_total_time'::text, (select relative_error_total_time from calc_error),
    'queries', json_object_agg(queries.rownum, queries.*),
    'aggregated', (select json_object_agg(1, aggregated.*) from aggregated),
    'workload_type', (select json_object_agg(workload_type.rownum, workload_type.*) from workload_type)
  )
  from queries
"

# save sql result to variable
JSON=$(${CHECK_HOST_CMD} "${_PSQL} -f -" <<SQL
  ${change_db_cmd}
  ${sql}
SQL
      )

# for each query of K003 (of 50), generate file with query and link to the file
for query_num in $(jq -r '.queries | keys | .[]' <<<${JSON}); do

  query_text=$(jq -r '.queries."'$query_num'".query' <<<${JSON})
  current_bytes=$(echo "$query_text" | wc -c | awk '{ print $1 }')
  queryid=$(jq -r '.queries."'$query_num'".queryid' <<<${JSON})

  # Put query into a file
  mkdir -p "${JSON_REPORTS_DIR}/K_query_groups" >/dev/null 2>&1 || true
  echo "-- queryid: ${queryid}" > "${JSON_REPORTS_DIR}/K_query_groups/${query_num}_${ALIAS_INDEX}.sql"
  echo "-- NOTICE: the first 50k characters" >> "${JSON_REPORTS_DIR}/K_query_groups/${query_num}_${ALIAS_INDEX}.sql"
  echo "-- NOTICE: current query size (bytes): '${current_bytes}'" >> "${JSON_REPORTS_DIR}/K_query_groups/${query_num}_${ALIAS_INDEX}.sql"
  echo "$query_text" >> "${JSON_REPORTS_DIR}/K_query_groups/${query_num}_${ALIAS_INDEX}.sql"

  # Generate link to a full text
  link="../../json_reports/${TIMESTAMP_DIRNAME}/K_query_groups/${query_num}_${ALIAS_INDEX}.sql"
  readable_queryid="${query_num}_${ALIAS_INDEX}"

  # add link into the object
  JSON=$(jq --arg link $link -r '.queries."'$query_num'" += { "link": $link }' <<<${JSON})
  JSON=$(jq --arg readable_queryid $readable_queryid -r '.queries."'$query_num'" += { "readable_queryid": $readable_queryid }' <<<${JSON})
done

echo "${JSON}" | jq '.queries | .[]' | jq -cs 'sort_by(-.per_sec_calls)' | jq -r '. | map({"query": .query, "per_sec_calls": .per_sec_calls, "ratio_calls": .ratio_calls, "per_call_total_time":.per_call_total_time, "ratio_total_time":.ratio_total_time, "per_call_rows":.per_call_rows, "ratio_rows":.ratio_rows})' > ${JSON_REPORTS_DIR}/K000_top_frequent.json

JSON=$(jq --argfile top_frequent "${JSON_REPORTS_DIR}/K000_top_frequent.json" -r '. += { "top_frequent": $top_frequent }' <<<${JSON})

rm ${JSON_REPORTS_DIR}/K000_top_frequent.json

# print resulting JSON to stdout
echo "${JSON}"

# Inspired by DataEgret's https://github.com/dataegret/pg-utils/blob/master/sql/global_reports/query_stat_total.sql

# Useful PostgreSQL utilities.
#
#Copyright (c) 2011-2014, PostgreSQL-Consulting.com
#
#Permission to use, copy, modify, and distribute this software and its documentation for any purpose, without fee, and without a written agreement is hereby granted, provided that the above copyright notice and this paragraph and the following two paragraphs appear in all copies.
#
#IN NO EVENT SHALL POSTGRESQL-CONSULTING.COM BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF POSTGRESQL-CONSULTING.COM HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#POSTGRESQL-CONSULTING.COM SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND POSTGRESQL-CONSULTING.COM HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
