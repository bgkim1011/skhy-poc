
#!/bin/bash
LANG=C; export LANG

### ORACLE TEMP TABLESPACE 사용 현황 확인 ###

#############################################################
# [1] root로 실행 시 → DB 인스턴스 기동 유저로 전환
#############################################################
CURDIR=$(pwd)
if [ "$(id -u)" -eq 0 ]; then
  ORA_OS_USER=$(ps -eo user,comm | grep -E "ora_pmon_" \
    | grep -v grep | grep -v "\+ASM" | awk '{print $1}' | head -1)
  if [ -z "$ORA_OS_USER" ]; then
    echo "Oracle DB 인스턴스를 기동한 OS 유저를 찾을 수 없습니다." >&2
    exit 1
  fi
  if [ "$ORA_OS_USER" != "root" ]; then
    exec su - "$ORA_OS_USER" -c "cd \"$CURDIR\" && bash \"$0\""
    exit $?
  fi
fi
#############################################################
# [2] Oracle 환경 변수 로드
#############################################################
if [ -f /etc/profile ]; then . /etc/profile; fi
if [ -f "${HOME}/.bash_profile" ]; then
  . "${HOME}/.bash_profile"
elif [ -f "${HOME}/.profile" ]; then
  . "${HOME}/.profile"
fi
#############################################################
# [3] DB 접속 정보 (sys로 변경)
#############################################################
DB_CONN="/ as sysdba"
#############################################################
# [4] JSON 이스케이프 (SQL text, module, hostname에 ",\ 포함 가능)
#############################################################
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
#############################################################
# [5] JSON 객체 출력
#############################################################
function function_print() {
  local sql=$1
  local status=$2
  local header=$3
  local data=$4
  local sql_json status_json header_json data_json
  sql_json=$(printf '%s' "$sql" | json_escape)
  status_json=$(printf '%s' "$status" | json_escape)
  header_json=$(printf '%s' "$header" | json_escape)
  data_json=$(printf '%s' "$data" | json_escape)
  echo "{"
  echo "  \"sql\": \"$sql_json\","
  echo "  \"status\": \"$status_json\","
  echo "  \"columns\": \"$header_json\","
  echo "  \"rows\": \"$data_json\""
  echo "}"
}
#############################################################
# [6] SQL 실행 함수 (sys 권한으로)
#############################################################
function RUN_SQL() {
  local first_item=1
  for sql in "$@"; do
    if [ $first_item -eq 0 ]; then
      echo ","
    fi
    first_item=0
    local output status="OK"
    output=$(
      sqlplus -s "$DB_CONN" <<EOF 2>&1
set heading on
set feedback off
set pagesize 500
set linesize 10000
set trimspool on
set termout off
set colsep '|'
whenever sqlerror exit failure rollback
${sql};
exit
EOF
    )
    if [ $? -ne 0 ]; then
      status="NG"
    fi
    local header data
    header=$(echo "$output" | head -1 | sed 's/^ *//;s/ *$//')
    data=$(echo "$output" | tail -n +2 | sed '/^$/d')
    function_print "$sql" "$status" "$header" "$data"
  done
}
#############################################################
# [7] JSON Wrapper
#############################################################
function function_main() {
  local host_raw host_json
  host_raw=$(hostname -f 2>/dev/null || hostname)
  host_json=$(printf '%s' "$host_raw" | json_escape)
  echo "{"
  echo "  \"kind\": \"db_query\","
  echo "  \"host\": \"$host_json\","
  echo "  \"items\": ["
  echo "    {"
  echo "      \"data\": ["
  SQLS=(
# TEMP 전체 Free 용량
"select 'TMPF:'||to_char(sysdate,'hh24miss') gubun, 'TEMP' tablespace_name,
       case when (round(((select sum(bytes) from dba_temp_files where tablespace_name='TEMP')
                        -(select sum(total_blocks)*8192 from gv\$sort_segment where tablespace_name='TEMP'))
                        /1024/1024/1024,2) <= 0)
            then 0
            else round(((select sum(bytes) from dba_temp_files where tablespace_name='TEMP')
                        -(select sum(total_blocks)*8192 from gv\$sort_segment where tablespace_name='TEMP'))
                        /1024/1024/1024,2)
       end free_gb
from dual"

# gv$sort_segment 기반 TEMP 사용 현황
"select 'SSEG:'||to_char(sysdate,'hh24miss') gubun
      ,tablespace_name, decode(grouping(inst_id),1,'Total',inst_id) inst_id
      ,to_char(sum(round(total_blocks*8192/1024/1024/1024,2)),'99990.00') cur_total_gb
      ,to_char(sum(round(used_blocks *8192/1024/1024/1024,2)),'99990.00') cur_used_gb
      ,to_char(sum(round(free_blocks *8192/1024/1024/1024,2)),'99990.00') cur_free_gb
      ,to_char(sum(round(max_blocks  *8192/1024/1024/1024,2)),'99990.00') max_all_op_used_gb
      ,to_char(sum(round(max_used_blocks*8192/1024/1024/1024,2)),'99990.00') max_all_sort_used_gb
      ,to_char(sum(round(max_sort_blocks*8192/1024/1024/1024,2)),'99990.00') max_one_sort_used_gb
      ,sum(extent_hits) extent_hits
from gv\$sort_segment
group by tablespace_name, rollup(inst_id)
order by 1,2,3"

# TEMP 많이 쓰는 SQL TOP 분석
"select 'SSQL:'||to_char(sysdate,'hh24miss') gubun
      ,a.inst_id
      ,a.tablespace tbs
      ,nvl(b.sql_id,a.sql_id) sql_id
      ,count(*) pq_cnt
      ,to_char(round(sum(a.blocks)*8192/1024/1024/1024,2),'9,999.00') sz_gbytes
      ,max(b.username) username
      ,max(substr(b.module,1,30)) module
      ,substr(c.sql_text,1,80) sql_text
from gv\$sort_usage a, gv\$session b, gv\$sqlstats c
where a.inst_id = b.inst_id
  and a.session_addr = b.saddr
  and a.inst_id = c.inst_id
  and b.sql_id = c.sql_id
group by a.inst_id, a.tablespace, nvl(b.sql_id,a.sql_id), substr(c.sql_text,1,80)
having sum(a.blocks)*8192/1024/1024/1024 >= 1
order by a.inst_id, a.tablespace, nvl(b.sql_id,a.sql_id)"
  )

  RUN_SQL "${SQLS[@]}"
  echo "      ],"
  echo "      \"status\": \"OK\""
  echo "    }"
  echo "  ]"
  echo "}"
}
#############################################################
# [8] 실행 시작
#############################################################
function_main
