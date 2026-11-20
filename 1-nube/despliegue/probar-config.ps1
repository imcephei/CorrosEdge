# Prueba GET /config pidiendo la clave en pantalla (no la guarda en ningun lado).
$api = 'https://97i50k7oag.execute-api.us-east-2.amazonaws.com'
$k = Read-Host 'Pega la clave de P-ACR-001 y presiona Enter'
$k = $k.Trim()
Write-Host 'Clave de ACR pidiendo su configuracion (debe traer frecuencia_horas):' -ForegroundColor Cyan
Write-Host ('   ' + (curl.exe -s "$api/config" -H "x-api-key: $k"))
Write-Host 'Clave de ACR pidiendo la de MTA (debe decir no autorizada):' -ForegroundColor Cyan
Write-Host ('   ' + (curl.exe -s "$api/config?panel_id=P-MTA-001" -H "x-api-key: $k"))
Write-Host 'Sin clave (debe decir Unauthorized):' -ForegroundColor Cyan
Write-Host ('   ' + (curl.exe -s "$api/config"))
