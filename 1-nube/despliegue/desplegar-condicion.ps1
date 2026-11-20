# Condicion de la lamina (con o sin incision) en el dashboard.
# 1) Sube la Lambda guardar-resultado-corrosion, que ahora guarda el campo opcional 'condicion'.
# 2) Publica el dashboard que lo muestra.
# Las lecturas sin ese campo siguen funcionando igual; solo no muestran la etiqueta.
Set-Location (Join-Path $PSScriptRoot '..')
$region = 'us-east-2'
$funcion = 'guardar-resultado-corrosion'

Write-Host '1) Subiendo la Lambda que guarda los resultados...' -ForegroundColor Cyan
aws lambda get-function --function-name $funcion --region $region --query 'Configuration.FunctionName' --output text | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "No se encontro la funcion $funcion. Pasale esto a Claude." -ForegroundColor Red; exit 1 }
aws lambda update-function-code --function-name $funcion --zip-file 'fileb://lambda-guardar-resultado/function.zip' --region $region --query FunctionName --output text | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "FALLO al subir $funcion. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
aws lambda wait function-updated --function-name $funcion --region $region
Write-Host "   $funcion actualizada"

Write-Host '2) Publicando el dashboard...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'desplegar-dashboard.ps1')
