function Get-OpenClawBuildKey {
    param(
        [Parameter(Mandatory)] [string] $Identity,
        [string[]] $Files = @(),
        [string] $RootPath = $PSScriptRoot
    )

    $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $inputs = @($Identity)
    foreach ($path in ($Files | Sort-Object)) {
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        $name = if ($file.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $file.FullName.Substring($root.Length) } else { $file.Name }
        $inputs += ($name.Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)
    }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $inputs -Compress))
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 24)
    } finally {
        $algorithm.Dispose()
    }
}

function Get-AcrImageDigest {
    param([string] $Registry, [string] $Image, [switch] $AllowMissing)

    $result = az acr repository show --name $Registry --image $Image --query digest -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = $result -join "`n"
        if ($AllowMissing -and $message -match 'MANIFEST_UNKNOWN|NAME_UNKNOWN|specified (tag|image|repository).*does not exist') { return '' }
        throw "Could not query ${Registry}/${Image}: $message"
    }
    $digest = ($result -join '').Trim()
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Invalid digest returned for ${Registry}/${Image}" }
    return $digest
}

function Invoke-AcrBuildCommand {
    param([string[]] $Arguments)

    & az @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "ACR $($Arguments[1]) failed (exit $LASTEXITCODE)" }
}

function Invoke-AcrCachedBuild {
    param(
        [string] $Registry,
        [string] $Image,
        [string] $Dockerfile,
        [string] $Context,
        [string] $AdditionalTag = '',
        [string[]] $BuildArguments = @(),
        [switch] $Refresh
    )

    $digest = if (-not $Refresh) { Get-AcrImageDigest -Registry $Registry -Image $Image -AllowMissing } else { '' }
    if ($digest) {
        Write-Host "  Reusing $Registry.azurecr.io/$Image" -ForegroundColor Gray
        if ($AdditionalTag) {
            $repository = ($Image -split ':')[0]
            Invoke-AcrBuildCommand -Arguments @('acr', 'import', '--name', $Registry, '--source', "$Registry.azurecr.io/$repository@$digest", '--image', $AdditionalTag, '--force')
        }
        return
    }

    $arguments = @('acr', 'build', '--registry', $Registry, '--image', $Image, '--file', $Dockerfile)
    if ($AdditionalTag) { $arguments += @('--image', $AdditionalTag) }
    if ($Refresh) { $arguments += '--no-cache' }
    foreach ($buildArgument in $BuildArguments) { $arguments += @('--build-arg', $buildArgument) }
    $arguments += $Context
    Invoke-AcrBuildCommand -Arguments $arguments
}

function Invoke-OpenClawToolsBuild {
    param([string] $Registry, [string] $BaseImage, [string] $Dockerfile, [string] $Context, [switch] $Refresh, [int] $Keep = 3)

    $baseDigest = Get-AcrImageDigest -Registry $Registry -Image $BaseImage
    $files = @(Get-ChildItem -LiteralPath $Context -Recurse -File -Force | Select-Object -ExpandProperty FullName)
    $identity = "$baseDigest/$(Split-Path $Dockerfile -Leaf)"
    $key = Get-OpenClawBuildKey -Identity $identity -Files $files -RootPath $Context
    $repository = ($BaseImage -split ':')[0]
    Invoke-AcrCachedBuild -Registry $Registry -Image "${repository}:tools-$key" -Dockerfile $Dockerfile -Context $Context -AdditionalTag "${repository}:latest" -BuildArguments @("BASE_IMAGE=$Registry.azurecr.io/$repository@$baseDigest") -Refresh:$Refresh
    Invoke-AcrBaseImageSweep -Registry $Registry -Repository $repository -KeepTagPrefix 'tools-' -Keep $Keep -ProtectedTags @("tools-$key")
}

function Get-AcrRepositoryTags {
    param([string] $Registry, [string] $Repository)

    $result = az acr repository show-tags --name $Registry --repository $Repository --orderby time_desc --detail -o json
    if ($LASTEXITCODE -ne 0) { throw "Could not list cache tags for $Registry/$Repository" }
    return ($result | ConvertFrom-Json)
}

function Invoke-AcrBaseImageSweep {
    param(
        [string] $Registry,
        [string] $Repository,
        [string] $KeepTagPrefix,
        [ValidateRange(1, 1000)] [int] $Keep = 3,
        [string[]] $ProtectedTags = @()
    )

    $tags = @(Get-AcrRepositoryTags -Registry $Registry -Repository $Repository)
    $matching = @($tags | Where-Object { $_.name.StartsWith($KeepTagPrefix) })
    $protectedNames = @('latest') + $ProtectedTags + @($matching | Select-Object -First $Keep -ExpandProperty name)
    $protectedDigests = @($tags | Where-Object { $protectedNames -contains $_.name -or -not $_.name.StartsWith($KeepTagPrefix) } | Select-Object -ExpandProperty digest)
    $obsolete = @($matching | Select-Object -Skip $Keep | Where-Object { $_.digest -and $protectedDigests -notcontains $_.digest } | Group-Object digest)
    foreach ($group in $obsolete) {
        $tag = $group.Group[0].name
        Write-Host "  Removing unused cache image ${Repository}:$tag" -ForegroundColor Gray
        Invoke-AcrBuildCommand -Arguments @('acr', 'repository', 'delete', '--name', $Registry, '--image', "${Repository}:$tag", '--yes')
    }
}