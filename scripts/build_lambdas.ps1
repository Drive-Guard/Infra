<#
.SYNOPSIS
    Empacota as Lambdas do DriveGuard em build/.

.DESCRIPTION
    Para cada função em lambdas/:
      1. cria build/<funcao>/ limpo;
      2. copia o handler;
      3. copia lambdas/common/ (helper de conexão) nas funções que falam com o RDS;
      4. instala as dependências de requirements.txt com pip --target;
      5. baixa o bundle de CAs do RDS, usado para validar o TLS do banco.

    O Terraform zipa build/<funcao>/ com o data source archive_file.
    Rode este script antes do `terraform apply` (o Makefile já faz isso).

.EXAMPLE
    ./scripts/build_lambdas.ps1
#>

[CmdletBinding()]
param(
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$LambdasDir = Join-Path $RepoRoot "lambdas"
$BuildDir   = Join-Path $RepoRoot "build"
$CommonDir  = Join-Path $LambdasDir "common"
$CaBundleUrl = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"

# Funções que abrem conexão com o RDS e por isso precisam de common/ + CA bundle.
$FuncoesComBanco = @("etl_silver", "etl_gold", "db_migrate")

Write-Host "==> Empacotando Lambdas do DriveGuard" -ForegroundColor Cyan

if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    throw "Python nao encontrado no PATH. Instale o Python 3.11+ ou passe -Python <caminho>."
}

# ---------------------------------------------------------------- CA bundle
$CaCache = Join-Path $BuildDir "_cache"
$CaFile  = Join-Path $CaCache "rds-ca-bundle.pem"

New-Item -ItemType Directory -Force -Path $CaCache | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BuildDir "_zips") | Out-Null

if (-not (Test-Path $CaFile)) {
    Write-Host "--> Baixando bundle de CAs do RDS"
    try {
        Invoke-WebRequest -Uri $CaBundleUrl -OutFile $CaFile -UseBasicParsing
    } catch {
        throw "Falha ao baixar $CaBundleUrl. As Lambdas de ETL nao conseguem validar o TLS do RDS sem esse arquivo. Detalhe: $_"
    }
}

if ((Get-Item $CaFile).Length -lt 1000) {
    throw "rds-ca-bundle.pem veio vazio ou truncado. Apague build/_cache e rode de novo."
}

# ---------------------------------------------------------------- funcoes
$Funcoes = Get-ChildItem -Path $LambdasDir -Directory |
           Where-Object { $_.Name -ne "common" -and $_.Name -ne "__pycache__" }

foreach ($f in $Funcoes) {
    $nome   = $f.Name
    $destino = Join-Path $BuildDir $nome

    Write-Host "--> $nome" -ForegroundColor Yellow

    if (Test-Path $destino) { Remove-Item -Recurse -Force $destino }
    New-Item -ItemType Directory -Force -Path $destino | Out-Null

    Copy-Item -Path (Join-Path $f.FullName "*.py") -Destination $destino -Force

    if ($FuncoesComBanco -contains $nome) {
        Copy-Item -Path (Join-Path $CommonDir "*.py") -Destination $destino -Force
        Copy-Item -Path $CaFile -Destination (Join-Path $destino "rds-ca-bundle.pem") -Force
    }

    $req = Join-Path $f.FullName "requirements.txt"
    if (Test-Path $req) {
        # Se o arquivo só tem comentários, pip não tem nada a instalar.
        $temPacotes = (Get-Content $req | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' }).Count -gt 0
        if ($temPacotes) {
            & $Python -m pip install --quiet --upgrade --target $destino -r $req
            if ($LASTEXITCODE -ne 0) { throw "pip install falhou para $nome" }
        }
    }

    # Bytecode e metadados de dist nao servem em runtime e so incham o zip.
    Get-ChildItem -Path $destino -Recurse -Directory -Include "__pycache__", "*.dist-info", "*.egg-info" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $tamanho = [math]::Round((Get-ChildItem $destino -Recurse -File | Measure-Object Length -Sum).Sum / 1KB, 1)
    Write-Host "    ok - $tamanho KB em build/$nome"
}

Write-Host "==> Build concluido. Rode 'terraform apply'." -ForegroundColor Green
