<#
.SYNOPSIS
    Apaga TODAS as versões e marcadores de exclusão de um bucket S3.

.DESCRIPTION
    Chamado pelo provisioner de destroy em modules/storage. Os buckets são
    versionados, e `aws s3 rm --recursive` só remove a versão corrente: as
    versões antigas e os delete markers ficam, e a Cloud Control recusa apagar
    o bucket. Este script lista e remove tudo em lotes de até 1000 objetos.

.EXAMPLE
    ./scripts/esvaziar_bucket.ps1 meu-bucket us-east-1
#>

param(
    [Parameter(Mandatory = $true)][string]$Bucket,
    [string]$Regiao = "us-east-1"
)

$total = 0
do {
    $json = aws s3api list-object-versions --bucket $Bucket --region $Regiao `
        --max-items 1000 --output json 2>$null | ConvertFrom-Json

    $objetos = @()
    if ($json.Versions)      { $objetos += $json.Versions      | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } } }
    if ($json.DeleteMarkers) { $objetos += $json.DeleteMarkers | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } } }

    if ($objetos.Count -gt 0) {
        $arquivo = New-TemporaryFile
        [IO.File]::WriteAllText($arquivo, (@{ Objects = $objetos; Quiet = $true } | ConvertTo-Json -Depth 4 -Compress))
        aws s3api delete-objects --bucket $Bucket --region $Regiao --delete "file://$arquivo" | Out-Null
        Remove-Item $arquivo
        $total += $objetos.Count
    }
} while ($objetos.Count -gt 0)

Write-Host "$Bucket : $total versoes/marcadores removidos"
