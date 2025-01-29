# Check if usbipd is installed
if (-not (Test-Path "C:\Program Files\usbipd-win\usbipd.exe")) {
        winget install usbipd
}

# Check if device is already bound
$deviceStatus = & 'C:\Program Files\usbipd-win\usbipd.exe' list | Select-String "1-2"
if ( ($deviceStatus -notmatch "Bound") -and ($deviceStatus -notmatch "Attached")) {
    # Only elevate and bind if not already bound
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        $arguments = "-Command `"& 'C:\Program Files\usbipd-win\usbipd.exe' bind --busid 1-2`""
        Start-Process powershell -Verb runAs -ArgumentList $arguments -Wait
    } else {
        & 'C:\Program Files\usbipd-win\usbipd.exe' bind --busid 1-2
    }
}

# Attach can run without admin rights
& 'C:\Program Files\usbipd-win\usbipd.exe' attach --wsl --busid 1-2


