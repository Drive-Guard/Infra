<#
.SYNOPSIS
    Abre ou fecha o cofre de segredos do grupo (chave da IA, usuário de teste).

.DESCRIPTION
    Os segredos ficam versionados no repositório, cifrados, em
    segredos/segredos.tfvars.enc. Quem tem a senha do grupo abre o cofre e
    ganha o arquivo segredos.auto.tfvars na raiz do Infra, que o Terraform lê
    sozinho (e que não vai para o git).

    Cifra: AES-256-CBC com chave e IV derivados da senha por PBKDF2-SHA256
    (200 mil iterações e sal aleatório), no mesmo formato do openssl:
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -a
    Então o scripts/segredos.sh (Linux/macOS) abre o mesmo arquivo.

    A senha vem do parâmetro -Senha, da variável DG_SEGREDOS_SENHA ou é
    perguntada (sem eco).

.EXAMPLE
    ./scripts/segredos.ps1 -Abrir     # cofre -> segredos.auto.tfvars
    ./scripts/segredos.ps1 -Fechar    # segredos.auto.tfvars -> cofre (depois: git commit)
#>

[CmdletBinding(DefaultParameterSetName = "Abrir")]
param(
    [Parameter(ParameterSetName = "Abrir")][switch]$Abrir,
    [Parameter(ParameterSetName = "Fechar", Mandatory = $true)][switch]$Fechar,
    [string]$Senha
)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
$claro = Join-Path $raiz "segredos.auto.tfvars"
$cofre = Join-Path $raiz "segredos/segredos.tfvars.enc"
$ITERACOES = 200000

function Ler-Senha([bool]$confirmar) {
    if ($Senha) { return $Senha }
    if ($env:DG_SEGREDOS_SENHA) { return $env:DG_SEGREDOS_SENHA }
    $s1 = Read-Host "Senha do cofre do grupo" -AsSecureString
    $t1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
    if ($confirmar) {
        $s2 = Read-Host "Repita a senha" -AsSecureString
        $t2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
        if ($t1 -ne $t2) { throw "As senhas não conferem." }
        if ($t1.Length -lt 12) { throw "Use uma senha com pelo menos 12 caracteres." }
    }
    return $t1
}

function Derivar([string]$senha, [byte[]]$sal) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        [Text.Encoding]::UTF8.GetBytes($senha), $sal, $ITERACOES, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $bytes = $kdf.GetBytes(48)
    $kdf.Dispose()
    return , $bytes
}

function Novo-Aes([byte[]]$chaveIv) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $chaveIv[0..31]
    $aes.IV = $chaveIv[32..47]
    return $aes
}

if ($Fechar) {
    if (-not (Test-Path $claro)) { throw "Não achei $claro para cifrar." }
    $senhaTexto = Ler-Senha $true
    $sal = New-Object byte[] 8
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sal)
    $aes = Novo-Aes (Derivar $senhaTexto $sal)
    $dados = [IO.File]::ReadAllBytes($claro)
    $cifrado = $aes.CreateEncryptor().TransformFinalBlock($dados, 0, $dados.Length)
    $aes.Dispose()
    $saida = [Text.Encoding]::ASCII.GetBytes("Salted__") + $sal + $cifrado
    # Base64 em linhas de 64 caracteres (o formato -a do openssl).
    $b64 = [Convert]::ToBase64String($saida)
    $linhas = for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) }
    New-Item -ItemType Directory -Force -Path (Split-Path $cofre) | Out-Null
    [IO.File]::WriteAllText($cofre, ($linhas -join "`n") + "`n")
    Write-Host "Cofre atualizado: segredos/segredos.tfvars.enc. Faça o commit para o grupo receber." -ForegroundColor Green
} else {
    if (-not (Test-Path $cofre)) { throw "Não achei $cofre (o grupo ainda não fechou o cofre)." }
    $senhaTexto = Ler-Senha $false
    $bytes = [Convert]::FromBase64String(((Get-Content $cofre -Raw) -replace "\s", ""))
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne "Salted__") { throw "Arquivo do cofre em formato desconhecido." }
    $sal = $bytes[8..15]
    $aes = Novo-Aes (Derivar $senhaTexto $sal)
    try {
        $claroBytes = $aes.CreateDecryptor().TransformFinalBlock($bytes, 16, $bytes.Length - 16)
    } catch {
        throw "Senha errada (ou cofre corrompido)."
    } finally {
        $aes.Dispose()
    }
    [IO.File]::WriteAllBytes($claro, $claroBytes)
    Write-Host "Cofre aberto: segredos.auto.tfvars (o Terraform lê sozinho; não vai para o git)." -ForegroundColor Green
}
