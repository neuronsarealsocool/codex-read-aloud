$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot 'reader.ps1'
$testData = Join-Path $env:TEMP ('CodexReadAloudTest-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testData)
$settings = @{enabled=$true; voice='Microsoft Zira Desktop'; rate=0; volume=0; skipCode=$true; maxCharacters=20000}
$settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testData 'settings.json') -Encoding UTF8
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-Hook($Payload) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $reader + '" -Mode Hook -DataDir "' + $testData + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress))
    $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd()
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    Assert ($process.ExitCode -eq 0) $errorText
    $process.Dispose()
    return $output.Trim()
}
$markdown = @'
# Hello **world**
[Guide](https://example.com)
```powershell
Remove-Item some-file
```
::code-comment{body="ignore this"}
Visit https://example.com.
- :codex-followup[Stop]{prompt="Use the Read Aloud plugin to stop current and queued speech."}
'@
$preview = & $reader -Mode Preview -Text $markdown -DataDir $testData
Assert ($preview -eq 'Hello world Guide Visit') ('Unexpected speech text: ' + $preview)
$visualMarker = [char]0xE200 + 'visualize' + [char]0xE202 + '{"path":"controls.html"}' + [char]0xE201
foreach ($numericAnswer in @('2.', '42.', '1.5', '-2.', '2. ')) {
    $numericPreview = & $reader -Mode Preview -Text ($numericAnswer + "`n`n" + $visualMarker) -DataDir $testData
    Assert ($numericPreview -eq $numericAnswer.Trim()) ('Numeric answer lost: ' + $numericAnswer)
}
$listPreview = & $reader -Mode Preview -Text ("1. First item`n2. Second item") -DataDir $testData
Assert ($listPreview -eq 'First item Second item') 'Actual numbered-list markers were not removed.'
$payload = @{hook_event_name='Stop'; session_id='test'; turn_id='one'; last_assistant_message='This is a silent test of the read aloud completion hook.'}
$watch = [Diagnostics.Stopwatch]::StartNew()
$output = Invoke-Hook $payload
$watch.Stop()
Assert ($output -eq '{}') ('Unexpected hook output: ' + $output)
Assert ($watch.Elapsed.TotalSeconds -lt 10) 'Completion hook did not return promptly.'
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    Start-Sleep -Milliseconds 100
    $statePath = Join-Path $testData 'playback.json'
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
} until ($state -or [DateTime]::UtcNow -gt $deadline)
Assert ($null -ne $state) 'Background speech did not initialize.'
Assert (-not (Test-Path -LiteralPath (Join-Path $testData 'last-error.txt'))) 'Speech worker reported an error.'
$before = Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw
Assert ((Invoke-Hook $payload) -eq '{}') 'Duplicate hook returned invalid output.'
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -eq $before) 'Duplicate completion was queued.'
& $reader -Mode Stop -DataDir $testData | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(5)
do {
    Start-Sleep -Milliseconds 100
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
} until ($state.state -eq 'idle' -or [DateTime]::UtcNow -gt $deadline)
Assert ($state.state -eq 'idle') 'Stop did not cancel playback.'
& $reader -Mode Off -DataDir $testData | Out-Null
$before = Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw
$payload.turn_id='two'
Assert ((Invoke-Hook $payload) -eq '{}') 'Disabled hook returned invalid output.'
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -eq $before) 'Disabled hook queued speech.'
& $reader -Mode On -DataDir $testData | Out-Null
$payload.last_assistant_message=$null
Assert ((Invoke-Hook $payload) -eq '{}') 'Empty answer hook failed.'
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -eq $before) 'Empty answer queued speech.'
& $reader -Mode Faster -DataDir $testData | Out-Null
$configured = Get-Content -LiteralPath (Join-Path $testData 'settings.json') -Raw | ConvertFrom-Json
Assert ($configured.rate -eq 1) 'Faster did not increase speed.'
& $reader -Mode Slower -DataDir $testData | Out-Null
& $reader -Mode Rate -Value 10 -DataDir $testData | Out-Null
& $reader -Mode Faster -DataDir $testData | Out-Null
$configured = Get-Content -LiteralPath (Join-Path $testData 'settings.json') -Raw | ConvertFrom-Json
Assert ($configured.rate -eq 10) 'Faster exceeded upper speed limit.'
& $reader -Mode Normal -DataDir $testData | Out-Null
$configured = Get-Content -LiteralPath (Join-Path $testData 'settings.json') -Raw | ConvertFrom-Json
Assert ($configured.rate -eq 0) 'Normal did not reset speed.'
$controls = & $reader -Mode Controls -DataDir $testData | ConvertFrom-Json
Assert ($controls.hookSpecificOutput.hookEventName -eq 'SessionStart') 'Invalid controls hook output.'
Assert ($controls.hookSpecificOutput.additionalContext.Contains('controls.html')) 'Controls context is missing the HTML controls.'
& $reader -Mode ProgressOff -DataDir $testData | Out-Null
$before = Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw
& $reader -Mode Narrate -Text 'This should not play.' -DataDir $testData | Out-Null
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -eq $before) 'Disabled progress narration queued speech.'
& $reader -Mode ProgressOn -DataDir $testData | Out-Null
& $reader -Mode Narrate -Text 'Checking the visible progress update.' -DataDir $testData | Out-Null
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -ne $before) 'Enabled progress narration did not queue speech.'
& $reader -Mode Off -DataDir $testData | Out-Null
$before = Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw
& $reader -Mode Narrate -Text 'This should not play either.' -DataDir $testData | Out-Null
Assert ((Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw) -eq $before) 'Automatic off did not silence narration.'
'PASS: Numeric answers, numbered lists, cleanup, background speech, completion, deduplication, stop, switches, speed controls, SessionStart output, and progress narration settings.'
"Isolated test data: $testData"
