function Get-WindowsModernVoices {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.SpeechSynthesis.SpeechSynthesizer,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]::AllVoices
}

function Invoke-WindowsModernSpeech($Job, $StopEvent) {
    $voice = Get-WindowsModernVoices | Where-Object DisplayName -eq $Job.voice | Select-Object -First 1
    if (-not $voice) { throw "Windows voice is not installed: $($Job.voice)" }
    $modernSynth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
    $operation = $null
    $speechStream = $null
    $readStream = $null
    $memory = $null
    $player = $null
    try {
        $modernSynth.Voice = $voice
        $modernSynth.Options.AudioVolume = [double]$Job.volume / 100.0
        $modernSynth.Options.SpeakingRate = [Math]::Max(0.5, [Math]::Min(2.0, 1.0 + [int]$Job.rate * 0.1))
        $operation = $modernSynth.SynthesizeTextToStreamAsync([string]$Job.text)
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
        $streamType = [Windows.Media.SpeechSynthesis.SpeechSynthesisStream,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]
        $task = $asTask.MakeGenericMethod($streamType).Invoke($null, @($operation))
        Write-State 'generating' $Job.id
        while (-not $task.IsCompleted) {
            $current = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($StopEvent.WaitOne(50) -or $current.id -ne $Job.id) { $operation.Cancel(); return }
        }
        $speechStream = $task.GetAwaiter().GetResult()
        $readStream = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($speechStream)
        $memory = New-Object IO.MemoryStream
        $readStream.CopyTo($memory)
        # Derive duration from the WAV chunks, rather than estimating from text.
        $memory.Position = 12
        $binary = New-Object IO.BinaryReader($memory)
        $byteRate = 0
        $audioBytes = 0
        while ($memory.Position + 8 -le $memory.Length) {
            $chunk = [Text.Encoding]::ASCII.GetString($binary.ReadBytes(4))
            $length = $binary.ReadUInt32()
            $next = $memory.Position + $length + ($length % 2)
            if ($chunk -eq 'fmt ') {
                [void]$binary.ReadUInt16(); [void]$binary.ReadUInt16(); [void]$binary.ReadUInt32()
                $byteRate = $binary.ReadUInt32()
            }
            if ($chunk -eq 'data') { $audioBytes = $length; break }
            $memory.Position = $next
        }
        if ($byteRate -le 0 -or $audioBytes -le 0) { throw 'Windows returned an invalid speech WAV stream.' }
        $memory.Position = 0
        $player = New-Object System.Media.SoundPlayer($memory)
        $player.Load()
        $current = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($StopEvent.WaitOne(0) -or $current.id -ne $Job.id) { return }
        $player.Play()
        Write-State 'speaking' $Job.id
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $duration = [double]$audioBytes / $byteRate + 0.2
        while ($timer.Elapsed.TotalSeconds -lt $duration) {
            $current = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($StopEvent.WaitOne(50) -or $current.id -ne $Job.id) { break }
        }
    } finally {
        if ($player) { $player.Stop(); $player.Dispose() }
        if ($readStream) { $readStream.Dispose() }
        if ($speechStream) { $speechStream.Dispose() }
        if ($memory) { $memory.Dispose() }
        $modernSynth.Dispose()
    }
}
