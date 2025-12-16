#!/bin/bash
LANG=C; export LANG

### ORACLE HANG 점검 (DB/OS Health Check) ###

#############################################################
# [1] root → Oracle 기동 유저 전환
#############################################################
CURDIR=$(pwd)
if [ "$(id -u)" -eq 0 ]; then
  ORA_OS_USER=$(ps -eo user,comm | grep -E "ora_pmon_" \
    | grep -v grep | grep -v "\+ASM" | awk '{print $1}' | head -1)
  [ -z "$ORA_OS_USER" ] && { echo "Oracle OS 유저를 찾을 수 없습니다."; exit 1; }
  [ "$ORA_OS_USER" != "root" ] && exec su - "$ORA_OS_USER" -c "cd \"$CURDIR\" && bash \"$0\""
fi
#############################################################
# [2] Oracle 환경 로드
#############################################################
[ -f /etc/profile ] && . /etc/profile
[ -f "${HOME}/.bash_profile" ] && . "${HOME}/.bash_profile"
[ -f "${HOME}/.profile" ] && . "${HOME}/.profile"
#############################################################
# [3] DB 접속 정보
#############################################################
DB_CONN="/ as sysdba"
#############################################################
# [4] JSON 유틸 함수
#############################################################
json_escape(){ sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
function print_json() {
  local sql=$1 status=$2 header=$3 data=$4
  echo "{"
  echo "  \"sql\": \"$(printf '%s' "$sql" | json_escape)\","
  echo "  \"status\": \"$(printf '%s' "$status" | json_escape)\","
  echo "  \"columns\": \"$(printf '%s' "$header" | json_escape)\","
  echo "  \"rows\": \"$(printf '%s' "$data" | json_escape)\""
  echo "}"
}
#############################################################
# [5] SQL 실행 함수
#############################################################
run_sql() {
  local sql="$1"
  local output status="OK"
  output=$(
    sqlplus -s "$DB_CONN" <<EOF 2>&1
set heading on
set feedback off
set linesize 32767
set pagesize 200
set trimspool on
set termout off
set colsep '|'
whenever sqlerror exit failure rollback
${sql};
exit
EOF
  )
  [ $? -ne 0 ] && status="NG"
  local header data
  header=$(echo "$output" | head -1 | sed 's/^ *//;s/ *$//')
  data=$(echo "$output" | tail -n +2 | sed '/^$/d')
  print_json "$sql" "$status" "$header" "$data"
}
#############################################################
# [6] 주요 점검 SQL
#############################################################
# 1. DB 응답 체크
Q_PING="select 'PING' gubun, to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') now from dual"
# 2. 인스턴스 상태 + 기동시간
Q_INSTANCE="select 'INSTANCE' gubun, instance_name, host_name, status, database_status, logins,
       to_char(startup_time,'YYYY-MM-DD HH24:MI:SS') startup_time,
       to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') current_time
from v\$instance"
# 3. DB 모드
Q_DB="select 'DATABASE' gubun, name db_name, open_mode, log_mode, checkpoint_change#
from v\$database"
# 4. 주요 백그라운드 프로세스 상태
Q_BGPROC="select 'BGPROC' gubun, pname, program, status
from v\$process
where pname in ('PMON','SMON','LGWR','CKPT','DBW0','ARC0')
order by pname"
# 5. Active 세션 Top 30
Q_ACTIVE_SESS="select * from (
 select 'SESS_ACTIVE' gubun, sid, serial#, nvl(username,'-') username,
        status, substr(event,1,50) event, state, seconds_in_wait sec_wait
 from v\$session
 where type='USER' and status='ACTIVE'
 order by seconds_in_wait desc
) where rownum <= 30"
# 6. Blocking 세션 Top 20
Q_BLOCKING="select * from (
 select 'BLOCK' gubun, sid, serial#, username, blocking_session, event,
        seconds_in_wait, wait_class
 from v\$session
 where blocking_session is not null
 order by seconds_in_wait desc
) where rownum <= 20"
# 7. Log file sync (Redo 동기화 지연)
Q_LOGSYNC="select 'LOG_SYNC' gubun,
       total_waits, round(time_waited/100,2) time_waited_s,
       round(case when total_waits=0 then 0 else time_waited/total_waits end,2) avg_ms
from v\$system_event
where event='log file sync'"
# 8. Undo / Temp 사용 현황
Q_UNDO_TEMP="select 'UNDO_TEMP' gubun,
       (select round(sum(bytes)/1024/1024/1024,2) from dba_undo_extents) undo_gb,
       (select round(sum(bytes)/1024/1024/1024,2) from dba_temp_files) temp_gb,
       (select round(sum(used_blocks*8192)/1024/1024/1024,2) from v\$sort_segment) temp_used_gb
from dual"
# 9. 시스템 이벤트 Top 15 (Idle 제외)
Q_SYSTEM_EVENT="select * from (
 select 'WAIT_TOP' gubun, substr(event,1,40) event,
        total_waits, round(time_waited/100,2) waited_s
 from v\$system_event
 where wait_class <> 'Idle'
 order by time_waited desc
) where rownum <= 15"
#############################################################
# [7] OS 레벨 점검
#############################################################
os_check() {
  HEADER="metric|value"
  LOAD=$(uptime 2>/dev/null | sed 's/^ *//')
  TOPPROC=$(ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 6 | tr -s ' ')
  DATA="OS Load: ${LOAD}\n\nTop Oracle/CPU Proc:\n${TOPPROC}"
  print_json "OS_STATUS" "OK" "$HEADER" "$DATA"
}
#############################################################
# [8] 실행
#############################################################
function_main() {
  local host_raw=$(hostname -f 2>/dev/null || hostname)
  local host_json=$(printf '%s' "$host_raw" | json_escape)
  echo "{"
  echo "  \"kind\": \"db_health_check\","
  echo "  \"host\": \"$host_json\","
  echo "  \"items\": ["
  echo "    {"
  echo "      \"data\": ["
  first=1
  for SQL in \
    "$Q_PING" "$Q_INSTANCE" "$Q_DB" "$Q_BGPROC" \
    "$Q_ACTIVE_SESS" "$Q_BLOCKING" "$Q_LOGSYNC" \
    "$Q_UNDO_TEMP" "$Q_SYSTEM_EVENT"
  do
    [ $first -eq 0 ] && echo ","; first=0
    run_sql "$SQL"
  done
  echo ","
  os_check
  echo "      ],"
  echo "      \"status\": \"OK\","
  echo "      \"ai_hint\": \"Oracle DB Health Check: \
1) PING/INSTANCE 로 DB 응답 및 STARTUP_TIME 확인, \
2) DATABASE OPEN_MODE 로 DB 상태 확인, \
3) ACTIVE/BLOCK 세션으로 교착 여부 판단, \
4) LOG_SYNC 및 SYSTEM_EVENT 로 I/O 지연 감지, \
5) UNDO/TEMP 사용률과 OS uptime 으로 병목 및 과부하 상태를 종합 판단합니다.\""
  echo "    }"
  echo "  ]"
  echo "}"
}
function_main