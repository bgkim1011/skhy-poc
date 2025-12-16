#!/bin/sh
LANG=C; export LANG
status="OK"

function_uptime()
{
local title="UPTIME CHECK"
local result="OK"
local value=""

uptime_tmp=$(uptime)

uptime_str=$(echo $uptime_tmp | awk -F"up " '{print $2}' | awk -F"," '{print $1}')

if [[ $uptime_str != *"day"* ]]; then
        local result="NOK"
        status="NOK"
fi

local value=`uptime`
# 표준 print함수 호출
function_print "${title}" "${result}" "${value}"
}
# 표준 print 함수
function_print()
{
    local title=${1}
    local result=${2}
    local value=${3}
    echo '    {'
    echo '     "title" : "'$title'",'
    echo '     "result" : "'$result'",'
    echo '     "value" : "'"$value"'"'
    echo '    },'
}

# 표준 main 함수
function_main()
{
    echo '{'
    echo '"kind" : "single",'
    echo '"items" : ['
    echo '  {'
    echo '    "data" : ['
                function_uptime # 필요한 함수 호출
    echo '    {}],'
    echo '    "output" : {'
    echo '    },'
    echo '    "status" : "'${status}'"' # opmate task의 결과
    echo '  }'
    echo ']'
    echo '}'
}
function_main
