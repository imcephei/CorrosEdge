# Hora de inicio del muestreo: sube las dos Lambdas que la guardan y la entregan
# al dispositivo, y luego publica el dashboard con el selector nuevo.
Set-Location (Join-Path $PSScriptRoot '..')
$region = 'us-east-2'
Write-Host '1) Subiendo las Lambdas...' -ForegroundColor Cyan
foreach ($par in @(@('actualizar-dispositivo', 'lambda-actualizar-dispositivo'), @('obtener-config-dispositivo', 'lambda-obtener-config'))) {
    aws lambda update-function-code --function-name $par[0] --zip-file "fileb://$($par[1])/function.zip" --region $region --query FunctionName --output text | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "FALLO al subir $($par[0]). Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
    aws lambda wait function-updated --function-name $par[0] --region $region
    Write-Host "   $($par[0]) actualizada"
}
Write-Host '2) Publicando el dashboard...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'desplegar-dashboard.ps1')
