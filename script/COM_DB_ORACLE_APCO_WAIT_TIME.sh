#!/bin/bash
LANG=C; export LANG

### ORACLE WAIT_TIME(대기/락/트랜잭션) 점검 ###
### Idle을 제외한 Active 세션의 CPU/Wait/Lock/TX 병목 확인 목적 ###

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
# [3] DB 접속 정보
#############################################################
DB_CONN="/ as sysdba"
#############################################################
# [4] JSON 이스케이프 함수
#############################################################
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
#############################################################
# [5] JSON 객체 출력 함수
#############################################################
function function_print() {
  local sql=$1
  local status=$2
  local header=$3
  local data=$4
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
# [6] SQL 실행 함수
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
    header=$(echo "$output" | head -1 | sed 's/^ *//;s/ *$//')
    data=$(echo "$output" | tail -n +2 | sed '/^$/d')
    function_print "$sql" "$status" "$header" "$data"
  done
}
#############################################################
# [7] SQL 목록 정의 (TMPF/SSEG/SSQL 제외)
#############################################################
SQLS=(
# 1. OCPU - Active Session 정보
"SELECT 'OCPU-'||TO_CHAR(SYSDATE,'hh24:mi:ss') AS snaptime, a.sid, a.serial#, b.spid, NVL(a.username,'NoUser') AS username,
        SUBSTR(NVL(a.module,'P:'||SUBSTR(DECODE(SUBSTR(a.program,1,7),'oracle@',SUBSTR(a.program,INSTR(a.program,'(',1)),a.program),1,20)),1,20) AS module,
        SUBSTR((SELECT object_name FROM dba_objects c WHERE c.object_id=row_wait_obj#),1,30) AS objname,
        a.sql_id,
        DECODE(type,'BACKGROUND',-1,last_call_et) AS LCET,
        TO_CHAR(ROUND(wait_time_micro/1000,2),'99,999,990.00')||'/'||TO_CHAR(ROUND(time_since_last_wait_micro/1000/1000,2),'9990') AS wtm_tslwm,
        SUBSTR(a.event,1,30) AS event,
        a.p1||'.'||a.p2||'.'||a.p3 AS p123,
        row_wait_file# AS rwf#, row_wait_block# AS rwb#, row_wait_row# AS rwr#, b.pid, a.osuser
FROM v\$session a, v\$process b
WHERE a.paddr = b.addr(+) AND a.status='ACTIVE' AND a.state <> 'WAITING' AND a.wait_class <> 'Idle'
ORDER BY a.event"
# 2. LockTree - 잠금 관계 트리 조회
"WITH v AS (
    SELECT DECODE(request,0,'Holder','Waiter') AS who,
           DECODE(request,0,id1||'-'||id2,inst_id||'-'||sid) AS id,
           DECODE(request,0,inst_id||'-'||sid,id1||'-'||id2) AS pid,
           inst_id,sid,id1,id2,lmode,request,type,ctime
    FROM gv\$lock
    WHERE (id1,id2,type) IN (SELECT id1,id2,type FROM gv\$lock WHERE request > 0)
      AND type IN ('TM','TX')
)
SELECT 'LTRE-'||TO_CHAR(SYSDATE,'hh24:mi:ss') AS snaptime,
       LPAD('',(LVL/2))||LVL/2 AS Lev,
       LPAD(' ',(LVL-2))||a.inst_id||'-'||a.sid||','||a.serial# AS \"I#-SID,SRL#\",
       DECODE(l.request,0,'H','W') AS hold,
       DECODE(l.lmode,1,'None',2,'RS',3,'RX',4,'S',5,'SRX',6,'X','') AS mod,
       DECODE(l.request,1,'None',2,'RS',3,'RX',4,'S',5,'SRX',6,'X','') AS req,
       l.ctime AS ctime, SUBSTR(a.status,1,3) AS sta, b.spid, a.username,
       SUBSTR(NVL(a.module,'P:'||SUBSTR(DECODE(SUBSTR(a.program,1,7),'oracle@',SUBSTR(a.program,INSTR(a.program,'(',1)),a.program),1,20)),1,20) AS module,
       a.sql_id, SUBSTR(c.name,1,30) AS objname, l.type, a.event, a.p1||'.'||a.p2||'.'||a.p3 AS p123,
       DECODE(row_wait_obj#,-1,'','('||row_wait_obj#||','||row_wait_file#||','||row_wait_block#||','||row_wait_row#||')') AS wait_rowid,
       (SELECT REPLACE(SUBSTRB(sql_text,1,20),CHR(10),'\\') FROM gv\$sqlstats WHERE inst_id = a.inst_id AND sql_id = a.sql_id AND ROWNUM = 1) AS sql_text
FROM (
    SELECT who,inst_id,sid,id1,id2,lmode,request,type,ctime,2*LEVEL LVL
    FROM v
    START WITH request = 0
    CONNECT BY PRIOR id = pid AND (request > 0 OR (request = 0 AND PRIOR id <> pid))
) l, gv\$session a, gv\$process b, sys.obj$ c
WHERE l.inst_id = a.inst_id AND l.sid = a.sid AND a.inst_id = b.inst_id AND a.paddr = b.addr AND a.row_wait_obj# = c.obj#(+)
ORDER BY id1, lvl"
# 3. Big TX - Undo 블록 50,000 이상 트랜잭션
"SELECT 'BTXS-'||TO_CHAR(SYSDATE,'hh24:mi:ss') AS snaptime, a.inst_id AS \"I#\", a.sid, a.serial#, b.spid,
        a.username, SUBSTR(a.program,1,20) AS program, SUBSTR(a.module,1,20) AS module,
        a.sql_id, a.status, c.used_ublk AS tx_ublk, c.used_urec AS tx_urec,
        ROUND((SYSDATE - c.start_date)*24*60,0) AS howlong_min, a.machine,
        TO_CHAR(ROUND(wait_time_micro/1000,2),'99,999,990.00')||'/'||TO_CHAR(ROUND(time_since_last_wait_micro/1000/1000,2),'9990') AS wtm_tslwm,
        SUBSTR(a.event,1,30) AS event
FROM gv\$session a, gv\$process b, gv\$transaction c
WHERE a.inst_id=b.inst_id AND a.inst_id=c.inst_id AND a.paddr=b.addr AND a.taddr=c.addr
  AND a.type<>'BACKGROUND' AND c.used_ublk>=50000
ORDER BY a.username, a.machine, a.sql_id, a.sid"
# 4. Long TX - 1800초 이상 트랜잭션
"SELECT 'LTXS-'||TO_CHAR(SYSDATE,'hh24:mi:ss') AS snaptime, a.inst_id AS \"I#\", a.sid, a.serial#, b.spid,
        a.username, SUBSTR(a.program,1,20) AS program, SUBSTR(a.module,1,20) AS module,
        a.sql_id, a.status, c.used_ublk AS tx_ublk, c.used_urec AS tx_urec,
        ROUND((SYSDATE - c.start_date)*24*60,0) AS howlong_min, a.machine,
        TO_CHAR(ROUND(wait_time_micro/1000,2),'99,999,990.00')||'/'||TO_CHAR(ROUND(time_since_last_wait_micro/1000/1000,2),'9990') AS wtm_tslwm,
        SUBSTR(a.event,1,30) AS event
FROM gv\$session a, gv\$process b, gv\$transaction c
WHERE a.inst_id=b.inst_id AND a.inst_id=c.inst_id AND a.paddr=b.addr AND a.taddr=c.addr
  AND a.type<>'BACKGROUND' AND (SYSDATE - c.start_date)*86400 > 1800
ORDER BY a.username, a.machine, a.sql_id, a.sid"
)
#############################################################
# [8] 실행 시작
#############################################################
function_main() {
  local host_raw host_json
  host_raw=$(hostname -f 2>/dev/null || hostname)
  host_json=$(printf '%s' "$host_raw" | json_escape)
  echo "{"
  echo "  \"kind\": \"db_query\","
  echo "  \"host\": \"$host_json\","
  echo "  \"items\": ["
  echo "    {"
  echo "      \"data\": ["
  RUN_SQL "${SQLS[@]}"
  echo "      ],"
  echo "      \"status\": \"OK\""
  echo "    }"
  echo "  ]"
  echo "}"
}
function_main