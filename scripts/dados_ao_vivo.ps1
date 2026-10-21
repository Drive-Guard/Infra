<#
.SYNOPSIS
    Liga, desliga ou mostra o estado dos dados ao vivo (simulador de frota).

.DESCRIPTION
    Os dados "ao vivo" vêm da Lambda simulador: a cada minuto o EventBridge a
    dispara, ela monta as leituras dos motoristas que estão no turno naquele
    horário (mesma escala e modelo de fadiga do seed) e envia para a API de
    ingestão real. Daí em diante é o caminho de produção (Bronze -> ETL ->
    banco -> dashboard).

    Este script liga ou desliga a regra do EventBridge; o terraform apply
    seguinte não desfaz a escolha. Ao ligar, também pede ao simulador que
    preencha as lacunas: do último dado de cada câmera (ou da meia-noite de
    hoje, se não houver nenhum) até agora, até 30 dias para trás. Assim a
    dashboard já abre com o dia completo, e dali para frente segue ao vivo.

    Desligado: o dashboard mostra o histórico, mas nada "dirigindo agora".
    Para a apresentação sem dados chegando, rode antes o injetar_dados (os
    turnos do momento da injeção ficam visíveis por 30 minutos).

.EXAMPLE
    ./scripts/dados_ao_vivo.ps1            # estado atual
    ./scripts/dados_ao_vivo.ps1 -Ligar
    ./scripts/dados_ao_vivo.ps1 -Desligar
#>

[CmdletBinding(DefaultParameterSetName = "Status")]
param(
    [Parameter(ParameterSetName = "Ligar")][switch]$Ligar,
    [Parameter(ParameterSetName = "Desligar")][switch]$Desligar,
    [string]$Regiao = "us-east-1",
    [string]$Prefixo = "driveguard-dev"
)

$ErrorActionPreference = "Stop"
$regra = "$Prefixo-simulador"

function Estado {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $s = aws events describe-rule --region $Regiao --name $regra --query State --output text 2>$null
    $ErrorActionPreference = $anterior
    if ($LASTEXITCODE) { throw "Regra $regra não encontrada: o simulador está criado? (terraform apply com enable_simulador = true)" }
    return $s
}

if ($Ligar) {
    aws events enable-rule --region $Regiao --name $regra | Out-Null
    if ($LASTEXITCODE) { throw "Falha ao ligar $regra" }
    # Assíncrono: o preenchimento leva alguns minutos e roda sozinho na Lambda.
    $evento = Join-Path $env:TEMP "driveguard-preencher.json"
    [IO.File]::WriteAllText($evento, '{"preencher": true}')
    $saida = Join-Path $env:TEMP "driveguard-preencher-saida.json"
    $anterior = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    aws lambda invoke --region $Regiao --function-name $regra --invocation-type Event --payload "fileb://$evento" $saida 2>$null | Out-Null
    $ErrorActionPreference = $anterior
    if ($LASTEXITCODE) { Write-Host "Aviso: não consegui pedir o preenchimento agora; ele roda sozinho em até 15 min." -ForegroundColor Yellow }
    else { Write-Host "Preenchendo as lacunas até agora (alguns minutos; a dashboard atualiza sozinha)." -ForegroundColor Cyan }
} elseif ($Desligar) {
    aws events disable-rule --region $Regiao --name $regra | Out-Null
    if ($LASTEXITCODE) { throw "Falha ao desligar $regra" }
}

$estado = Estado
if ($estado -eq "ENABLED") {
    Write-Host "Dados ao vivo: LIGADOS (simulador enviando leituras a cada minuto)" -ForegroundColor Green
} else {
    Write-Host "Dados ao vivo: DESLIGADOS (o dashboard mostra só o histórico)" -ForegroundColor Yellow
}
