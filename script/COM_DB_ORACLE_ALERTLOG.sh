#!/bin/bash
# 1. 루트 계정이면 Oracle 유저로 전환
if [ "$(id -u)" -eq 0 ]; then
  ORA_USER=$(ps -ef | grep "[p]mon" | grep -v "+ASM" | awk '{print $1}' | sort | uniq | head -n 1)
  if [ -z "$ORA_USER" ]; then
    echo "Oracle 유저를 찾을 수 없습니다."
    exit 1
  fi
#  if [ -z "$ORACLE_SID" ]; then
#    echo "ORACLE_SID 환경변수가 설정되지 않았습니다."
#    exit 1
#  fi
  SCRIPT_PATH=$(readlink -f "$0")
  su - "$ORA_USER" -c "bash -c 'source ~/.bash_profile; ORACLE_SID=$ORACLE_SID $SCRIPT_PATH $1'"
  exit 0
fi


source ~/.bash_profile


export LANG=C
# 2. ORACLE_SID 확인
if [ -z "$ORACLE_SID" ]; then
  echo "ORACLE_SID 환경변수가 설정되지 않았습니다."
  exit 1
fi
# 3. Alert 로그 경로 조회
ALERT_DIR=$(sqlplus -s / as sysdba <<EOF
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TIMING OFF
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
EOF
)
ALERT_DIR=$(echo "$ALERT_DIR" | xargs)
ALERTLOG="$ALERT_DIR/alert_${ORACLE_SID}.log"
# 4. 날짜 인자 확인
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 [yyyymmdd] (예: $0 20250715)"
  exit 1
fi
# 5. 날짜 파싱
YEAR=${1:0:4}
MNTH=${1:4:2}
DAY=${1:6:2}
DAY_NUM=$((10#$DAY))
ISO_DATE="${YEAR}-${MNTH}-${DAY}"
case "$MNTH" in
  "01") MONTH_NAME="Jan" ;;
  "02") MONTH_NAME="Feb" ;;
  "03") MONTH_NAME="Mar" ;;
  "04") MONTH_NAME="Apr" ;;
  "05") MONTH_NAME="May" ;;
  "06") MONTH_NAME="Jun" ;;
  "07") MONTH_NAME="Jul" ;;
  "08") MONTH_NAME="Aug" ;;
  "09") MONTH_NAME="Sep" ;;
  "10") MONTH_NAME="Oct" ;;
  "11") MONTH_NAME="Nov" ;;
  "12") MONTH_NAME="Dec" ;;
  *) echo "Invalid month"; exit 1 ;;
esac
# 6. 시작 라인 탐색
STARTLINE=$(awk -v iso="$ISO_DATE" -v mon="$MONTH_NAME" -v day="$DAY_NUM" '{
  line++
  if (index($0, iso) > 0 || index($0, mon " " day) > 0) {
    print line
    exit
  }
}' line=0 "$ALERTLOG")
[ -z "$STARTLINE" ] && STARTLINE=1
# 7. 시스템 정보
HOSTNAME=$(hostname)
INSTANCE_NAME=$(ps -ef | grep "[p]mon" | grep "$ORACLE_SID" | awk -F_ '{print $3}')
DBSTATUS=$(sqlplus -s / as sysdba <<EOF
set pages 0 feedback off timing off
select status from v\$instance;
exit;
EOF
)
DBSTATUS=$(echo "$DBSTATUS" | xargs)
# 8. JSON 출력
echo "{"
echo "  \"hostname\": \"$HOSTNAME\","
echo "  \"instance_name\": \"$INSTANCE_NAME\","
echo "  \"status\": \"$DBSTATUS\","
echo "  \"alertlog_path\": \"$ALERTLOG\","
echo "  \"alerts\": ["
awk -v start=$STARTLINE '
function normalize_time(line) {
  gsub(/\*\*\*/, "", line)
  gsub("T", " ", line)
  gsub(/\..*/, "", line)
  split(line, a, " ")
  m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04"; m["May"]="05"; m["Jun"]="06"
  m["Jul"]="07"; m["Aug"]="08"; m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12"
  if (line ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/) return substr(line, 1, 19)
  else if (length(a[1]) == 3 && length(a[2]) == 3 && a[3] ~ /^[0-9]+$/) return a[5] "-" m[a[2]] "-" sprintf("%02d", a[3]) " " a[4]
  else if (length(a[1]) == 3 && a[2] ~ /^[0-9]+$/) return a[4] "-" m[a[1]] "-" sprintf("%02d", a[2]) " " a[3]
  else if (length(a[1]) == 10 && a[2] ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) return a[1] " " a[2]
  return "UNKNOWN"
}
BEGIN {
  first = 1
  prev1 = prev2 = ""
}
NR >= start {
  current = $0
  prev2 = prev1; prev1 = current
  if (current ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)? ?[A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}/ || current ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T?[0-9]{2}:[0-9]{2}:[0-9]{2}/ || current ~ /^\*\*\* *[0-9]{4}-[0-9]{2}-[0-9]{2}/) {
    dtime = normalize_time(current)
  }
  if (current ~ /ORA-1653|ORA-1688|ORA-01013|ORA-3136/) next
  if (current ~ /ORA-|^Starting ORACLE instance|^Shutting down instance|^Checkpoint not complete|evict/) {
    if (!first) printf(",\n")
    printf("    {\"time\": \"%s\", \"message\": [", dtime)
    gsub(/"/, "\\\"", prev2); gsub(/"/, "\\\"", prev1); gsub(/"/, "\\\"", current)
    printed = 0
    if (prev2 ~ /^[A-Z]/) { printf("\"%s\"", prev2); printed++ }
    if (prev1 ~ /^[A-Z]/ && prev1 != prev2) { if (printed) printf(", "); printf("\"%s\"", prev1); printed++ }
    if (printed) printf(", "); printf("\"%s\"]}", current)
    first = 0
  }
}
' "$ALERTLOG"
echo ""
echo "  ]"
echo "}"