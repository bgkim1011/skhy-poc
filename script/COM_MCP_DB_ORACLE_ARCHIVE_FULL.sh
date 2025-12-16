#!/bin/bash
LANG=C; export LANG
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
# [4] JSON Escape 함수
#############################################################
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
#############################################################
# [5] JSON 출력 함수
#############################################################
function function_print() {
  local sql=$1 status=$2 header=$3 data=$4
  echo "{"
  echo "  \"sql\": \"$(printf '%s' "$sql" | json_escape)\","
  echo "  \"status\": \"$(printf '%s' "$status" | json_escape)\","
  echo "  \"columns\": \"$(printf '%s' "$header" | json_escape)\","
  echo "  \"rows\": \"$(printf '%s' "$data" | json_escape)\""
  echo "}"
}
#############################################################
# [6] SQL 실행 함수
#############################################################
function RUN_SQL() {
  local first_item=1
  for sql in "$@"; do
    [ $first_item -eq 0 ] && echo ","; first_item=0
    local output status="OK"
    output=$(
      sqlplus -s "$DB_CONN" <<EOF 2>&1
set heading on
set feedback off
set linesize 10000
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
    function_print "$sql" "$status" "$header" "$data"
  done
}
#############################################################
# [7] 메인 JSON Wrapper
#############################################################
function function_main() {
  local host_raw=$(hostname -f 2>/dev/null || hostname)
  local host_json=$(printf '%s' "$host_raw" | json_escape)
  echo "{"
  echo "  \"kind\": \"db_archive_check\","
  echo "  \"host\": \"$host_json\","
  echo "  \"items\": ["
  echo "    {"
  echo "      \"data\": ["
  #############################################################
  # [A] 아카이브 경로 추출 (location=, mandatory 대소문자 무시)
  #############################################################
  ARCH_PATH=$(sqlplus -s "$DB_CONN" <<EOF
set heading off feedback off verify off echo off
select trim(
         regexp_replace(
           regexp_replace(
             value,
             '(?i).*location *= *', ''        -- location= / LOCATION=
           ),
           '(?i) *mandatory.*', ''            -- mandatory / MANDATORY / Mandatory
         )
       )
  from v\$parameter
 where name = 'log_archive_dest_1';
exit
EOF
  )
  ARCH_PATH=$(echo "$ARCH_PATH" | grep -v "^$" | tail -1 | tr -d '[:space:]')
  [ -z "$ARCH_PATH" ] && ARCH_PATH="UNKNOWN"
  SQLS=(
# ① 아카이브 모드 및 경로
"select 'ARC_LOC' gubun,
       log_mode,
       name db_name,
       (select value from v\$parameter where name='log_archive_dest_1') archive_dest
from v\$database"
# ② 저장소 유형 (ASM / FILESYSTEM)
"select 'ARC_TYPE' gubun,
        case when upper(value) like '+%' then 'ASM' else 'FILESYSTEM' end storage_type,
        value archive_dest
  from v\$parameter
 where name='log_archive_dest_1'"
# ③ ASM 환경: 오래된 아카이브 로그 TOP 20
"select * from (
        select 'ASM_OLD' gubun,
               f.inst_id,
               g.name diskgroup_name,
               a.name asm_file_name,
               round(f.bytes/1024/1024/1024,2) size_gb,
               to_char(f.creation_date,'YYYY-MM-DD HH24:MI:SS') creation_date
          from gv\$asm_file f
          join gv\$asm_alias a
            on f.group_number = a.group_number
           and f.file_number = a.file_number
           and f.inst_id = a.inst_id
          join gv\$asm_diskgroup g
            on f.group_number = g.group_number
           and f.inst_id = g.inst_id
         where f.type = 'ARCHIVELOG'
         order by f.creation_date
     ) where rownum <= 20"
# ④ FILESYSTEM 환경: 오래된 아카이브 로그 TOP 20 (blocks × block_size)
"select * from (
        select 'FS_OLD' gubun,
               name file_name,
               to_char(completion_time,'YYYY-MM-DD HH24:MI:SS') completion_time,
               round(blocks * block_size / 1024 / 1024 / 1024, 2) file_size_gb
          from v\$archived_log
         where deleted='NO'
         order by completion_time
     ) where rownum <= 20"
  )
  RUN_SQL "${SQLS[@]}"
  #############################################################
  # [B] Filesystem 환경일 경우 df -h 출력 추가
  #############################################################
  if [[ "$ARCH_PATH" != +* && "$ARCH_PATH" != "USE_DB_RECOVERY_FILE_DEST" && "$ARCH_PATH" != "UNKNOWN" ]]; then
    echo ","
    DF_OUTPUT=$(df -h "$ARCH_PATH" 2>/dev/null | tail -n +2)
    DF_HEADER=$(df -h "$ARCH_PATH" 2>/dev/null | head -1 | tr -s ' ')
    function_print "df -h $ARCH_PATH" "OK" "$DF_HEADER" "$DF_OUTPUT"
  fi
  echo "      ],"
  echo "      \"status\": \"OK\","
  echo "      \"ai_hint\": \"ASM 환경에서는 gv\\$asm_file + gv\\$asm_alias join으로 ARCHIVELOG 파일명을 조회합니다. \
FILESYSTEM 환경에서는 blocks×block_size 기반 크기 계산과 df -h 사용률을 함께 확인합니다. \
mandatory 옵션은 자동 제거되며, old 아카이브가 많더라도 log switch frequency 및 delete 정책을 함께 검토해야 합니다.\""
  echo "    }"
  echo "  ]"
  echo "}"
}
#############################################################
# [8] 실행 시작
#############################################################
function_main