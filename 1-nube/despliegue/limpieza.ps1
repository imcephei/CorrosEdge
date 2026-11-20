# Limpieza: (1) P-MTA-002, (2) aviso de clave vieja en el autorizador,
# (3) rol viejo, (4) direccion principal del dashboard, (5) alerta de costos.
# Cada parte revisa antes de tocar y se salta si algo no cuadra.
Set-Location (Join-Path $PSScriptRoot '..')
$region = 'us-east-2'
$cuenta = '<ID_CUENTA_AWS>'
$rolViejo = 'lambda-corrosion-role'
$distribucion = 'EQPQDJ72IZ4IX'
$utf8 = New-Object Text.UTF8Encoding $false

function Fallo($paso) { Write-Host "FALLO en: $paso. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 1
Write-Host '1) Revisando el dispositivo P-MTA-002...' -ForegroundColor Cyan
$existe = aws dynamodb get-item --table-name dispositivos --key file://pruebas-api/llave-mta-002.json --region $region --query 'Item.nombre.S' --output text
if ($LASTEXITCODE -ne 0) { Fallo 'leer P-MTA-002' }
$borrarMta002 = $false
if ($existe -eq 'None' -or -not $existe) {
    Write-Host '   No esta en la tabla dispositivos: no hay nada que borrar'
    $borrarMta002 = $true
} else {
    $lecturas = aws dynamodb query --table-name resultados_corrosion --key-condition-expression 'panel_id = :p' --expression-attribute-values file://pruebas-api/valores-mta-002.json --select COUNT --region $region --query Count --output text
    if ($LASTEXITCODE -ne 0) { Fallo 'contar lecturas de P-MTA-002' }
    $fotos = aws s3api list-objects-v2 --bucket imagenes-corrosion-detector --prefix 'paneles/P-MTA-002/' --query KeyCount --output text
    if ($LASTEXITCODE -ne 0) { Fallo 'contar fotos de P-MTA-002' }
    Write-Host "   '$existe': $lecturas lecturas, $fotos fotos"
    if ([int]$lecturas -eq 0 -and [int]$fotos -eq 0) {
        aws dynamodb delete-item --table-name dispositivos --key file://pruebas-api/llave-mta-002.json --region $region
        if ($LASTEXITCODE -ne 0) { Fallo 'borrar P-MTA-002' }
        Write-Host '   Sin informacion asociada: borrado de la tabla dispositivos'
        $borrarMta002 = $true
    } else {
        Write-Host '   Tiene informacion asociada: NO se borro. Pasale esto a Claude.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 2
Write-Host '2) Autorizador: aviso de clave vieja en el log y quitar la clave de P-MTA-002...' -ForegroundColor Cyan
$cfg = aws lambda get-function-configuration --function-name authorizer-corrosion --region $region | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { Fallo 'leer el autorizador' }
$vars = [ordered]@{}
$cfg.Environment.Variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
if ($borrarMta002 -and $vars['DEVICE_KEYS']) {
    $claves = $vars['DEVICE_KEYS'] | ConvertFrom-Json
    $nuevas = [ordered]@{}
    $claves.PSObject.Properties | Where-Object { $_.Value -ne 'P-MTA-002' } | ForEach-Object { $nuevas[$_.Name] = $_.Value }
    $vars['DEVICE_KEYS'] = ($nuevas | ConvertTo-Json -Compress)
    $tmp = Join-Path $env:TEMP 'env-autorizador.json'
    [IO.File]::WriteAllText($tmp, (@{ Variables = $vars } | ConvertTo-Json -Compress -Depth 3), $utf8)
    aws lambda update-function-configuration --function-name authorizer-corrosion --environment "file://$tmp" --region $region --query LastUpdateStatus --output text | Out-Null
    $codigo = $LASTEXITCODE; Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($codigo -ne 0) { Fallo 'actualizar DEVICE_KEYS' }
    aws lambda wait function-updated --function-name authorizer-corrosion --region $region
    Write-Host ("   Paneles con clave: " + (($nuevas.Values) -join ', '))
}
aws lambda update-function-code --function-name authorizer-corrosion --zip-file fileb://lambda-authorizer/function.zip --region $region --query FunctionName --output text | Out-Null
if ($LASTEXITCODE -ne 0) { Fallo 'subir el autorizador' }
aws lambda wait function-updated --function-name authorizer-corrosion --region $region
Write-Host '   Codigo actualizado (API_SECRET sigue activa hasta que Luis cambie la clave)'

# ---------------------------------------------------------------- 3
Write-Host "3) Rol viejo $rolViejo..." -ForegroundColor Cyan
$usan = aws lambda list-functions --region $region --query "Functions[?Role=='arn:aws:iam::${cuenta}:role/$rolViejo'].FunctionName" --output text
if ($LASTEXITCODE -ne 0) { Fallo 'revisar quien usa el rol viejo' }
aws iam get-role --role-name $rolViejo 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '   Ya no existe'
} elseif ($usan -and $usan -ne 'None') {
    Write-Host "   Todavia lo usa: $usan. NO se borro." -ForegroundColor Yellow
} else {
    $respaldo = 'infra\respaldo-rol-viejo'
    New-Item -ItemType Directory $respaldo -Force | Out-Null
    $adjuntas = aws iam list-attached-role-policies --role-name $rolViejo --query 'AttachedPolicies[].PolicyArn' --output text
    $propias = aws iam list-role-policies --role-name $rolViejo --query 'PolicyNames' --output text
    [IO.File]::WriteAllText((Join-Path $respaldo 'politicas-adjuntas.txt'), "$adjuntas", $utf8)
    foreach ($n in ($propias -split '\s+' | Where-Object { $_ -and $_ -ne 'None' })) {
        $doc = (aws iam get-role-policy --role-name $rolViejo --policy-name $n --query PolicyDocument --output json) -join "`n"
        [IO.File]::WriteAllText((Join-Path $respaldo "$n.json"), $doc, $utf8)
        aws iam delete-role-policy --role-name $rolViejo --policy-name $n
        if ($LASTEXITCODE -ne 0) { Fallo "borrar la politica $n" }
    }
    foreach ($a in ($adjuntas -split '\s+' | Where-Object { $_ -and $_ -ne 'None' })) {
        aws iam detach-role-policy --role-name $rolViejo --policy-arn $a
        if ($LASTEXITCODE -ne 0) { Fallo "soltar la politica $a" }
    }
    aws iam delete-role --role-name $rolViejo
    if ($LASTEXITCODE -ne 0) { Fallo 'borrar el rol viejo' }
    Write-Host "   Ninguna Lambda lo usaba: borrado. Sus permisos quedaron respaldados en $respaldo"
}

# ---------------------------------------------------------------- 4
Write-Host '4) Direccion principal del dashboard...' -ForegroundColor Cyan
$etag = aws cloudfront get-distribution-config --id $distribucion --query ETag --output text
if ($LASTEXITCODE -ne 0) { Fallo 'leer CloudFront' }
$conf = (aws cloudfront get-distribution-config --id $distribucion --query DistributionConfig --output json) -join "`n"
if ($conf -match '[^\x00-\x7F]') {
    Write-Host '   La configuracion tiene caracteres especiales: no se toco por seguridad. Avisale a Claude.' -ForegroundColor Yellow
} elseif ($conf -match '"DefaultRootObject":\s*"dashboard-v2\.html"') {
    Write-Host '   Ya apuntaba a dashboard-v2.html'
} else {
    $nueva = $conf -replace '"DefaultRootObject":\s*"[^"]*"', '"DefaultRootObject": "dashboard-v2.html"'
    $tmp = Join-Path $env:TEMP 'cloudfront-config.json'
    [IO.File]::WriteAllText($tmp, $nueva, $utf8)
    aws cloudfront update-distribution --id $distribucion --if-match $etag --distribution-config "file://$tmp" --query 'Distribution.Status' --output text | Out-Null
    $codigo = $LASTEXITCODE; Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($codigo -ne 0) { Fallo 'cambiar la pagina principal' }
    aws cloudfront create-invalidation --distribution-id $distribucion --paths '/' --query 'Invalidation.Status' --output text | Out-Null
    Write-Host '   Listo: la direccion sola ahora abre dashboard-v2.html (tarda unos minutos en propagarse)'
}

# ---------------------------------------------------------------- 5
Write-Host '5) Alerta de costos...' -ForegroundColor Cyan
aws budgets describe-budget --account-id $cuenta --budget-name corrosedge-mensual 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host '   Ya existia'
} else {
    aws budgets create-budget --account-id $cuenta --budget file://pruebas-api/presupuesto.json --notifications-with-subscribers file://pruebas-api/presupuesto-avisos.json
    if ($LASTEXITCODE -ne 0) { Fallo 'crear el presupuesto' }
    Write-Host '   Presupuesto de 5 USD/mes (sin contar creditos): avisa al 50 %, al 100 % y si el pronostico pasa de 5 USD'
}
Write-Host 'Limpieza terminada.' -ForegroundColor Green
