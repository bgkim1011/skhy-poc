##########################################################################################################################  
##  
## File name: wincheck_daily
## Description: Script to check system daily.
## Information:
##
##========================================================================================================================
## version  date         author                 reason
##------------------------------------------------------------------------------------------------------------------------
## 1.0      2023.07.10   S.H.C                  First created.
## 
##########################################################################################################################
# ==================<<<< Important Global Variable Registration Area Marking Comment (Start)>>>>>=========================
  #[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==================<<<< Important Global Variable Registration Area Marking Comment (End)>>>>>===========================


# ==================<<<< Function Registration Area Marking Comment (Start)>>>>>==========================================
##########################################################################################################################
## Function name: Sub_print($object,$state,$detail)
## Description: Print execution results
## Information: 
## - When the function is called, each of the 3 variables receives its own values. The 3 variables are $object, $state and $detail. 
##  a. $object is the item to check, which is similar to the function name.
##  b. $state is the check result, which is either ok or check.
##  c. $detail is a detailed execution result, and is only printed if $state is checked.
##########################################################################################################################
Function Sub_print($object,$state,$detail)
{
    # Print Out

    $result="{`n"+ '"title"' + ":" + '"'+"$object"+""",`n" + '"result"' + ':'+'"'+"$state"+""",`n" 
    #$UTF8result=[System.Text.Encoding]::UTF8.GetString($result)
    #$UTFdetail= [System.Text.Encoding]::UTF8.GetString($detail)

    if($result){
     $result + '"value"' + ':' + '"'+"$detail"+"""`n"+"},"
     } else {
     #$result + '"value"' + ':' + '"'+"$detail"+"""`n"+"},"
     
    }

    
}

##########################################################################################################################
## Function name: Head Print
## Description: Print Title
## Information: 
##########################################################################################################################
Function Head_print
{
    '{
     "kind":"single",
     "items":[
        {
            "status":"OK",
            "data":[  '

}
##########################################################################################################################
## Function name: Head Print
## Description: Print Title
## Information: 
##########################################################################################################################
Function End_print
{
    '{}],
    "output":{
        "product":"window"
     }
    }
    ]
    }'

}
##########################################################################################################################
## Function name: Check-Uptime
## Description: Check system uptime
## Information: The uptime check creteria is 2 year. Less than 1 year is normal and the result is displayed as "ok".
##              Otherwise, it is marked as "check" and needs confirmation. 
##########################################################################################################################
Function Check-Uptime
{
    $object = 'Uptime'
    $os = Get-Wmiobject win32_operatingsystem
    $uptime = (Get-Date) - ($os.ConvertToDateTime($os.lastbootuptime))

    $days=$uptime.Days
    $hours=$uptime.Hours
    $minutes=$uptime.Minutes

    if($Uptime.Days -gt 1){
        $state = 'OK'
        $detail =  "$days days, $hours hours, $minutes minutes"    
    } else{
        $state = 'Warning'
        $detail =  "$days days, $hours hours, $minutes minutes"
    }
    sub_print $object $state $detail
}

# ==================<<<< Function Registration Area Marking Comment (End)>>>>>==========================================

# ==================<<<< Main Logic Area Marking Comment (Start)>>>>>=====================================================

Head_print

Check-Uptime

End_print

# ==================<<<< Main Logic Area Marking Comment (End)>>>>>=====================================================


