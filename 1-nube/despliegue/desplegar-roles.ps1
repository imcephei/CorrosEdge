# Un rol de IAM por Lambda (minimo privilegio). Los permisos de cada rol estan
# en infra\roles\<funcion>.json. El rol viejo (lambda-corrosion-role) NO se borra:
# si algo falla, pruebas-api\revertir-roles.ps1 devuelve todo como estaba.
Set-Location (Join-Path $PSScriptRoot '..')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$region = 'us-east-2'
$cuenta = '<ID_CUENTA_AWS>'
$api = 'https://97i50k7oag.execute-api.us-east-2.amazonaws.com'

function Revisar($paso) {
    if ($LASTEXITCODE -ne 0) { Write-Host "FALLO en: $paso. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
}
function Normalizar($ruta) { ((Get-Content $ruta -Raw -Encoding UTF8) -replace "`r`n", "`n").Trim() }

$plan = Get-Content 'infra\roles\plan.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$tmp = Join-Path $env:TEMP 'roles-corrosion'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null

Write-Host '1) Comparando el codigo desplegado en AWS con el de tu carpeta...' -ForegroundColor Cyan
$aplicar = @()
foreach ($p in $plan) {
    $url = aws lambda get-function --function-name $p.funcion --region $region --query Code.Location --output text
    Revisar "leer $($p.funcion)"
    $zip = Join-Path $tmp "$($p.funcion).zip"
    $dir = Join-Path $tmp $p.funcion
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dir -Force
    } catch {
        Write-Host "FALLO al descargar el codigo de $($p.funcion): $_" -ForegroundColor Red; exit 1
    }
    $remoto = Join-Path $dir 'lambda_function.py'
    $local = Join-Path $p.carpeta 'lambda_function.py'
    if ((Test-Path $remoto) -and ((Normalizar $remoto) -eq (Normalizar $local))) {
        Write-Host "   igual     $($p.funcion)"
        $aplicar += $p
    } else {
        Write-Host "   DISTINTO  $($p.funcion): no se le cambia el rol (avisale a Claude)" -ForegroundColor Yellow
    }
}

Write-Host '2) Creando un rol por funcion con sus permisos...' -ForegroundColor Cyan
foreach ($p in $aplicar) {
    aws iam get-role --role-name $p.rol 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        aws iam create-role --role-name $p.rol --assume-role-policy-document file://infra/roles/confianza-lambda.json --description $p.descripcion | Out-Null
        Revisar "crear $($p.rol)"
    }
    aws iam put-role-policy --role-name $p.rol --policy-name permisos-minimos --policy-document "file://infra/roles/$($p.funcion).json"
    Revisar "permisos de $($p.rol)"
    Write-Host "   $($p.rol)"
}
Write-Host '   Esperando 15 s a que IAM propague los roles nuevos...'
Start-Sleep -Seconds 15

Write-Host '3) Verificando cada rol con el simulador de IAM (sin tocar datos)...' -ForegroundColor Cyan
$fallas = 0
foreach ($p in $aplicar) {
    $arnRol = "arn:aws:iam::${cuenta}:role/$($p.rol)"
    $permitidas = 0; $total = 0
    foreach ($s in $p.simular) {
        $res = aws iam simulate-principal-policy --policy-source-arn $arnRol --action-names $s.acciones --resource-arns $s.recurso --query 'EvaluationResults[].EvalDecision' --output text
        Revisar "simular $($p.rol)"
        foreach ($d in ($res -split '\s+' | Where-Object { $_ })) { $total++; if ($d -eq 'allowed') { $permitidas++ } }
    }
    $borrar = aws iam simulate-principal-policy --policy-source-arn $arnRol --action-names dynamodb:DeleteItem --resource-arns "arn:aws:dynamodb:${region}:${cuenta}:table/resultados_corrosion" --query 'EvaluationResults[0].EvalDecision' --output text
    $ok = ($permitidas -eq $total) -and ($borrar -ne 'allowed')
    if (-not $ok) { $fallas++ }
    $color = if ($ok) { 'Gray' } else { 'Red' }
    Write-Host ("   {0,-30} necesita {1}/{2} permitidos | borrar lecturas: {3}" -f $p.funcion, $permitidas, $total, $borrar) -ForegroundColor $color
}
if ($fallas -gt 0) { Write-Host 'Hay roles con permisos incompletos: no se cambio nada en las Lambdas. Pasale esto a Claude.' -ForegroundColor Red; exit 1 }

Write-Host '4) Asignando cada rol a su Lambda...' -ForegroundColor Cyan
foreach ($p in $aplicar) {
    $arnRol = "arn:aws:iam::${cuenta}:role/$($p.rol)"
    for ($i = 1; $i -le 6; $i++) {
        aws lambda update-function-configuration --function-name $p.funcion --role $arnRol --region $region --query LastUpdateStatus --output text 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 5
    }
    Revisar "asignar el rol a $($p.funcion)"
    aws lambda wait function-updated --function-name $p.funcion --region $region
    Write-Host "   $($p.funcion) -> $($p.rol)"
}

Write-Host '5) Probando la API con los roles nuevos...' -ForegroundColor Cyan
$k = (Read-Host 'Pega la clave de P-ACR-001 y presiona Enter').Trim()
Write-Host ('   /config:     ' + (curl.exe -s "$api/config" -H "x-api-key: $k"))
$r = curl.exe -s -X POST "$api/upload-url" -H "x-api-key: $k" -H "Content-Type: application/json" --data '@pruebas-api/panel-acr.json'
Write-Host ('   /upload-url: ' + $r.Substring(0, [Math]::Min(70, $r.Length)) + '...')
Write-Host 'Listo. Ahora entra al dashboard y revisa que cargue el mapa y el historial.' -ForegroundColor Green
