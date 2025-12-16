#!/bin/sh
LANG=C; export LANG

function_docommand() {
  nproc=$(grep -c ^processor /proc/cpuinfo)
  # 결과를 한 줄로 만듦
  result=$(eval "$command" | awk -v cores=$nproc '{printf "%s %s %.1f%%\n", $1, $2, $3/cores}')
  # result에서 줄바꿈, 큰따옴표, 역슬래시 등 JSON에 문제될 수 있는 문자 처리
  result=$(echo "$result" | sed ':a;N;$!ba;s/\n/\\n/g')
  # JSON 출력
  printf "{\"command\":\"%s\",\"result\":\"%s\"}" "$command" "$result"
  
  CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)
  command="ps -eo user,pcpu --no-headers | awk -v cpu_count=$CPU_COUNT '{arr[\$1]+= \$2} END {for (i in arr) print i, arr[i]/cpu_count}' | sort -k2 -nr"
  result=$(eval "$command")
  # Serialize
  result=$(echo "$result" | sed ':a;N;$!ba;s/\n/\\n/g')
  # Print Json
  printf "{\"command\":\"%s\",\"result\":\"%s\"}" "$command" "$result"
  
}

function_docommand