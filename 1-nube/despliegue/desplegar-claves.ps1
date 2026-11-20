# Despliega "una clave por dispositivo": agrega DEVICE_KEYS al autorizador
# (sin tocar API_SECRET), sube el codigo de las 3 Lambdas y prueba la API.
# No imprime ninguna clave en pantalla.
Set-Location (Join-Path $PSScriptRoot '..')
$region = 'us-east-2'
$api = 'https://97i50k7oag.execute-api.us-east-2.amazonaws.com'

function Revisar($paso) {
    if ($LASTEXITCODE -ne 0) { Write-Host "FALLO en: $paso. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
}

Write-Host '1) Agregando DEVICE_KEYS al autorizador...' -ForegroundColor Cyan
$cfg = aws lambda get-function-configuration --function-name authorizer-corrosion --region $region | ConvertFrom-Json
Revisar 'leer la configuracion del autorizador'
$vars = [ordered]@{}
if ($cfg.Environment) { $cfg.Environment.Variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value } }
$vars['DEVICE_KEYS'] = (Get-Content 'pruebas-api\device-keys.json' -Raw).Trim()
$tmp = Join-Path $env:TEMP 'env-autorizador.json'
@{ Variables = $vars } | ConvertTo-Json -Compress -Depth 3 | Set-Content $tmp -Encoding ascii
aws lambda update-function-configuration --function-name authorizer-corrosion --environment "file://$tmp" --region $region --query 'LastUpdateStatus' --output text | Out-Null
$codigo = $LASTEXITCODE
Remove-Item $tmp -ErrorAction SilentlyContinue
$LASTEXITCODE = $codigo; Revisar 'guardar DEVICE_KEYS'
aws lambda wait function-updated --function-name authorizer-corrosion --region $region
Write-Host ("   Listo. Variables del autorizador: " + ($vars.Keys -join ', '))

Write-Host '2) Subiendo el codigo nuevo...' -ForegroundColor Cyan
$funciones = [ordered]@{
    'authorizer-corrosion'        = 'lambda-authorizer'
    'generar-url-subida'          = 'lambda-generar-url'
    'guardar-resultado-corrosion' = 'lambda-guardar-resultado'
}
foreach ($f in $funciones.Keys) {
    aws lambda update-function-code --function-name $f --zip-file "fileb://$($funciones[$f])/function.zip" --region $region --query 'FunctionName' --output text | Out-Null
    Revisar "subir $f"
    aws lambda wait function-updated --function-name $f --region $region
    Write-Host "   $f actualizada"
}

Write-Host '3) Probando la API real (no escribe nada en la base de datos)...' -ForegroundColor Cyan
$k = (Select-String 'claves-dispositivos.txt' -Pattern '^P-ACR-001: (.+)$').Matches[0].Groups[1].Value
$r1 = curl.exe -s -X POST "$api/upload-url" -H "x-api-key: $k" -H "Content-Type: application/json" --data '@pruebas-api/panel-acr.json'
$r2 = curl.exe -s -X POST "$api/upload-url" -H "x-api-key: $k" -H "Content-Type: application/json" --data '@pruebas-api/panel-mta.json'
Write-Host '   Clave de ACR con su panel (debe traer upload_url):'
Write-Host ('   ' + $r1.Substring(0, [Math]::Min(90, $r1.Length)) + '...')
Write-Host '   Clave de ACR con el panel de MTA (debe decir no autorizada):'
Write-Host ('   ' + $r2)
