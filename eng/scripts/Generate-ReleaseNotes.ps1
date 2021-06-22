[CmdletBinding()]
param (
  [string]$releasePeriod,
  [DateTime]$releaseStartDate,
  [string]$repoLanguage,
  [string]$commonScriptPath,
  [string]$releaseDirectory = (Resolve-Path "$PSScriptRoot\..\..\_data\releases"),
  [string]$github_pat = $env:GITHUB_PAT
)

. (Join-Path $commonScriptPath ChangeLog-Operations.ps1)
. (Join-Path $commonScriptPath SemVer.ps1)
. (Join-Path $PSScriptRoot PackageList-Helpers.ps1)
. (Join-Path $PSScriptRoot PackageVersion-Helpers.ps1)

function GetReleaseNotesData ($packageName, $packageVersion, $packageMetadata)
{
  $sourceUrl = GetLinkTemplateValue $langLinkTemplates "source_url_template" $packageName $packageVersion $packageMetadata.RepoPath
  if (!$sourceUrl.EndsWith("/")) { $sourceUrl += "/" }
  $changelogBlobLink = "${sourceUrl}CHANGELOG.md"
  $changelogRawLink = $changelogBlobLink -replace "https://github.com/(.*)/(tree|blob)", "https://raw.githubusercontent.com/`$1"
  try
  {
    $changelogContent = Invoke-RestMethod -Method GET -Uri $changelogRawLink -MaximumRetryCount 2
  }
  catch
  {
    # Skip if the changelog Url is invalid
    LogWarning "Failed to get content from ${changelogRawLink}"
    LogWarning "ReleaseNotes will not be collected for $packageName : $packageVersion. Please add entry manually."
    return $null
  }

  $changeLogEntries = Get-ChangeLogEntriesFromContent -changeLogContent $changelogContent
  $updatedVersionEntry = $changeLogEntries[$packageVersion]

  if (!$updatedVersionEntry)
  {
    # Skip if the changelog Url is invalid
    LogWarning "Failed to get find matching change log entry from from ${changelogRawLink}"
    LogWarning "ReleaseNotes will not be collected for $packageName : $packageVersion. Please add entry manually."
    return $null
  }

  $packageSemVer = [AzureEngSemanticVersion]::ParseVersionString($packageVersion)
  $releaseEntryContent = @()

  if ($updatedVersionEntry.Sections.Keys.Count -gt 0)
  {
    $sectionsToPull = @("Features Added","Breaking Changes","Key Bugs Fixed")
    foreach ($key in $updatedVersionEntry.Sections.Keys)
    {
      if ($key -in $sectionsToPull)
      {
        $releaseEntryContent += "####${key}"
        $releaseEntryContent += BumpUpMDHeaders -content $updatedVersionEntry.Sections[$key]
      }
    }
  }

  if (($releaseEntryContent.Count -eq 0) -and $updatedVersionEntry.ReleaseContent)
  {
      # Bumping all MD headers by one level to fit in with the release template structure.
      $releaseEntryContent += BumpUpMDHeaders -content $updatedVersionEntry.ReleaseContent
  }

  $entry = [ordered]@{
    Name = $packageName
    Version = $packageVersion
    DisplayName = $packageMetadata.DisplayName
    ServiceName = $packageMetadata.ServiceName
    VersionType = $packageSemVer.VersionType
    Hidden = $false
    ChangelogUrl = $changelogBlobLink
    ChangelogContent = ($releaseEntryContent | % { $_.Trim() } | Out-String).Trim()
  }

  if (!$entry.DisplayName)
  {
    $entry.DisplayName = $entry.Name
  }

  if ($packageMetadata.PSObject.Members.Name -contains "GroupId")
  {
    $entry.Add("GroupId", $packageMetadata.GroupId)
  }
  return $entry
}
function BumpUpMDHeaders($content)
{
    $result = @()
    foreach ($line in $content)
    {
        if ($line.StartsWith("#"))
        {
            $line = "#${line}"
        }
        $result += $line
    }
    return $result
}

$pathToRelatedYaml = (Join-Path $ReleaseDirectory $releasePeriod "${repoLanguage}.yml")
LogDebug "Related Yaml File Path [ $pathToRelatedYaml ]"

if (Test-Path $pathToRelatedYaml)
{
  $yamlContent = Get-Content $pathToRelatedYaml -Raw
}
else
{
  $yamlContent = "entries:"
}

# Install Powershell Yaml
$ProgressPreference = "SilentlyContinue"
$ToolsFeed = "https://pkgs.dev.azure.com/azure-sdk/public/_packaging/azure-sdk-tools/nuget/v2"
Register-PSRepository -Name azure-sdk-tools-feed -SourceLocation $ToolsFeed -PublishLocation $ToolsFeed -InstallationPolicy Trusted -ErrorAction SilentlyContinue
Install-Module -Repository azure-sdk-tools-feed powershell-yaml

$existingYamlContent = ConvertFrom-Yaml $yamlContent -Ordered
if (!$existingYamlContent.entries)
{
  $existingYamlContent.entries = New-Object "System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]"
}

$langLinkTemplates = GetLinkTemplates $repoLanguage
$updatedPackageSet = GetPackageVersions $repoLanguage $releaseStartDate
$languageMetadata = Get-PackageLookupForLanguage $repoLanguage

foreach ($packageName in $updatedPackageSet.Keys)
{
  Write-Verbose "Checking release notes for $packageName"
  $pkgKey = $packageName
  if ($repoLanguage -eq "java") { $pkgKey = "com.azure:${pkgKey}" }
  if ($repoLanguage -eq "android") { $pkgKey = "com.azure.android:${pkgKey}" }
  $pkgMetadata = $languageMetadata[$pkgKey]

  if (!$pkgMetadata) {
    Write-Host "Skipped package '$pkgKey' because it doesn't contain metadata in the csv file."
    continue
  }

  if ($pkgMetadata.New -ne "true" -or $pkgMetadata.Hide -eq "true") {
    Write-Host "Skipped package '$pkgKey' because it is not new ($($pkgMetadata.Hide)) or it is marked as hidden ($($pkgMetadata.Hide))"
    continue
  }

  foreach ($packageVersion in $updatedPackageSet[$packageName].Versions)
  {
    $presentKey = $existingYamlContent.entries.Where({ ($_.name -eq $packageName) -and ($_.version -eq $packageVersion.RawVersion) })
    if ($presentKey.Count -eq 0)
    {
      $entry = GetReleaseNotesData $packageName $packageVersion.RawVersion $pkgMetadata
      if ($entry) {
        Write-Host "Added '$pkgKey' to the release note entries"
        $existingYamlContent.entries += $entry
      }
    }
  }
}

if ($existingYamlContent.entries.Count -gt 0)
{
  Write-Host "Writing release notes for $repoLanguage to $pathToRelatedYaml"

  $yamlDirectory = Split-Path $pathToRelatedYaml -Parent
  if (!(Test-Path $yamlDirectory)) {
    New-Item -Type Directory $yamlDirectory > $null
  }
  Set-Content -Path $pathToRelatedYaml -Value (ConvertTo-Yaml $existingYamlContent)
}
else
{
  Write-Host "No release notes for $repoLanguage so not writing $pathToRelatedYaml"
}
