# Crea la ruta GET /config: el dispositivo consulta su frecuencia y si esta activo.
# Crea la Lambda obtener-config-dispositivo, la conecta a la API con el mismo
# autorizador de los dispositivos y prueba la ruta. Se puede correr mas de una vez.
Set-Location (Join-Path $PSScriptRoot '..')
$region = 'us-east-2'
$apiId = '97i50k7oag'
$cuenta = '<ID_CUENTA_AWS>'
$funcion = 'obtener-config-dispositivo'
$api = "https://$apiId.execute-api.$region.amazonaws.com"

function Revisar($paso) {
    if ($LASTEXITCODE -ne 0) { Write-Host "FALLO en: $paso. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
}

Write-Host '1) Copiando la configuracion de generar-url-subida (rol y version de Python)...' -ForegroundColor Cyan
$ref = aws lambda get-function-configuration --function-name generar-url-subida --region $region | ConvertFrom-Json
Revisar 'leer generar-url-subida'
Write-Host "   Rol: $($ref.Role)"
Write-Host "   Python: $($ref.Runtime)"

Write-Host "2) Creando la Lambda $funcion..." -ForegroundColor Cyan
aws lambda get-function --function-name $funcion --region $region 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    aws lambda update-function-code --function-name $funcion --zip-file fileb://lambda-obtener-config/function.zip --region $region --query FunctionName --output text | Out-Null
    Revisar 'actualizar el codigo'
    Write-Host '   Ya existia: solo se actualizo el codigo'
} else {
    aws lambda create-function --function-name $funcion --runtime $ref.Runtime --role $ref.Role --handler lambda_function.lambda_handler --zip-file fileb://lambda-obtener-config/function.zip --timeout 10 --region $region --query FunctionArn --output text | Out-Null
    Revisar 'crear la Lambda'
    Write-Host '   Creada'
}
aws lambda wait function-active --function-name $funcion --region $region
$arn = "arn:aws:lambda:${region}:${cuenta}:function:$funcion"

Write-Host '3) Conectandola a la API...' -ForegroundColor Cyan
$rutas = aws apigatewayv2 get-routes --api-id $apiId --region $region | ConvertFrom-Json
Revisar 'leer las rutas'
$rutaUpload = $rutas.Items | Where-Object { $_.RouteKey -eq 'POST /upload-url' }
$integUpload = aws apigatewayv2 get-integration --api-id $apiId --integration-id ($rutaUpload.Target -replace 'integrations/', '') --region $region | ConvertFrom-Json
Revisar 'leer la integracion de /upload-url'
Write-Host "   Autorizador de los dispositivos: $($rutaUpload.AuthorizerId) / formato: $($integUpload.PayloadFormatVersion)"

if ($rutas.Items | Where-Object { $_.RouteKey -eq 'GET /config' }) {
    Write-Host '   La ruta GET /config ya existia'
} else {
    $integId = aws apigatewayv2 create-integration --api-id $apiId --integration-type AWS_PROXY --integration-uri $arn --payload-format-version $integUpload.PayloadFormatVersion --region $region --query IntegrationId --output text
    Revisar 'crear la integracion'
    aws apigatewayv2 create-route --api-id $apiId --route-key 'GET /config' --target "integrations/$integId" --authorization-type CUSTOM --authorizer-id $rutaUpload.AuthorizerId --region $region --query RouteId --output text | Out-Null
    Revisar 'crear la ruta'
    aws lambda add-permission --function-name $funcion --statement-id api-gateway-config --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${region}:${cuenta}:$apiId/*/*/config" --region $region | Out-Null
    Revisar 'dar permiso a la API'
    Write-Host '   Ruta GET /config creada con el autorizador de los dispositivos'
}

$etapas = aws apigatewayv2 get-stages --api-id $apiId --region $region | ConvertFrom-Json
foreach ($e in $etapas.Items) {
    if (-not $e.AutoDeploy) {
        aws apigatewayv2 create-deployment --api-id $apiId --stage-name $e.StageName --region $region | Out-Null
        Write-Host "   Etapa $($e.StageName) redesplegada"
    }
}

Write-Host '4) Probando...' -ForegroundColor Cyan
Start-Sleep -Seconds 5
$k = (Select-String 'claves-dispositivos.txt' -Pattern '^P-ACR-001: (.+)$').Matches[0].Groups[1].Value
Write-Host '   Clave de ACR pidiendo su configuracion (debe traer frecuencia_horas):'
Write-Host ('   ' + (curl.exe -s "$api/config" -H "x-api-key: $k"))
Write-Host '   Clave de ACR pidiendo la de MTA (debe decir no autorizada):'
Write-Host ('   ' + (curl.exe -s "$api/config?panel_id=P-MTA-001" -H "x-api-key: $k"))
Write-Host '   Sin clave (debe decir Unauthorized o Forbidden):'
Write-Host ('   ' + (curl.exe -s "$api/config"))
