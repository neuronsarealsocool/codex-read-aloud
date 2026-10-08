$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot 'reader.ps1'
$testData = Join-Path $env:TEMP ('CodexWindowsVoicesTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testData | Out-Null
@{enabled=$false;voice='Microsoft Zira Desktop';rate=0;volume=0;skipCode=$true;maxCharacters=20000;narrateProgress=$true;engine='windows';kokoroVoice='af_heart'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testData 'settings.json') -Encoding utf8
foreach ($voiceName in @('Microsoft George','Microsoft Susan','Microsoft Hazel Desktop')) {
    & $reader -Mode Off -DataDir $testData | Out-Null
    & $reader -Mode Voice -Value $voiceName -DataDir $testData | Out-Null
    $settings = Get-Content -LiteralPath (Join-Path $testData 'settings.json') -Raw | ConvertFrom-Json
    if ($settings.enabled) { throw 'Selecting a voice changed the automatic-reading preference.' }
    & $reader -Mode On -DataDir $testData | Out-Null
    & $reader -Mode Test -Text 'Two plus two is four.' -DataDir $testData | Out-Null
    $id = (Get-Content -LiteralPath (Join-Path $testData 'latest.json') -Raw | ConvertFrom-Json).id
    $request = Join-Path $testData ($id + '.json')
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do { Start-Sleep -Milliseconds 100 } until (-not (Test-Path -LiteralPath $request) -or [DateTime]::UtcNow -gt $deadline)
    $errorFile = Join-Path $testData 'last-error.txt'
    if (Test-Path -LiteralPath $errorFile) { throw (Get-Content -LiteralPath $errorFile -Raw) }
    if (Test-Path -LiteralPath $request) { throw "Speech did not complete for $voiceName" }
    "Verified muted playback: $voiceName"
}
& $reader -Mode Voice -Value 'Microsoft George' -DataDir $testData | Out-Null
& $reader -Mode Test -Text ('A longer Windows speech cancellation test. ' * 100) -DataDir $testData | Out-Null
$statePath = Join-Path $testData 'playback.json'
$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    Start-Sleep -Milliseconds 100
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
} until ($state.state -eq 'speaking' -or [DateTime]::UtcNow -gt $deadline)
if ($state.state -ne 'speaking') { throw 'Modern Windows speech did not reach playback.' }
& $reader -Mode Stop -DataDir $testData | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(3)
do {
    Start-Sleep -Milliseconds 100
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
} until ($state.state -eq 'idle' -or [DateTime]::UtcNow -gt $deadline)
if ($state.state -ne 'idle') { throw 'Modern Windows speech did not stop promptly.' }
'PASS: George, Susan and Hazel playback; preserved automatic-off preference; cancellation.'
"Isolated data: $testData"
