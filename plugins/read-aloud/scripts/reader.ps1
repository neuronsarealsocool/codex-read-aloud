param(
    [ValidateSet('Hook','Worker','On','Off','Stop','Status','Voices','Voice','Engine','Rate','Faster','Slower','Normal','ProgressOn','ProgressOff','Narrate','Controls','Preview','Test')]
    [string]$Mode = 'Status',
    [string]$Text = '',
    [string]$Value = '',
    [string]$Request = '',
    [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'CodexReadAloud')
)
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $DataDir 'settings.json'
$latestPath = Join-Path $DataDir 'latest.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
# Distinct synchronization objects for each user's chosen data directory.
$sha = [System.Security.Cryptography.SHA256]::Create()
$suffix = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($DataDir.ToLowerInvariant())))).Replace('-','').Substring(0,16)
$sha.Dispose()
$mutexName = 'Local\CodexReadAloudSpeak_' + $suffix
$eventName = 'Local\CodexReadAloudStop_' + $suffix

function Write-JsonFile($Path, $Object) {
    $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tempPath, ($Object | ConvertTo-Json -Depth 8), $utf8)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}
function Get-Settings {
    if (Test-Path -LiteralPath $configPath) {
        $loaded = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $loaded.PSObject.Properties['narrateProgress']) { $loaded | Add-Member -NotePropertyName narrateProgress -NotePropertyValue $true }
        if (-not $loaded.PSObject.Properties['engine']) { $loaded | Add-Member -NotePropertyName engine -NotePropertyValue 'windows' }
        if (-not $loaded.PSObject.Properties['kokoroVoice']) { $loaded | Add-Member -NotePropertyName kokoroVoice -NotePropertyValue 'af_heart' }
        return $loaded
    }
    return [pscustomobject]@{enabled=$true; voice='Microsoft Zira Desktop'; rate=0; volume=100; skipCode=$true; maxCharacters=20000; narrateProgress=$true; engine='windows'; kokoroVoice='af_heart'}
}
function Get-SpokenText([string]$InputText, $Settings) {
    $result = $InputText
    if ($Settings.skipCode) {
        $result = [regex]::Replace($result, '(?ms)^\s*(`{3,}|~{3,})[^\r\n]*\r?\n.*?(?:^\s*\1\s*$|\z)', ' ')
        $result = [regex]::Replace($result, '(?m)^(?: {4}|\t).+$', ' ')
    }
    $result = [regex]::Replace($result, '(?m)^\s*::[^\r\n]+', ' ')
    $result = [regex]::Replace($result, '(?m)^\s*[-*+]\s*:codex-followup\[[^\r\n]*$', ' ')
    $result = [regex]::Replace($result, '\uE200visualize\uE202[^\r\n]*?\uE201', ' ')
    $result = [regex]::Replace($result, '!?\[([^\]]*)\]\([^\r\n]*?\)', '$1')
    $result = [regex]::Replace($result, 'https?://[^\s<>]+', ' ')
    # List markers must have content on the same line. A reply such as "2."
    # followed by the controls on the next line is a number, not a list.
    $result = [regex]::Replace($result, '(?m)^[ \t]*(?:#{1,6}[ \t]+|[-*+][ \t]+|>[ \t]*|\d+\.[ \t]+(?=\S))', '')
    $result = $result.Replace('`','').Replace('**','').Replace('__','')
    $result = [Net.WebUtility]::HtmlDecode($result)
    $result = [regex]::Replace($result, '\s+', ' ').Trim()
    $limit = [int]$Settings.maxCharacters
    if ($limit -gt 0 -and $result.Length -gt $limit) { $result = $result.Substring(0,$limit) + '. Remaining text omitted.' }
    return $result
}
function Signal-Stop {
    $event = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $eventName)
    try { [void]$event.Set() } finally { $event.Dispose() }
}
function Write-State([string]$State, [string]$Id = '') {
    Write-JsonFile (Join-Path $DataDir 'playback.json') @{state=$State; request=$Id; updated=[DateTime]::UtcNow.ToString('o')}
}
function Queue-Speech([string]$SpeechText, $Settings, [string]$Id) {
    $requestId = [guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $DataDir ($requestId + '.json')
    Write-JsonFile $requestPath @{id=$requestId; text=$SpeechText; voice=$Settings.voice; rate=$Settings.rate; volume=$Settings.volume; engine=$Settings.engine; kokoroVoice=$Settings.kokoroVoice}
    Write-JsonFile $latestPath @{id=$requestId; turn=$Id}
    Signal-Stop
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Worker -Request "' + $requestPath + '" -DataDir "' + $DataDir + '"'
    try { Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden | Out-Null }
    catch { Remove-Item -LiteralPath $requestPath -ErrorAction SilentlyContinue; throw }
}

try {
    [void][IO.Directory]::CreateDirectory($DataDir)
    $settings = Get-Settings
    switch ($Mode) {
        'Controls' {
            $footerPath = Join-Path (Split-Path $PSScriptRoot) 'controls.md'
            $context = [IO.File]::ReadAllText($footerPath, $utf8)
            @{hookSpecificOutput=@{hookEventName='SessionStart'; additionalContext=$context}} | ConvertTo-Json -Depth 5 -Compress
        }
        'Hook' {
            [Console]::InputEncoding = $utf8
            $inputObject = [Console]::In.ReadToEnd() | ConvertFrom-Json
            if ($inputObject.hook_event_name -ne 'Stop' -or -not $settings.enabled) { break }
            if ([string]::IsNullOrWhiteSpace($inputObject.last_assistant_message)) { break }
            $turnKey = [string]$inputObject.session_id + ':' + [string]$inputObject.turn_id
            if ($inputObject.turn_id -and (Test-Path -LiteralPath $latestPath)) {
                $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($latest.turn -eq $turnKey) { break }
            }
            $speechText = Get-SpokenText $inputObject.last_assistant_message $settings
            if ($speechText) { Queue-Speech $speechText $settings $turnKey }
        }
        'Worker' {
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)
            $event = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $eventName)
            $locked = $false
            $synth = $null
            try {
                try { $locked = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
                if (-not $locked) { throw 'Timed out waiting for previous speech to stop.' }
                $job = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
                $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($latest.id -ne $job.id -or -not (Get-Settings).enabled) { break }
                [void]$event.Reset()
                if ($job.engine -eq 'kokoro') {
                    $python = Join-Path $DataDir 'kokoro\venv\Scripts\python.exe'
                    $worker = Join-Path $PSScriptRoot 'kokoro-worker.py'
                    $errorPath = Join-Path $DataDir ($job.id + '.stderr')
                    $child = $null
                    $cancelled = $false
                    try {
                        if (-not (Test-Path -LiteralPath $python)) { throw 'Kokoro is not installed; run setup-kokoro.py first.' }
                        Write-State 'generating' $job.id
                        $childArgs = '"' + $worker + '" --data-dir "' + $DataDir + '" --request "' + $Request + '"'
                        $child = Start-Process -FilePath $python -ArgumentList $childArgs -WindowStyle Hidden -PassThru -RedirectStandardError $errorPath
                        while (-not $child.HasExited) {
                            $cancelled = $event.WaitOne(100)
                            $current = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            if ($cancelled -or $current.id -ne $job.id) { $cancelled=$true; break }
                        }
                        if ($cancelled) { break }
                        $child.WaitForExit()
                        if ($child.ExitCode -ne 0) { throw ([IO.File]::ReadAllText($errorPath)) }
                        break
                    } catch {
                        [IO.File]::WriteAllText((Join-Path $DataDir 'kokoro-error.txt'), ([DateTime]::UtcNow.ToString('o') + ' ' + $_.Exception.Message), $utf8)
                        # Failed neural playback falls back to the selected Windows voice.
                    } finally {
                        if ($child) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
                        if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath }
                    }
                }
                Add-Type -AssemblyName System.Speech
                $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
                if ($job.voice) { $synth.SelectVoice($job.voice) }
                $synth.Rate = [int]$job.rate
                $synth.Volume = [int]$job.volume
                $synth.SetOutputToDefaultAudioDevice()
                $prompt = $synth.SpeakAsync([string]$job.text)
                Write-State 'speaking' $job.id
                while (-not $prompt.IsCompleted) {
                    $cancelled = $event.WaitOne(100)
                    $current = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($cancelled -or $current.id -ne $job.id) { $synth.SpeakAsyncCancelAll(); break }
                }
                Write-State 'idle' $job.id
            } finally {
                if ($locked) { Write-State 'idle' }
                if ($synth) { $synth.Dispose() }
                if ($locked) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
                $event.Dispose()
                if ($Request -and (Test-Path -LiteralPath $Request)) { Remove-Item -LiteralPath $Request }
            }
        }
        'On' { $settings.enabled=$true; Write-JsonFile $configPath $settings; 'Automatic reading enabled.' }
        'Off' {
            $settings.enabled=$false; Write-JsonFile $configPath $settings
            Write-JsonFile $latestPath @{id='cancelled'; turn=''}
            Signal-Stop
            'Automatic reading disabled.'
        }
        'Stop' { Write-JsonFile $latestPath @{id='cancelled'; turn=''}; Signal-Stop; 'Speech stopped.' }
        'Status' {
            $settings | ConvertTo-Json
            if (Test-Path -LiteralPath (Join-Path $DataDir 'playback.json')) { Get-Content -LiteralPath (Join-Path $DataDir 'playback.json') -Raw }
            "Settings: $configPath"
        }
        'Voices' {
            $python = Join-Path $DataDir 'kokoro\venv\Scripts\python.exe'
            if (Test-Path -LiteralPath $python) { & $python (Join-Path $PSScriptRoot 'kokoro-worker.py') --data-dir $DataDir --check }
            Add-Type -AssemblyName System.Speech
            $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
            try { $synth.GetInstalledVoices() | Where-Object Enabled | ForEach-Object { $_.VoiceInfo.Name } } finally { $synth.Dispose() }
        }
        'Voice' {
            if ($Value -match '^[ab][fm]_') {
                $python = Join-Path $DataDir 'kokoro\venv\Scripts\python.exe'
                if (-not (Test-Path -LiteralPath $python)) { throw 'Install Kokoro first with setup-kokoro.py.' }
                $available = & $python (Join-Path $PSScriptRoot 'kokoro-worker.py') --data-dir $DataDir --check | ConvertFrom-Json
                if ($LASTEXITCODE -ne 0 -or $Value -notin $available) { throw 'Unknown or unavailable Kokoro voice.' }
                $settings.kokoroVoice=$Value; $settings.engine='kokoro'; Write-JsonFile $configPath $settings; "Kokoro voice set to $Value."; break
            }
            Add-Type -AssemblyName System.Speech
            $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
            try { $synth.SelectVoice($Value) } finally { $synth.Dispose() }
            $settings.voice=$Value; $settings.engine='windows'; Write-JsonFile $configPath $settings; "Windows voice set to $Value."
        }
        'Engine' {
            if ($Value -notin @('windows','kokoro')) { throw 'Engine must be windows or kokoro.' }
            if ($Value -eq 'kokoro') {
                $python = Join-Path $DataDir 'kokoro\venv\Scripts\python.exe'
                if (-not (Test-Path -LiteralPath $python)) { throw 'Install Kokoro first with setup-kokoro.py.' }
                & $python (Join-Path $PSScriptRoot 'kokoro-worker.py') --data-dir $DataDir --check | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Kokoro installation check failed.' }
            }
            $settings.engine=$Value; Write-JsonFile $configPath $settings; "Speech engine set to $Value."
        }
        'Rate' {
            $rateNumber = [int]$Value
            if ($rateNumber -lt -10 -or $rateNumber -gt 10) { throw 'Rate must be between -10 and 10; 0 is normal.' }
            $settings.rate=$rateNumber; Write-JsonFile $configPath $settings; "Rate set to $rateNumber."
        }
        'Faster' { $settings.rate=[Math]::Min(10, [int]$settings.rate + 1); Write-JsonFile $configPath $settings; "Reading speed: $($settings.rate)." }
        'Slower' { $settings.rate=[Math]::Max(-10, [int]$settings.rate - 1); Write-JsonFile $configPath $settings; "Reading speed: $($settings.rate)." }
        'Normal' { $settings.rate=0; Write-JsonFile $configPath $settings; 'Reading speed reset to normal.' }
        'ProgressOn' { $settings.narrateProgress=$true; Write-JsonFile $configPath $settings; 'Visible progress narration enabled.' }
        'ProgressOff' { $settings.narrateProgress=$false; Write-JsonFile $configPath $settings; 'Visible progress narration disabled.' }
        'Narrate' {
            if (-not $settings.enabled -or -not $settings.narrateProgress) { 'Progress narration is off.'; break }
            $speechText = Get-SpokenText $Text $settings
            if ($speechText) { Queue-Speech $speechText $settings ''; 'Progress update queued.' }
        }
        'Preview' { Get-SpokenText $Text $settings }
        'Test' {
            if (-not $settings.enabled) { throw 'Reading is disabled. Enable it first.' }
            if (-not $Text) { $Text = 'Codex read aloud is ready.' }
            Queue-Speech (Get-SpokenText $Text $settings) $settings ''
            'Speech test queued.'
        }
    }
} catch {
    if ($Mode -eq 'Hook' -or $Mode -eq 'Worker') {
        try { [IO.File]::WriteAllText((Join-Path $DataDir 'last-error.txt'), ([DateTime]::UtcNow.ToString('o') + ' ' + $_.Exception.Message), $utf8) } catch {}
        if ($Mode -eq 'Hook') { [Console]::WriteLine('{"systemMessage":"Read Aloud could not start. Check LocalAppData/CodexReadAloud/last-error.txt."}'); exit 0 }
        exit 1
    }
    throw
}
if ($Mode -eq 'Hook') { [Console]::WriteLine('{}') }
