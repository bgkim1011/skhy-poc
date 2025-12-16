#!/bin/sh
LANG=C; export LANG

function_docommand() {
  TARGET_TS=$(date -d "10 min ago" +%s)
  YEAR=$(date +%Y)
 command='
FOUND=0
while IFS= read -r line; do
  if [[ $FOUND -eq 1 ]]; then
        echo "$line"
        continue
  fi

  ts=$(echo "$line" | awk "{print \$1, \$2, \$3}")
  log_ts=$(date -d "$ts $YEAR" +%s 2>/dev/null)
  
  if [[ -z "$log_ts" ]]; then
    continue
  fi
  if [[ $log_ts -gt $TARGET_TS ]]; then
    FOUND=1
    echo "$line"
  fi
done < /var/log/messages
'
  
  result=$(eval "$command")
  # Serialize
  result=$(echo "$result" | sed ':a;N;$!ba;s/\n/\\n/g')
  # Print Json
  printf "{\"command\":\"cat /var/log/messages\",\"result\":\"%s\"}" "$result"
}

function_main() {
  function_docommand
}

function_main