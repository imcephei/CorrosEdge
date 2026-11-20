# Publica dashboard\dashboard-v2.html (con renovacion de sesion) en el bucket del
# dashboard y limpia la cache de CloudFront. Antes revisa que lo publicado sea la
# version anterior de tu carpeta, para no pisar cambios hechos por otro lado.
Set-Location (Join-Path $PSScriptRoot '..')
$bucket = 'dashboard-corrosion-juanp'
$distribucion = 'EQPQDJ72IZ4IX'
# Versiones que pueden estar publicadas hoy: la renovacion de sesion y el primer rediseno
$hashesAnteriores = @('131abb6e630f037213b380a5658bc5b8c74816ae8cae3ff1c4a2c62d46b03379', '7090d4bce43e0520a1cb8870c5125166897e9c4cd8a7a743e5e7265098f25e28', 'cbc4502f8dee43298085871812dd9f3fd3a255e8478d97d9b2335ebafe6afe33', 'a7899a7b28a9d985dbb99080aae52b52ed1d8e45debf3fb36de19900665155a1', '5bc3f38f773fec5c1cecafbd09e4be7a58ace4e3ff7b62b9749ec8a2b1112ffc', '8a611656018ee61aa2d8fc2d0672251ade794f85e4f4a0f1890bbac0129da9dc', 'b8248737161e721eb373a6d2d2f6576c09300deb0b4756ea94554c7b45581449')
$bucketFotos = 'imagenes-corrosion-detector'
$origen = 'https://d35c0bpdfopbh3.cloudfront.net'

function Revisar($paso) {
    if ($LASTEXITCODE -ne 0) { Write-Host "FALLO en: $paso. Copia el error y pasaselo a Claude." -ForegroundColor Red; exit 1 }
}
function HuellaTexto($ruta) {
    $t = ((Get-Content $ruta -Raw -Encoding UTF8) -replace "`r`n", "`n").Trim()
    $sha = [Security.Cryptography.SHA256]::Create()
    -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t)) | ForEach-Object { $_.ToString('x2') })
}

Write-Host '1) Buscando la pagina publicada...' -ForegroundColor Cyan
$claves = aws s3api list-objects-v2 --bucket $bucket --query "Contents[?ends_with(Key, '.html')].Key" --output text
Revisar 'listar el bucket'
$tmp = Join-Path $env:TEMP 'dashboard-publicado'
New-Item -ItemType Directory $tmp -Force | Out-Null
$destino = $null
foreach ($c in ($claves -split '\s+' | Where-Object { $_ })) {
    $archivo = Join-Path $tmp ($c -replace '/', '_')
    aws s3 cp "s3://$bucket/$c" $archivo --quiet
    Revisar "descargar $c"
    $igual = $hashesAnteriores -contains (HuellaTexto $archivo)
    Write-Host ("   {0,-28} {1}" -f $c, $(if ($igual) { 'es la version anterior de tu carpeta' } else { 'otra pagina' }))
    if ($igual) { $destino = $c }
}
if (-not $destino) {
    Write-Host 'Ninguna pagina publicada coincide con tu version anterior: no se publico nada. Pasale esto a Claude.' -ForegroundColor Yellow
    exit 1
}

Write-Host '2) Permiso para que el dashboard lea las fotos al armar el PDF (CORS)...' -ForegroundColor Cyan
$cors = (aws s3api get-bucket-cors --bucket $bucketFotos --output json 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0 -or -not $cors) {
    $tmp = Join-Path $env:TEMP 'cors-fotos.json'
    $regla = '{"CORSRules":[{"AllowedOrigins":["' + $origen + '"],"AllowedMethods":["GET"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}'
    [IO.File]::WriteAllText($tmp, $regla, (New-Object Text.UTF8Encoding $false))
    aws s3api put-bucket-cors --bucket $bucketFotos --cors-configuration "file://$tmp"
    $codigo = $LASTEXITCODE; Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($codigo -ne 0) { Write-Host 'FALLO al dar el permiso CORS. Copia el error y pasaselo a Claude.' -ForegroundColor Red; exit 1 }
    Write-Host "   Listo: solo $origen puede leer las fotos desde el navegador (y solo con URL firmada)"
} elseif ($cors -match [regex]::Escape($origen)) {
    Write-Host '   Ya estaba'
} else {
    Write-Host '   El bucket ya tiene otra regla CORS: no se toco. El PDF saldria sin fotos; avisale a Claude.' -ForegroundColor Yellow
}

Write-Host "3) Publicando la version nueva en $destino y el logo..." -ForegroundColor Cyan
foreach ($img in 'corrosedge-logo.png', 'corrosedge-logo-claro.png', 'corrosedge-icono.png') {
    aws s3 cp "dashboard\$img" "s3://$bucket/$img" --content-type 'image/png' --cache-control 'max-age=86400' --quiet
    Revisar "subir $img"
}
# fotos del modo demostracion (las 12 pruebas de laboratorio, reducidas)
if (Test-Path 'dashboard\demo') {
    aws s3 sync 'dashboard\demo' "s3://$bucket/demo" --exclude '*' --include '*.jpg' --content-type 'image/jpeg' --cache-control 'max-age=86400' --quiet
    Revisar 'subir las fotos de la demostracion'
}
aws s3 cp 'dashboard\dashboard-v2.html' "s3://$bucket/$destino" --content-type 'text/html; charset=utf-8' --quiet
Revisar 'subir el dashboard'
aws cloudfront create-invalidation --distribution-id $distribucion --paths "/$destino" "/" "/corrosedge-*" "/demo/*" --query 'Invalidation.Status' --output text
Revisar 'limpiar la cache de CloudFront'
Write-Host 'Listo. En 1 o 2 minutos CloudFront entrega la version nueva.' -ForegroundColor Green
