# Borra API_SECRET (la clave compartida vieja) del autorizador, SOLO si en los
# ultimos 3 dias ningun dispositivo la uso. Correr cuando Luis ya haya puesto
# las claves nuevas en el Pi.
$region = 'us-east-2'
$desde = [DateTimeOffset]::UtcNow.AddDays(-3).ToUnixTimeMilliseconds()
$usos = aws logs filter-log-events --log-group-name /aws/lambda/authorizer-corrosion --filter-pattern CLAVE_VIEJA_USADA --start-time $desde --region $region --query 'length(events)' --output text
if ($LASTEXITCODE -ne 0) { Write-Host 'No se pudo leer el log. Pasale el error a Claude.' -ForegroundColor Red; exit 1 }
if ([int]$usos -gt 0) {
    Write-Host "La clave vieja se uso $usos vez/veces en los ultimos 3 dias: algun dispositivo todavia la tiene. NO se borro." -ForegroundColor Yellow
    exit 1
}
$cfg = aws lambda get-function-configuration --function-name authorizer-corrosion --region $region | ConvertFrom-Json
$vars = [ordered]@{}
$cfg.Environment.Variables.PSObject.Properties | Where-Object { $_.Name -ne 'API_SECRET' } | ForEach-Object { $vars[$_.Name] = $_.Value }
$tmp = Join-Path $env:TEMP 'env-autorizador.json'
[IO.File]::WriteAllText($tmp, (@{ Variables = $vars } | ConvertTo-Json -Compress -Depth 3), (New-Object Text.UTF8Encoding $false))
aws lambda update-function-configuration --function-name authorizer-corrosion --environment "file://$tmp" --region $region --query LastUpdateStatus --output text | Out-Null
$codigo = $LASTEXITCODE; Remove-Item $tmp -ErrorAction SilentlyContinue
if ($codigo -ne 0) { Write-Host 'Fallo al guardar. Pasale el error a Claude.' -ForegroundColor Red; exit 1 }
Write-Host ('Clave vieja borrada. Variables del autorizador: ' + ($vars.Keys -join ', ')) -ForegroundColor Green
