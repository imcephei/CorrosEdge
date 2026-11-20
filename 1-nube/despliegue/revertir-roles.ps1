# Devuelve todas las Lambdas al rol compartido de antes (lambda-corrosion-role).
$region = 'us-east-2'
$rolViejo = 'arn:aws:iam::<ID_CUENTA_AWS>:role/lambda-corrosion-role'
$plan = Get-Content (Join-Path $PSScriptRoot '..\infra\roles\plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($p in $plan) {
    aws lambda update-function-configuration --function-name $p.funcion --role $rolViejo --region $region --query FunctionName --output text
    aws lambda wait function-updated --function-name $p.funcion --region $region
}
Write-Host 'Todas las Lambdas volvieron a lambda-corrosion-role.' -ForegroundColor Green
