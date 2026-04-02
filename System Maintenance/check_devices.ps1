Write-Host "=== DEVICES WITH ERRORS OR UNKNOWN STATUS ===" -ForegroundColor Cyan
Get-PnpDevice | Where-Object {$_.Status -ne 'OK'} | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap

Write-Host ""
Write-Host "=== UNKNOWN / NO DRIVER DEVICES ===" -ForegroundColor Cyan
Get-PnpDevice | Where-Object {$_.Class -eq 'Unknown' -or $_.Status -eq 'Unknown'} | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap
