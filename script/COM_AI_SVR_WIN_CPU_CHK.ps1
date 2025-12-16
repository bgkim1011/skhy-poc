<# 
  cpu_snapshot.ps1  (stable per-process counter version)
  - 콘솔 출력만 (파일 저장 없음)
  - 기본값: SampleSec=5, RecentEventMin=1
  - 포함: 시간/호스트/업타임/코어수, CPU Total(+비율)·Queue, Top N 프로세스, 최근 경고/오류 이벤트
  사용:
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\scripts\cpu_snapshot.ps1
    (옵션) -TopN 10 -SampleSec 3 -RecentEventMin 2
#>

param(
  [int]$TopN = 5,
  [int]$SampleSec = 5,       # CPU% 샘플 간격(초)
  [int]$RecentEventMin = 1   # 최근 이벤트 조회(분)
)

function LP { (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
function UptimeHours { 
  $bt = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  [math]::Round(([datetime]::UtcNow - $bt).TotalHours,2)
}
function NowLocal { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

function Get-CpuTotals {
  $c = Get-Counter -Counter @(
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% User Time',
    '\Processor(_Total)\% Privileged Time',
    '\Processor(_Total)\% DPC Time',
    '\Processor(_Total)\% Interrupt Time',
    '\System\Processor Queue Length'
  ) -ErrorAction SilentlyContinue
  $m = @{}
  foreach($s in $c.CounterSamples){ $m[$s.Path.Split('\')[-1]] = [math]::Round($s.CookedValue,1) }
  [pscustomobject]@{
    CpuTotalPct  = $m['% Processor Time']
    CpuUserPct   = $m['% User Time']
    CpuPrivPct   = $m['% Privileged Time']
    CpuDpcPct    = $m['% DPC Time']
    CpuIntPct    = $m['% Interrupt Time']
    ProcQueueLen = [int]$m['Processor Queue Length']
  }
}

# --- Top N 프로세스 (성능카운터 기반) ---
function Get-TopProcesses([int]$n, [int]$intervalSec){
  # \Process(*)\ID Process  +  \Process(*)\% Processor Time
  $counters = Get-Counter -Counter @('\Process(*)\ID Process','\Process(*)\% Processor Time') `
                          -SampleInterval $intervalSec -MaxSamples 1 -ErrorAction SilentlyContinue
  if(-not $counters){ return @() }

  $pidByInst = @{}
  $cpuByPid  = @{}

  # 1) 인스턴스명 -> PID 매핑
  foreach($s in $counters.CounterSamples){
    $path = $s.Path
    $inst = ($path -split '\\')[-2] -replace '^Process\(|\)$',''  # e.g. svchost, sqlservr
    $name = ($path -split '\\')[-1]
    if($inst -in @('_Total','Idle')){ continue }
    if($name -eq 'ID Process'){
      $pidByInst[$inst] = [int]$s.CookedValue
    }
  }

  # 2) % Processor Time 을 PID 기준으로 합산
  foreach($s in $counters.CounterSamples){
    $path = $s.Path
    $inst = ($path -split '\\')[-2] -replace '^Process\(|\)$',''
    $name = ($path -split '\\')[-1]
    if($name -ne '% Processor Time'){ continue }
    if($inst -in @('_Total','Idle')){ continue }
    if($pidByInst.ContainsKey($inst)){
      $procId = $pidByInst[$inst]        # <-- $PID 충돌 회피
      $val = [math]::Round($s.CookedValue,1)
      if(-not $cpuByPid.ContainsKey($procId)){ $cpuByPid[$procId] = 0 }
      $cpuByPid[$procId] += $val
    }
  }

  # 3) 보조 정보 결합 + 정렬
  $rows = foreach($kv in $cpuByPid.GetEnumerator()){
    $procId = $kv.Key; $pct = $kv.Value
    try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { continue }
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue).CommandLine
    [pscustomobject]@{
      CPUpct    = $pct
      PID       = $procId
      Name      = $p.ProcessName
      CPUtimeS  = [math]::Round(($p.CPU),1)
      Threads   = ($p.Threads.Count)
      Command   = ($cmd -replace '\r|\n',' ')
    }
  }

  $rows | Sort-Object CPUpct -Descending | Select-Object -First $n
}

function Get-RecentEvents([int]$minutes){
  $since = (Get-Date).AddMinutes(-$minutes)
  Get-WinEvent -ErrorAction SilentlyContinue `
    -FilterHashtable @{LogName=@('System','Application'); Level=2,3; StartTime=$since} -MaxEvents 50 |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
}

# ---- run ----
$ComputerName = $env:COMPUTERNAME
$now  = NowLocal
$upt  = UptimeHours
$cpu  = Get-CpuTotals
$tops = Get-TopProcesses -n $TopN -intervalSec $SampleSec
$evts = Get-RecentEvents -minutes $RecentEventMin | Select-Object -First 5

"===== CPU ALERT SNAPSHOT ====="
"Host: $ComputerName"
"Time: $now"
"Uptime(hours): $upt"
"LogicalProcessors: $(LP)"
"------------------------------"
"CPU Total: $($cpu.CpuTotalPct)%  (User $($cpu.CpuUserPct)%, Priv $($cpu.CpuPrivPct)%, DPC $($cpu.CpuDpcPct)%, Int $($cpu.CpuIntPct)%)"
"Processor Queue Length: $($cpu.ProcQueueLen)"
"------------------------------"
"Top $TopN Processes by CPU% (sample ${SampleSec}s)"
"{0,-7} {1,-7} {2,-25} {3,-8} {4,-8} {5}" -f "CPU%","PID","Name","CPU(s)","Threads","CommandLine"
foreach($p in $tops){
  "{0,-7} {1,-7} {2,-25} {3,-8} {4,-8} {5}" -f $p.CPUpct,$p.PID,($p.Name -replace '\s',' '),$p.CPUtimeS,$p.Threads,($p.Command -replace '\r|\n',' ')
}
"------------------------------"
"Recent Warnings/Errors (last ${RecentEventMin}m)"
if($evts){
  foreach($e in $evts){
    "[{0:yyyy-MM-dd HH:mm:ss}] Id:{1} {2} {3} - {4}" -f $e.TimeCreated,$e.Id,$e.LevelDisplayName,$e.ProviderName,($e.Message -replace '\r|\n',' ')
  }
}else{
  "(none)"
}
"===== END ====="