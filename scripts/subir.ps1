<#
.SYNOPSIS
    Sobe o DriveGuard inteiro num computador sem nada instalado (um clique).

.DESCRIPTION
    Chamado pelo subir.cmd (duplo clique). Em ordem:

      1. baixa as ferramentas em versões fixas, conferindo o SHA-256, para
         %LOCALAPPDATA%\DriveGuard\ferramentas (Terraform, Node.js, Python,
         AWS CLI e, se faltarem, Git e GitHub CLI). Nada é instalado no
         Windows e nada exige administrador;
      2. clona (ou atualiza) Backend e Site ao lado deste Infra. O Site é
         privado: se o computador ainda não tem login do GitHub, abre o login
         no navegador (uma vez) e clona;
      3. lê as credenciais do Learner Lab da área de transferência (ou pede
         para colar) e grava em ~/.aws/credentials;
      4. abre o cofre de segredos do grupo (pede a senha);
      5. guarda o state do Terraform num bucket S3 da própria conta
         (driveguard-tfstate-<conta>), para qualquer colega do grupo continuar
         de onde o outro parou. Na primeira vez, migra o state local;
      6. roda o terraform apply, com novas tentativas, e abre o dashboard.

    Rodar de novo é seguro: o que já existe é reaproveitado e o apply só
    muda o que mudou. Tudo fica registrado em
    %LOCALAPPDATA%\DriveGuard\logs.

.PARAMETER SoInfra
    Sobe só a infraestrutura (sem deploy do Backend e sem publicar o site).

.PARAMETER Desligar
    Prepara tudo igual e, em vez do apply, destrói o ambiente
    (scripts/desligar.ps1). Pede confirmação.

.EXAMPLE
    ./subir.cmd
    ./scripts/subir.ps1 -SoInfra
    ./scripts/subir.ps1 -Desligar
#>

