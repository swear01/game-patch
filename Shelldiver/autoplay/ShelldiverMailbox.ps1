function Publish-ShelldiverMailboxFile([string]$TemporaryPath, [string]$DestinationPath) {
    for ($attempt = 1; $attempt -le 5; ++$attempt) {
        try {
            [IO.File]::Move($TemporaryPath, $DestinationPath, $true)
            return
        } catch {
            $code = $_.Exception.GetBaseException().HResult -band 0xFFFF
            if ($attempt -eq 5 -or $code -notin 5, 32, 33) { throw }
            Start-Sleep -Milliseconds 8
        }
    }
}