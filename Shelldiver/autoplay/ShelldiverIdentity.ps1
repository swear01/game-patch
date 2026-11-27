function Assert-ShelldiverIdentity([Diagnostics.Process]$Process) {
    if ($Process.ProcessName -ne 'Shelldiver') { throw 'The mailbox PID is not Shelldiver.' }
    $path = $Process.MainModule.FileName
    if (!$path) { throw 'The Shelldiver executable path is unavailable.' }
    $binary = Get-Item -LiteralPath $path
    $install = $binary.Directory
    $common = $install.Parent
    $steamapps = $common.Parent
    if ($binary.Name -ne 'Shelldiver.exe' -or $install.Name -ne 'Shelldiver' -or
        $common.Name -ne 'common' -or $steamapps.Name -ne 'steamapps') {
        throw 'Expected Shelldiver.exe under the Steam library steamapps/common/Shelldiver directory.'
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binary.FullName).Hash
    if ($hash -notin '62599F01A4CE4B8946FCC38827E6364539E31ABBED99B0828112E670B0C3925E',
        '48D45832A3B2FD299BB343289A2CB4A3BFAD8755B847CF23E49EC01D65629290') {
        throw 'Shelldiver.exe does not match a verified build 23898569 image.'
    }
}
