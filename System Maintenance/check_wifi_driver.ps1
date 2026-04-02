Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DeviceName -like '*MediaTek*' -or $_.DeviceName -like '*MT79*' } | Select-Object DeviceName, DriverVersion, DriverDate | Format-List