[CmdletBinding()]
param(
    [string]$SenhaCofre = "",
    [switch]$SoInfra,
    [switch]$Desligar,
    [switch]$NaoAbrirNavegador
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # o Invoke-WebRequest do PS 5.1 fica 10x mais lento com a barra
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8

$REGIAO = "us-east-1"
$ORG = "Drive-Guard"
$CHAVE_STATE = "driveguard/dev/terraform.tfstate"
$UTF8_SEM_BOM = New-Object System.Text.UTF8Encoding($false)

# Versões fixas: o que foi testado é o que roda. Para atualizar, troque
# versão, URL e hash juntos (os hashes vêm dos SHA256SUMS de cada projeto).
$FERRAMENTAS = [ordered]@{
    terraform = @{
        Versao = "1.16.2"; Tipo = "zip"; Bin = ""; Exe = "terraform.exe"
        Url    = "https://releases.hashicorp.com/terraform/1.16.2/terraform_1.16.2_windows_amd64.zip"
        Sha256 = "6ef140ce1d399dc43b8315194176ddc2dfb5c21d607968e82ef20a55cfff40d0"
    }
    node = @{
        Versao = "24.20.0"; Tipo = "zip"; Bin = "node-v24.20.0-win-x64"; Exe = "node.exe"
        Url    = "https://nodejs.org/dist/v24.20.0/node-v24.20.0-win-x64.zip"
        Sha256 = "6cac9ffbca8f6a47091e4b5c772e0606049c3871cb67d900c0cedde630e545ba"
    }
    python = @{
        # O pacote NuGet oficial do Python: um Python completo (com pip) num zip.
        Versao = "3.12.10"; Tipo = "zip"; Bin = "tools"; Exe = "python.exe"
        Url    = "https://api.nuget.org/v3-flatcontainer/python/3.12.10/python.3.12.10.nupkg"
        Sha256 = "0eb85c2dfccccf1b17352de4c397f69194035b7d37149eacc16f1147d93de3b8"
    }
    aws = @{
        # O MSI é só extraído (msiexec /a), não instalado: não pede administrador.
        Versao = "2.36.45"; Tipo = "msi"; Bin = "Amazon\AWSCLIV2"; Exe = "aws.exe"
        Url    = "https://awscli.amazonaws.com/AWSCLIV2-2.36.45.msi"
        Sha256 = "9ab9d14ad5bd935ecb5176ce39d39d8744bc1bb9c380a22e09c8f354f7e5cc2b"
    }
    git = @{
        Versao = "2.56.0.2"; Tipo = "zip"; Bin = "cmd"; Exe = "git.exe"; SoSeFaltar = $true
        Url    = "https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/MinGit-2.56.0.2-64-bit.zip"
        Sha256 = "da35e72aa21c005a5a0d298cfbae110bc1609a815730ea0dde84b01a1b3cd3be"
    }
    gh = @{
        Versao = "2.101.0"; Tipo = "zip"; Bin = "bin"; Exe = "gh.exe"; SoSeFaltar = $true
        Url    = "https://github.com/cli/cli/releases/download/v2.101.0/gh_2.101.0_windows_amd64.zip"
        Sha256 = "bc6c814367b193cd8e713611d61e36013c0ef843b8f516458fe3eda039192794"
    }
}

# ============================================================================
# Saída e utilitários
# ============================================================================

$RaizLocal = Join-Path $env:LOCALAPPDATA "DriveGuard"
$DirFerramentas = Join-Path $RaizLocal "ferramentas"
$DirLogs = Join-Path $RaizLocal "logs"
New-Item -ItemType Directory -Force -Path $DirFerramentas, $DirLogs | Out-Null
$ArquivoLog = Join-Path $DirLogs ("subir-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $ArquivoLog -Append | Out-Null } catch { }

function Etapa([string]$texto) { Write-Host ""; Write-Host "==> $texto" -ForegroundColor Cyan }
function Info([string]$texto) { Write-Host "    $texto" }
function Ok([string]$texto) { Write-Host "    $texto" -ForegroundColor Green }
function Aviso([string]$texto) { Write-Host "    ATENCAO: $texto" -ForegroundColor Yellow }

function Falhar([string]$texto) {
    Write-Host ""
    Write-Host "==> NAO DEU CERTO: $texto" -ForegroundColor Red
    Write-Host "    Rodar de novo é seguro: o que já foi feito é reaproveitado."
    Write-Host "    Registro completo: $ArquivoLog"
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# Roda um executável e devolve código e saída. No PS 5.1, stderr de programa
# nativo com ErrorActionPreference=Stop vira exceção; aqui ele só é lido.
function Exec([string]$exe, [string[]]$argumentos, [switch]$AoVivo) {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $linhas = New-Object System.Collections.Generic.List[string]
    try {
        & $exe @argumentos 2>&1 | ForEach-Object {
            $t = "$_"
            $linhas.Add($t)
            if ($AoVivo) { Write-Host $t }
        }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    return [pscustomobject]@{ Codigo = $codigo; Saida = ($linhas -join "`n") }
}

# Linhas coladas a mais ficariam no buffer do console e cairiam na próxima
# pergunta (a senha do cofre, por exemplo).
function Limpar-Entrada { try { $Host.UI.RawUI.FlushInputBuffer() } catch { } }

function Perguntar-SimNao([string]$pergunta, [bool]$padrao) {
    $sufixo = if ($padrao) { "[S/n]" } else { "[s/N]" }
    $r = Read-Host "    $pergunta $sufixo"
    if (-not $r) { return $padrao }
    return $r.Trim().ToLower().StartsWith("s")
}

function Baixar([string]$url, [string]$destino, [string]$sha256) {
    $parcial = "$destino.parcial"
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    for ($tentativa = 1; $tentativa -le 4; $tentativa++) {
        try {
            if (Test-Path $parcial) { Remove-Item -Force $parcial }
            if (Test-Path $curl) {
                $r = Exec $curl @("-fL", "--retry", "3", "--retry-delay", "3", "--connect-timeout", "30", "-sS", "-o", $parcial, $url)
                if ($r.Codigo -ne 0) { throw "curl: $($r.Saida)" }
            } else {
                Invoke-WebRequest -Uri $url -OutFile $parcial -UseBasicParsing -TimeoutSec 900
            }
            $hash = (Get-FileHash -Algorithm SHA256 $parcial).Hash.ToLower()
            if ($sha256 -and $hash -ne $sha256) { throw "o arquivo baixado não confere (SHA-256 $hash)" }
            Move-Item -Force $parcial $destino
            return
        } catch {
            Aviso "download falhou (tentativa $tentativa de 4): $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $tentativa)
        }
    }
    Falhar "não consegui baixar $url. Confira a internet (ou proxy/antivírus) e rode de novo."
}

function Extrair-Zip([string]$zip, [string]$destino) {
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $tar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (Test-Path $tar) {
        $r = Exec $tar @("-xf", $zip, "-C", $destino)
        if ($r.Codigo -eq 0) { return }
    }
    # Fallback lento, mas presente em todo Windows. Exige extensão .zip.
    $comoZip = [IO.Path]::ChangeExtension($zip, ".zip")
    if ($comoZip -ne $zip) { Copy-Item -Force $zip $comoZip }
    Expand-Archive -Force -Path $comoZip -DestinationPath $destino
}

function Garantir-Ferramenta([string]$nome) {
    $f = $FERRAMENTAS[$nome]
    if ($f.SoSeFaltar) {
        $doSistema = Get-Command $f.Exe -ErrorAction SilentlyContinue
        if ($doSistema) { return $doSistema.Source }
    }
    $dir = Join-Path $DirFerramentas "$nome-$($f.Versao)"
    $bin = if ($f.Bin) { Join-Path $dir $f.Bin } else { $dir }
    $exe = Join-Path $bin $f.Exe
    $marca = Join-Path $dir ".instalado"
    if ((Test-Path $marca) -and (Test-Path $exe)) { return $exe }

    Info "baixando $nome $($f.Versao)..."
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pacote = Join-Path $DirFerramentas ("{0}-{1}.{2}" -f $nome, $f.Versao, $(if ($f.Tipo -eq "msi") { "msi" } else { "zip" }))
    if (-not (Test-Path $pacote) -or ((Get-FileHash -Algorithm SHA256 $pacote).Hash.ToLower() -ne $f.Sha256)) {
        Baixar $f.Url $pacote $f.Sha256
    }
    if ($f.Tipo -eq "msi") {
        # O msiexec extrai pelo serviço do Windows Installer (conta SYSTEM). Em
        # %TEMP% ele sempre enxerga os arquivos; depois movemos para o lugar final.
        $tmpMsi = Join-Path $env:TEMP "driveguard-$nome.msi"
        $tmpDir = Join-Path $env:TEMP "driveguard-$nome-extraido"
        Copy-Item -Force $pacote $tmpMsi
        for ($tentativa = 1; $tentativa -le 4; $tentativa++) {
            if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
            $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @("/a", "`"$tmpMsi`"", "/qn", "TARGETDIR=`"$tmpDir`"")
            if ($p.ExitCode -eq 0) { break }
            # 1618: outra instalação (Windows Update, por exemplo) está rodando.
            Aviso "msiexec saiu com $($p.ExitCode) (tentativa $tentativa de 4)"
            Start-Sleep -Seconds 20
        }
        if ($p.ExitCode -ne 0) { Falhar "não consegui extrair o $nome (msiexec saiu com $($p.ExitCode))." }
        Get-ChildItem -Force $tmpDir | Move-Item -Destination $dir -Force
        Remove-Item -Force $tmpMsi -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    } else {
        Extrair-Zip $pacote $dir
    }
    if (-not (Test-Path $exe)) { Falhar "o pacote do $nome não tem $exe." }
    Set-Content -Path $marca -Value $f.Versao
    Remove-Item -Force $pacote -ErrorAction SilentlyContinue
    return $exe
}

function Adicionar-AoPath([string]$exe) {
    $dir = Split-Path -Parent $exe
    if (-not (($env:Path -split ";") -contains $dir)) { $env:Path = "$dir;$env:Path" }
}

# ============================================================================
# 0. Conferências básicas
# ============================================================================

Write-Host ""
Write-Host "  DriveGuard - subir o projeto" -ForegroundColor White
Write-Host "  Registro: $ArquivoLog" -ForegroundColor DarkGray

Etapa "Conferindo o computador"
if (-not [Environment]::Is64BitOperatingSystem) { Falhar "o Windows precisa ser 64 bits." }
if ($PSVersionTable.PSVersion.Major -lt 5) { Falhar "precisa do PowerShell 5.1 ou mais novo (Windows 10/11 já vem com ele)." }
$unidade = (Get-Item $env:LOCALAPPDATA).PSDrive
if ($unidade.Free -and $unidade.Free -lt 3GB) {
    Falhar ("pouco espaço livre em {0}: (precisa de 3 GB, tem {1:N1} GB)." -f $unidade.Name, ($unidade.Free / 1GB))
}
foreach ($site in @("https://github.com", "https://releases.hashicorp.com", "https://sts.us-east-1.amazonaws.com")) {
    $ok = $false
    for ($i = 1; $i -le 3 -and -not $ok; $i++) {
        try { Invoke-WebRequest -Uri $site -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null; $ok = $true }
        catch {
            # Responder com erro HTTP (403, 404...) também prova que a internet chega lá.
            if ($_.Exception.Response) { $ok = $true } else { Start-Sleep -Seconds 3 }
        }
    }
    if (-not $ok) { Falhar "sem acesso a $site. Confira a internet e rode de novo." }
}
Ok "Windows 64 bits, PowerShell $($PSVersionTable.PSVersion), internet ok"

# ============================================================================
# 1. Ferramentas
# ============================================================================

Etapa "Ferramentas (versões fixas, em $DirFerramentas)"
foreach ($nome in @("git", "terraform", "node", "python", "aws")) {
    $exe = Garantir-Ferramenta $nome
    Adicionar-AoPath $exe
    Set-Variable -Name "EXE_$nome" -Value $exe
    Info ("{0,-10} {1}" -f $nome, $exe)
}
# O Python vem sem pip.exe no PATH; o build das Lambdas usa "python -m pip".
$r = Exec $EXE_python @("-m", "pip", "--version")
if ($r.Codigo -ne 0) {
    $r = Exec $EXE_python @("-m", "ensurepip", "--default-pip")
    if ($r.Codigo -ne 0) { Falhar "o pip do Python portátil não funcionou: $($r.Saida)" }
}
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
$env:GIT_TERMINAL_PROMPT = "0"   # git nunca fica parado esperando usuário/senha no console
$env:CHECKPOINT_DISABLE = "1"    # Terraform sem checagem de versão
$env:NPM_CONFIG_FUND = "false"
$env:NPM_CONFIG_AUDIT = "false"
Ok "ferramentas prontas"

# ============================================================================
# 2. Repositórios
# ============================================================================

Etapa "Repositórios"

# Backend e Site ficam ao lado deste Infra (é onde o app.tf procura).
$InfraDir = Split-Path -Parent $PSScriptRoot
$Base = Split-Path -Parent $InfraDir
Info "pasta base: $Base"

$script:GhPronto = $false
function Garantir-LoginGitHub {
    if ($script:GhPronto) { return }
    $gh = Garantir-Ferramenta "gh"
    Adicionar-AoPath $gh
    $script:EXE_gh = $gh
    $r = Exec $gh @("auth", "status", "--hostname", "github.com")
    if ($r.Codigo -ne 0) {
        Write-Host ""
        Write-Host "    O repositório Site é privado. Vou abrir o login do GitHub:" -ForegroundColor White
        Write-Host "    copie o código que aparecer, cole na página do navegador e autorize." -ForegroundColor White
        Write-Host "    (Use a conta do GitHub que tem acesso à organização $ORG.)" -ForegroundColor White
        Write-Host ""
        Limpar-Entrada
        # Start-Process mantém o console de verdade (o gh só pergunta com TTY).
        $p = Start-Process -FilePath $gh -NoNewWindow -Wait -PassThru `
            -ArgumentList @("auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web")
        if ($p.ExitCode -ne 0) { Falhar "o login do GitHub não foi concluído. Rode de novo e autorize no navegador." }
    }
    $script:GhPronto = $true
}

function Atualizar-Repo([string]$nome, [string]$dir, [bool]$privado) {
    $url = "https://github.com/$ORG/$nome.git"
    if (Test-Path (Join-Path $dir ".git")) {
        $ramo = (Exec $EXE_git @("-C", $dir, "rev-parse", "--abbrev-ref", "HEAD")).Saida.Trim()
        $sujo = (Exec $EXE_git @("-C", $dir, "status", "--porcelain", "--untracked-files=no")).Saida.Trim()
        if ($ramo -ne "main") { Aviso "$nome está no branch '$ramo': não atualizei (uso como está)."; return }
        if ($sujo) { Aviso "$nome tem alterações locais: não atualizei (uso como está)."; return }
        $r = Exec $EXE_git @("-C", $dir, "pull", "--ff-only", "--quiet")
        if ($r.Codigo -ne 0 -and $privado) {
            Garantir-LoginGitHub
            $anterior = Get-Location
            Set-Location $dir
            $r = Exec $script:EXE_gh @("repo", "sync")
            Set-Location $anterior
        }
        if ($r.Codigo -eq 0) { Ok "$nome atualizado (main)" } else { Aviso "não consegui atualizar $nome; uso a cópia local." }
        return
    }
    if (Test-Path $dir) {
        if (Get-ChildItem -Force $dir | Select-Object -First 1) { Info "$nome já existe em $dir (sem git): uso como está."; return }
        Remove-Item -Force $dir
    }
    Info "clonando $nome..."
    for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
        $r = Exec $EXE_git @("clone", "--quiet", $url, $dir)
        if ($r.Codigo -eq 0) { Ok "$nome clonado"; return }
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        if ($privado) { break }
        Start-Sleep -Seconds (5 * $tentativa)
    }
    if (-not $privado) { Falhar "não consegui clonar $url : $($r.Saida)" }
    # Privado e sem login do GitHub neste computador: entra e clona com o gh.
    Garantir-LoginGitHub
    for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
        $r = Exec $script:EXE_gh @("repo", "clone", "$ORG/$nome", $dir, "--", "--quiet")
        if ($r.Codigo -eq 0) { Ok "$nome clonado (login do GitHub)"; return }
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Start-Sleep -Seconds (5 * $tentativa)
    }
    Falhar "não consegui clonar $ORG/$nome. Confira se entrou no GitHub com a conta da organização $ORG : $($r.Saida)"
}

Atualizar-Repo "Infra" $InfraDir $false
Atualizar-Repo "Backend" (Join-Path $Base "Backend") $false
Atualizar-Repo "Site" (Join-Path $Base "Site") $true
Set-Location $InfraDir

# ============================================================================
# 3. Credenciais da AWS (Learner Lab)
# ============================================================================

Etapa "Credenciais da AWS"

$DirAws = Join-Path $env:USERPROFILE ".aws"
$ArqCredenciais = Join-Path $DirAws "credentials"
$ArqConfig = Join-Path $DirAws "config"
# Variáveis de ambiente antigas teriam prioridade sobre o arquivo.
foreach ($v in @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "AWS_DEFAULT_PROFILE")) {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
$env:AWS_DEFAULT_REGION = $REGIAO
$env:AWS_REGION = $REGIAO
$env:AWS_PAGER = ""

function Ler-Bloco([string]$texto) {
    if (-not $texto) { return $null }
    $c = @{}
    foreach ($chave in @("aws_access_key_id", "aws_secret_access_key", "aws_session_token")) {
        $m = [regex]::Match($texto, "(?im)^\s*$chave\s*=\s*(\S+)\s*$")
        if (-not $m.Success) { return $null }
        $c[$chave] = $m.Groups[1].Value
    }
    return $c
}

function Gravar-Credenciais($c) {
    New-Item -ItemType Directory -Force -Path $DirAws | Out-Null
    # Troca só o [default]; outros profiles do arquivo ficam como estão.
    $outras = New-Object System.Collections.Generic.List[string]
    if (Test-Path $ArqCredenciais) {
        $dentro = $false
        foreach ($linha in [IO.File]::ReadAllLines($ArqCredenciais)) {
            if ($linha -match "^\s*\[(.+)\]\s*$") { $dentro = ($Matches[1].Trim() -eq "default") }
            if (-not $dentro) { $outras.Add($linha) }
        }
    }
    $novo = @("[default]",
        "aws_access_key_id=$($c.aws_access_key_id)",
        "aws_secret_access_key=$($c.aws_secret_access_key)",
        "aws_session_token=$($c.aws_session_token)", "") + $outras
    [IO.File]::WriteAllText($ArqCredenciais, ($novo -join "`r`n").TrimEnd() + "`r`n", $UTF8_SEM_BOM)

    $config = if (Test-Path $ArqConfig) { [IO.File]::ReadAllText($ArqConfig) } else { "" }
    if ($config -notmatch "(?m)^\s*\[default\]") {
        $config = "[default]`r`nregion = $REGIAO`r`noutput = json`r`n`r`n" + $config
        [IO.File]::WriteAllText($ArqConfig, $config, $UTF8_SEM_BOM)
    }
}

function Testar-Credenciais {
    for ($i = 1; $i -le 3; $i++) {
        $r = Exec $EXE_aws @("sts", "get-caller-identity", "--output", "json")
        if ($r.Codigo -eq 0) { return ($r.Saida | ConvertFrom-Json) }
        if ($r.Saida -match "RequestTimeTooSkewed|Signature expired") {
            Falhar "o relógio do Windows está errado. Acerte data e hora (Configurações > Hora e idioma > Sincronizar agora) e rode de novo."
        }
        Start-Sleep -Seconds 3   # credencial recém-criada leva alguns segundos para valer
    }
    return $null
}

function Pedir-Credenciais([string]$motivo) {
    Write-Host ""
    if ($motivo) { Aviso $motivo }
    Write-Host "    No Learner Lab: Start Lab, espere a bolinha ficar verde, AWS Details > AWS CLI: Show." -ForegroundColor White
    Write-Host "    Copie o bloco inteiro ([default] ... aws_session_token=...)." -ForegroundColor White
    for ($vez = 1; $vez -le 10; $vez++) {
        $linha = Read-Host "    Com o bloco copiado, aperte Enter (ou cole aqui no console)"
        if ($linha -and $linha.Trim()) {
            # Colou no console: cada linha chega numa leitura. Junta até ter as três chaves.
            $texto = $linha
            for ($n = 0; $n -lt 8 -and -not (Ler-Bloco $texto); $n++) { $texto += "`n" + (Read-Host) }
        } else {
            $texto = ""
            try { $texto = Get-Clipboard -Raw } catch { }
        }
        Limpar-Entrada
        $c = Ler-Bloco $texto
        if ($c) { return $c }
        Aviso "não achei aws_access_key_id, aws_secret_access_key e aws_session_token. Copie de novo."
    }
    Falhar "não recebi as credenciais da AWS."
}

# Testa um bloco sem gravar: credencial velha na área de transferência não
# pode apagar a boa que já está no arquivo.
function Testar-Bloco($c) {
    $env:AWS_ACCESS_KEY_ID = $c.aws_access_key_id
    $env:AWS_SECRET_ACCESS_KEY = $c.aws_secret_access_key
    $env:AWS_SESSION_TOKEN = $c.aws_session_token
    try { return Testar-Credenciais }
    finally { Remove-Item Env:AWS_ACCESS_KEY_ID, Env:AWS_SECRET_ACCESS_KEY, Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
}

function Garantir-Credenciais([bool]$aceitarAtuais) {
    $daArea = $null
    try { $daArea = Ler-Bloco (Get-Clipboard -Raw) } catch { }
    if ($daArea) {
        Info "credenciais encontradas na área de transferência"
        $id = Testar-Bloco $daArea
        if ($id) { Gravar-Credenciais $daArea; return $id }
        Info "(as da área de transferência já não valem)"
    }
    if ($aceitarAtuais) {
        $id = Testar-Credenciais
        if ($id) { Info "uso as credenciais que já estavam em $ArqCredenciais"; return $id }
    }
    $motivo = "preciso de credenciais válidas do Learner Lab."
    for ($tentativa = 1; $tentativa -le 5; $tentativa++) {
        $c = Pedir-Credenciais $motivo
        $id = Testar-Bloco $c
        if ($id) { Gravar-Credenciais $c; return $id }
        $motivo = "a AWS recusou essas credenciais. A sessão do lab pode ter acabado: clique em Start Lab e copie o bloco novo."
    }
    Falhar "não consegui credenciais válidas da AWS."
}

$identidade = Garantir-Credenciais $true
$CONTA = $identidade.Account
Ok "conta $CONTA ($($identidade.Arn))"
if ($identidade.Arn -notmatch "voclabs|LabRole") {
    Aviso "isto não parece o AWS Academy Learner Lab. O projeto usa a LabRole (iam_mode = learner_lab)."
}

# ============================================================================
# 4. Segredos e variáveis
# ============================================================================

Etapa "Segredos do grupo e variáveis"

$ArqSegredos = Join-Path $InfraDir "segredos.auto.tfvars"
$ArqCofre = Join-Path $InfraDir "segredos\segredos.tfvars.enc"
if (Test-Path $ArqSegredos) {
    Ok "segredos.auto.tfvars já existe (não mexi)"
} elseif (-not (Test-Path $ArqCofre)) {
    Aviso "sem cofre de segredos: sobe sem a chave da IA (insights por regras) e sem o usuário de teste."
} else {
    Limpar-Entrada
    $senhaInformada = if ($SenhaCofre) { $SenhaCofre } else { $env:DG_SEGREDOS_SENHA }
    $aberto = $false
    for ($tentativa = 1; $tentativa -le 3 -and -not $aberto; $tentativa++) {
        try {
            if ($senhaInformada) { & (Join-Path $InfraDir "scripts\segredos.ps1") -Abrir -Senha $senhaInformada }
            else { & (Join-Path $InfraDir "scripts\segredos.ps1") -Abrir }
            $aberto = $true
        } catch {
            Aviso $_.Exception.Message
            $senhaInformada = ""
        }
    }
    if (-not $aberto) {
        if (-not (Perguntar-SimNao "Seguir sem os segredos (sem IA nos insights e sem usuário de teste)?" $false)) {
            Falhar "cofre não aberto. Peça a senha do cofre ao grupo e rode de novo."
        }
    }
}

$ArqTfvars = Join-Path $InfraDir "terraform.tfvars"
if (-not (Test-Path $ArqTfvars)) {
    Copy-Item (Join-Path $InfraDir "terraform.tfvars.example") $ArqTfvars
    Ok "terraform.tfvars criado a partir do exemplo"
} else {
    Ok "terraform.tfvars já existe (não mexi)"
}

# ============================================================================
# 5. State remoto no S3 da conta
# ============================================================================

Etapa "State do Terraform (S3 da conta $CONTA)"

$BUCKET_STATE = "driveguard-tfstate-$CONTA"
$r = Exec $EXE_aws @("s3api", "head-bucket", "--bucket", $BUCKET_STATE)
if ($r.Codigo -ne 0) {
    Info "criando o bucket $BUCKET_STATE"
    $r = Exec $EXE_aws @("s3api", "create-bucket", "--bucket", $BUCKET_STATE, "--region", $REGIAO)
    if ($r.Codigo -ne 0 -and $r.Saida -notmatch "BucketAlreadyOwnedByYou") { Falhar "não consegui criar o bucket do state: $($r.Saida)" }
    Exec $EXE_aws @("s3api", "wait", "bucket-exists", "--bucket", $BUCKET_STATE) | Out-Null
}
# Versionado (dá para voltar um state estragado) e fechado ao público. Idempotente.
Exec $EXE_aws @("s3api", "put-bucket-versioning", "--bucket", $BUCKET_STATE, "--versioning-configuration", "Status=Enabled") | Out-Null
Exec $EXE_aws @("s3api", "put-public-access-block", "--bucket", $BUCKET_STATE, "--public-access-block-configuration",
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true") | Out-Null

$ArqBackend = Join-Path $InfraDir "backend.tf"
$conteudoBackend = @"
# Gerado pelo scripts/subir.ps1 (não vai para o git). State no S3 da conta do
# Learner Lab, com trava por arquivo (use_lockfile), sem DynamoDB.
terraform {
  backend "s3" {
    bucket       = "$BUCKET_STATE"
    key          = "$CHAVE_STATE"
    region       = "$REGIAO"
    encrypt      = true
    use_lockfile = true
  }
}
"@
$anteriorBackend = if (Test-Path $ArqBackend) { [IO.File]::ReadAllText($ArqBackend) } else { "" }
if ($anteriorBackend -ne $conteudoBackend.Replace("`r`n", "`n")) {
    [IO.File]::WriteAllText($ArqBackend, $conteudoBackend.Replace("`r`n", "`n"), $UTF8_SEM_BOM)
}

# Decide se o state local (de quem subia antes sem o S3) vai para o bucket.
$StateLocal = Join-Path $InfraDir "terraform.tfstate"
$remoto = $null
$r = Exec $EXE_aws @("s3", "cp", "s3://$BUCKET_STATE/$CHAVE_STATE", "-", "--only-show-errors")
if ($r.Codigo -eq 0 -and $r.Saida.Trim().StartsWith("{")) { try { $remoto = $r.Saida | ConvertFrom-Json } catch { } }
$local = $null
if (Test-Path $StateLocal) {
    try { $local = [IO.File]::ReadAllText($StateLocal) | ConvertFrom-Json } catch { }
}
$localDestaConta = $local -and @($local.resources).Count -gt 0 -and ([IO.File]::ReadAllText($StateLocal) -match ":${CONTA}:")
$migrar = $false
if ($localDestaConta) {
    if (-not $remoto -or @($remoto.resources).Count -eq 0) { $migrar = $true }
    elseif ($remoto.lineage -eq $local.lineage -and [int]$local.serial -gt [int]$remoto.serial) { $migrar = $true }
    else { Aviso "este computador tinha um state local, mas o do S3 é o que vale (outro colega subiu depois)." }
}

$argsInit = @("init", "-input=false", "-no-color")
if ($migrar) {
    Info "levando o state local para o S3 (primeira vez neste computador)"
    # Sem o cache do backend antigo, o Terraform enxerga o state local como origem.
    Remove-Item -Force (Join-Path $InfraDir ".terraform\terraform.tfstate") -ErrorAction SilentlyContinue
    $argsInit += @("-migrate-state", "-force-copy")
} else {
    $argsInit += "-reconfigure"
}
$init = $null
for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
    $init = Exec $EXE_terraform $argsInit
    if ($init.Codigo -eq 0) { break }
    Aviso "terraform init falhou (tentativa $tentativa de 3)"
    Start-Sleep -Seconds (10 * $tentativa)
}
if ($init.Codigo -ne 0) { Write-Host $init.Saida; Falhar "terraform init não funcionou." }

# O state local saiu de cena (migrado ou substituído pelo do S3): renomeia
# para ninguém achar que ele ainda vale.
if (Test-Path $StateLocal) {
    $guardado = "$StateLocal.antes-do-s3-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
    Move-Item -Force $StateLocal $guardado
    Info "state local antigo guardado em $(Split-Path -Leaf $guardado)"
}
Ok ("state em s3://$BUCKET_STATE/$CHAVE_STATE" + $(if ($migrar) { " (migrado)" } elseif ($remoto) { " (já existia)" } else { " (novo)" }))

# Monta build/ sempre: um build/ velho (de outro commit, ou com outro bundle de
# CAs) daria pacotes diferentes dos colegas e Lambdas trocando a cada apply.
# Com o código igual, o pacote sai igual e o apply não muda nada.
Etapa "Empacotando as Lambdas"
try { & (Join-Path $InfraDir "scripts\build_lambdas.ps1") -Python $EXE_python | Out-Null }
catch { Falhar "o build das Lambdas falhou: $($_.Exception.Message)" }
Ok "pacotes em build/"

# ============================================================================
# 6a. Desligar (opcional)
# ============================================================================

if ($Desligar) {
    Etapa "Desligar: destruir todo o DriveGuard da conta $CONTA"
    Write-Host "    Isto APAGA banco, buckets, EC2, API e dados. Não tem volta." -ForegroundColor Red
    $confirma = Read-Host "    Digite DESLIGAR para confirmar"
    if ($confirma -cne "DESLIGAR") { Info "cancelado: nada foi apagado."; try { Stop-Transcript | Out-Null } catch { }; exit 0 }
    & (Join-Path $InfraDir "scripts\desligar.ps1") -Regiao $REGIAO
    $codigo = $LASTEXITCODE
    try { Stop-Transcript | Out-Null } catch { }
    exit $codigo
}

# ============================================================================
# 6b. Apply
# ============================================================================

Etapa "terraform apply (12 a 25 minutos na primeira vez; quase tudo é esperar o RDS)"

$argsApply = @("apply", "-input=false", "-auto-approve", "-no-color")
if ($SoInfra) { $argsApply += @("-var", "deploy_aplicacao=false") }

$sucesso = $false
for ($tentativa = 1; $tentativa -le 3 -and -not $sucesso; $tentativa++) {
    if ($tentativa -gt 1) {
        Etapa "terraform apply: tentativa $tentativa de 3 (continua de onde parou)"
        if (-not (Testar-Credenciais)) { Garantir-Credenciais $false | Out-Null }
    }
    $apply = Exec $EXE_terraform $argsApply -AoVivo
    if ($apply.Codigo -eq 0) { $sucesso = $true; break }

    if ($apply.Saida -match "Error acquiring the state lock") {
        $id = [regex]::Match($apply.Saida, "ID:\s+([0-9a-fA-F-]{8,})").Groups[1].Value
        Aviso "o state está travado. Ou alguém do grupo está rodando agora, ou uma execução anterior caiu no meio."
        if ($id -and (Perguntar-SimNao "Ninguém mais está rodando? Destravar (ID $id)?" $false)) {
            Exec $EXE_terraform @("force-unlock", "-force", $id) | Out-Null
        } else {
            Falhar "state travado. Espere o colega terminar e rode de novo."
        }
    } elseif ($apply.Saida -match "ExpiredToken|InvalidClientTokenId|security token included in the request is (expired|invalid)|voc-cancel-cred") {
        Garantir-Credenciais $false | Out-Null
    } else {
        Aviso "o apply falhou; erros passageiros da AWS são comuns aqui. Tento de novo em 30 s."
        Start-Sleep -Seconds 30
    }
}
if (-not $sucesso) { Falhar "o terraform apply falhou 3 vezes. O erro está logo acima e no registro." }

# ============================================================================
# 7. Pronto
# ============================================================================

# Lab que ficou desligado deixa um buraco nos dados: com o simulador ligado,
# ele preenche do último dado de cada câmera até agora (assíncrono).
$regraSimulador = "driveguard-dev-simulador"
if ((Exec $EXE_aws @("events", "describe-rule", "--name", $regraSimulador, "--query", "State", "--output", "text")).Saida.Trim() -eq "ENABLED") {
    $evento = Join-Path $env:TEMP "driveguard-preencher.json"
    [IO.File]::WriteAllText($evento, '{"preencher": true}')
    $r = Exec $EXE_aws @("lambda", "invoke", "--function-name", $regraSimulador, "--invocation-type", "Event", "--payload", "fileb://$evento", (Join-Path $env:TEMP "driveguard-preencher-saida.json"))
    if ($r.Codigo -eq 0) { Info "simulador preenchendo os dados que faltam até agora (alguns minutos)" }
}

Etapa "Conferindo o dashboard"
$url = (Exec $EXE_terraform @("output", "-raw", "dashboard_url")).Saida.Trim()
$api = (Exec $EXE_terraform @("output", "-raw", "backend_api_url")).Saida.Trim()
$noAr = $false
if ($url -match "^https?://") {
    Info "a EC2 copia o site do S3 a cada minuto; espero até 8 minutos"
    $limite = (Get-Date).AddMinutes(8)
    while ((Get-Date) -lt $limite -and -not $noAr) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
            if ($resp.StatusCode -eq 200 -and $resp.Content -match 'id="root"') { $noAr = $true; break }
        } catch { }
        Start-Sleep -Seconds 15
    }
}

$email = ""; $senha = ""
if (Test-Path $ArqSegredos) {
    $txt = [IO.File]::ReadAllText($ArqSegredos)
    $bloco = [regex]::Match($txt, "(?s)usuario_teste\s*=\s*\{(.*?)\}").Groups[1].Value
    $email = [regex]::Match($bloco, 'email\s*=\s*"([^"]+)"').Groups[1].Value
    $senha = [regex]::Match($bloco, 'senha\s*=\s*"([^"]+)"').Groups[1].Value
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host "   DriveGuard no ar" -ForegroundColor Green
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host "   Dashboard:  $url"
Write-Host "   API:        $api"
if ($email) { Write-Host "   Login:      $email   senha: $senha" }
if (-not $noAr) { Write-Host "   (o dashboard ainda não respondeu; espere 1 ou 2 minutos e recarregue)" -ForegroundColor Yellow }
Write-Host ""
Write-Host "   O lab desliga RDS e EC2 quando a sessão acaba. Para voltar: Start Lab"
Write-Host "   e rode o subir.cmd de novo (credenciais novas, o resto é reaproveitado)."
Write-Host "   Para apagar tudo da conta: desligar.cmd"
Write-Host "   Registro: $ArquivoLog"
Write-Host ""

if ($url -match "^https?://" -and -not $NaoAbrirNavegador) { Start-Process $url }
try { Stop-Transcript | Out-Null } catch { }
exit 0
