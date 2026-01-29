# Backup-AzureResourceGroup.ps1
# Backs up an Azure Resource Group to local Bicep/JSON files for disaster recovery.
# Running the generated restore script will recreate/update resources in the SAME resource group.

param(
    [Parameter(Mandatory=$false)] [string]$SourceSubscription = "",
    [Parameter(Mandatory=$false)] [string]$SourceResourceGroup = "rg-your-project-dev",
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\backup-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Azure Resource Group Backup Tool" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Source: $SourceResourceGroup" -ForegroundColor White
Write-Host "Output: $OutputPath" -ForegroundColor White
Write-Host ""

$SourceSubscription = $SourceSubscription.Trim()
$SourceResourceGroup = $SourceResourceGroup.Trim()

# 1. HOUSEKEEPING
if (Test-Path -Path $OutputPath) {
    Write-Host "Output folder already exists, will overwrite..." -ForegroundColor Yellow
    Remove-Item -Path $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$configPath = Join-Path $OutputPath "configs"
New-Item -ItemType Directory -Path $configPath -Force | Out-Null

# 2. ACCESS CHECKS
Write-Host "Verifying permissions..." -ForegroundColor Yellow
try {
    az account set --subscription "$SourceSubscription" 2>$null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Host "ERROR: Cannot access Subscription '$SourceSubscription'." -ForegroundColor Red
    exit 1
}

$rgInfo = az group show --name $SourceResourceGroup --subscription "$SourceSubscription" 2>$null | ConvertFrom-Json
if (!$rgInfo) {
    Write-Host "ERROR: Resource Group '$SourceResourceGroup' not found." -ForegroundColor Red
    exit 1
}

# 3. DISCOVERY
Write-Host "Discovering resources..." -ForegroundColor Yellow
$resources = az resource list --resource-group $SourceResourceGroup --output json | ConvertFrom-Json
$resources = $resources | Sort-Object -Property type, name

if (!$resources -or $resources.Count -eq 0) {
    Write-Host "ERROR: Resource Group is empty." -ForegroundColor Red
    exit 1
}
Write-Host "  Found $($resources.Count) resources" -ForegroundColor Green

# 4. CAPTURE FUNCTION APP SETTINGS (WITH ACTUAL VALUES FOR BACKUP)
Write-Host "Capturing Function App settings (full backup)..." -ForegroundColor Yellow
$functionApps = $resources | Where-Object { $_.type -eq "Microsoft.Web/sites" -and $_.kind -match "functionapp" }
$functionAppConfigs = @{}
$allAppSettings = @{}

foreach ($app in $functionApps) {
    $settings = az functionapp config appsettings list --name $app.name --resource-group $SourceResourceGroup --output json | ConvertFrom-Json
    $functionAppConfigs[$app.name] = @{ Settings = $settings; Kind = $app.kind }
    
    # Store full settings for backup (including secrets)
    $settingsHash = @{}
    foreach ($s in $settings) {
        $settingsHash[$s.name] = $s.value
    }
    $allAppSettings[$app.name] = $settingsHash
}

# Save full app settings to a sensitive backup file
$appSettingsBackupFile = Join-Path $configPath "appsettings-backup.json"
$allAppSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $appSettingsBackupFile
Write-Host "  Saved app settings to configs/appsettings-backup.json" -ForegroundColor Green

# 5. EXPORT TO JSON
Write-Host "Exporting ARM template..." -ForegroundColor Yellow
$armTemplateFile = Join-Path $OutputPath "template.json"
az group export --name $SourceResourceGroup --output json > $armTemplateFile 2>$null

if (!(Test-Path -Path $armTemplateFile)) {
    Write-Host "CRITICAL ERROR: Export failed." -ForegroundColor Red
    exit 1
}

# 6. DEEP CLEANING
Write-Host "Cleaning template..." -ForegroundColor Yellow
$jsonContent = Get-Content -Path $armTemplateFile -Raw | ConvertFrom-Json
$initialCount = $jsonContent.resources.Count

$cleanedResources = @()

foreach ($r in $jsonContent.resources) {
    # Remove unwanted resource types
    if ($r.type -match "Microsoft.OperationalInsights/workspaces/tables") { continue }
    if ($r.type -match "Microsoft.OperationalInsights/workspaces/savedSearches") { continue }
    if ($r.type -match "Microsoft.OperationalInsights/workspaces/dataSources") { continue }
    if ($r.type -match "microsoft.insights/components/ProactiveDetectionConfigs") { continue }
    if ($r.type -match "microsoft.insights/actiongroups") { continue }
    if ($r.type -match "microsoft.insights/metricalerts") { continue }
    if ($r.type -match "microsoft.insights/webtests") { continue }
    if ($r.type -match "microsoft.alertsmanagement") { continue }
    if ($r.type -match "Microsoft.Web/sites/deployments") { continue }
    if ($r.type -match "Microsoft.Web/sites/functions") { continue }
    if ($r.type -match "Microsoft.Web/sites/basicPublishingCredentialsPolicies") { continue }
    if ($r.type -match "Microsoft.Web/sites/hostNameBindings") { continue }
    if ($r.type -match "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules") { continue }
    
    # Strip Read-Only Properties
    if ($r.properties -and $r.properties.provisioningState) { $r.properties.PSObject.Properties.Remove("provisioningState") }
    
    $typeSegments = $r.type -split "/"
    if ($typeSegments.Count -gt 2) {
        if ($r.PSObject.Properties.Match("location").Count -gt 0) { $r.PSObject.Properties.Remove("location") }
        if ($r.PSObject.Properties.Match("tags").Count -gt 0) { $r.PSObject.Properties.Remove("tags") }
        if ($r.PSObject.Properties.Match("sku").Count -gt 0) { $r.PSObject.Properties.Remove("sku") }
    }

    if ($r.type -match "Microsoft.ServiceBus") {
        if ($r.properties -and $r.properties.status) { $r.properties.PSObject.Properties.Remove("status") }
    }
    
    if ($r.type -eq "Microsoft.Storage/storageAccounts") {
        if ($r.sku -and $r.sku.tier) { $r.sku.PSObject.Properties.Remove("tier") }
    }

    if ($r.type -eq "Microsoft.Web/serverfarms") {
        if ($r.sku -and $r.sku.tier) { $r.sku.PSObject.Properties.Remove("tier") }
    }

    $cleanedResources += $r
}

$jsonContent.resources = $cleanedResources
Write-Host "  Pruned from $initialCount to $($cleanedResources.Count) resources." -ForegroundColor Green

$cleanJsonFile = Join-Path $OutputPath "template.clean.json"
$jsonContent | ConvertTo-Json -Depth 100 | Set-Content -Path $cleanJsonFile

# 7. DECOMPILE TO BICEP
Write-Host "Decompiling to Bicep..." -ForegroundColor Yellow
$bicepFile = Join-Path $OutputPath "main.bicep"
if (Test-Path $bicepFile) { Remove-Item $bicepFile }

az bicep decompile --file $cleanJsonFile --force 2>$null

$generatedBicep = Join-Path $OutputPath "template.clean.bicep"
if (Test-Path $generatedBicep) { Rename-Item -Path $generatedBicep -NewName "main.bicep" -Force }

if (!(Test-Path $bicepFile)) {
    Write-Host "CRITICAL ERROR: Bicep creation failed." -ForegroundColor Red
    exit 1
}

# 8. SANITIZE DEPENDSON
Write-Host "Sanitizing Bicep..." -ForegroundColor Yellow
$bicepLines = Get-Content -Path $bicepFile
$cleanBicepLines = @()
$insideDependsOn = $false

foreach ($line in $bicepLines) {
    if ($line -match 'dependsOn:\s*\[') { $insideDependsOn = $true; $cleanBicepLines += $line; continue }
    if ($insideDependsOn -and $line -match '\]') { $insideDependsOn = $false; $cleanBicepLines += $line; continue }
    if ($insideDependsOn) {
        if ($line -match "'") { continue }
    }
    $cleanBicepLines += $line
}
$bicepContent = $cleanBicepLines -join "`n"
Set-Content -Path $bicepFile -Value $bicepContent

# 9. GENERATE PARAMETERS (exact names, no transformation)
Write-Host "Generating parameters file..." -ForegroundColor Yellow
$paramRegex = [regex]::Matches($bicepContent, 'param\s+([a-zA-Z0-9_]+)\s+string')
$backupParameters = @{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{}
}

foreach ($match in $paramRegex) {
    $pName = $match.Groups[1].Value
    
    # Find matching resource by parameter name
    $matchRes = $resources | Where-Object { $pName -match ($_.name -replace "-","_") } | Select-Object -First 1
    if ($matchRes) {
        # Use exact original name (no transformation)
        $backupParameters.parameters[$pName] = @{ value = $matchRes.name }
    } else {
        # Try to extract value from parameter name pattern
        if ($pName -match "workspace") {
            $ws = $resources | Where-Object { $_.type -eq "Microsoft.OperationalInsights/workspaces" } | Select-Object -First 1
            if ($ws) {
                $backupParameters.parameters[$pName] = @{ value = $ws.id }
            } else {
                $backupParameters.parameters[$pName] = @{ value = "REVIEW_REQUIRED" }
            }
        } elseif ($pName -match "user") {
            $backupParameters.parameters[$pName] = @{ value = "Administrator" }
        } else {
            $backupParameters.parameters[$pName] = @{ value = "REVIEW_REQUIRED" }
        }
    }
}

$paramsFile = Join-Path $OutputPath "parameters.json"
$backupParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile

# 10. GENERATE RESTORE SCRIPT
Write-Host "Generating restore script..." -ForegroundColor Yellow
$restoreScript = @"
# Restore script for $SourceResourceGroup
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# WARNING: This will UPDATE resources in the SAME resource group. Review before running.

param([switch]`$Validate, [switch]`$WhatIf)

`$ResourceGroup = "$SourceResourceGroup"
`$Location = "$($rgInfo.location)"
`$TemplateFile = "main.bicep"
`$ParametersFile = "parameters.json"

Write-Host "Restoring to `$ResourceGroup..." -ForegroundColor Cyan
az account set --subscription "$SourceSubscription"

# Ensure resource group exists
az group create --name "`$ResourceGroup" --location "`$Location" 2>`$null

Write-Host "Validating Bicep syntax..." -ForegroundColor Yellow
az bicep build --file "`$TemplateFile" --stdout 2>&1 | Out-Null
if (`$LASTEXITCODE -ne 0) {
    Write-Host "Bicep validation failed!" -ForegroundColor Red
    az bicep build --file "`$TemplateFile"
    exit 1
}
Write-Host "Validation passed!" -ForegroundColor Green

if (`$Validate) { exit 0 }

if (`$WhatIf) {
    Write-Host "Running What-If analysis..." -ForegroundColor Yellow
    az deployment group what-if --resource-group "`$ResourceGroup" --template-file "`$TemplateFile" --parameters "@`$ParametersFile"
    exit 0
}

Write-Host "Deploying infrastructure..." -ForegroundColor Yellow
az deployment group create --resource-group "`$ResourceGroup" --template-file "`$TemplateFile" --parameters "@`$ParametersFile"

if (`$LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Infrastructure restored!" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT: To restore Function App settings, run:" -ForegroundColor Yellow
    Write-Host "  .\restore-appsettings.ps1" -ForegroundColor White
}
"@
Set-Content -Path (Join-Path $OutputPath "restore.ps1") -Value $restoreScript

# 11. GENERATE APP SETTINGS RESTORE SCRIPT
$appSettingsRestoreScript = @"
# Restore Function App settings from backup
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# WARNING: This will OVERWRITE all app settings. Review configs/appsettings-backup.json first.

param([switch]`$WhatIf)

`$ResourceGroup = "$SourceResourceGroup"
`$BackupFile = ".\configs\appsettings-backup.json"

if (!(Test-Path `$BackupFile)) {
    Write-Host "ERROR: Backup file not found: `$BackupFile" -ForegroundColor Red
    exit 1
}

az account set --subscription "$SourceSubscription"

`$allSettings = Get-Content `$BackupFile -Raw | ConvertFrom-Json

foreach (`$appName in `$allSettings.PSObject.Properties.Name) {
    Write-Host "Restoring settings for `$appName..." -ForegroundColor Yellow
    
    `$settings = `$allSettings.`$appName
    `$settingsList = @()
    
    foreach (`$key in `$settings.PSObject.Properties.Name) {
        `$value = `$settings.`$key
        `$settingsList += "`$key=`$value"
    }
    
    if (`$WhatIf) {
        Write-Host "  Would restore `$(`$settingsList.Count) settings" -ForegroundColor Cyan
        continue
    }
    
    # Apply settings
    az functionapp config appsettings set ``
        --name `$appName ``
        --resource-group `$ResourceGroup ``
        --settings `$settingsList ``
        --output none
    
    if (`$LASTEXITCODE -eq 0) {
        Write-Host "  Restored `$(`$settingsList.Count) settings" -ForegroundColor Green
    } else {
        Write-Host "  Failed to restore settings!" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "App settings restore complete!" -ForegroundColor Green
"@
Set-Content -Path (Join-Path $OutputPath "restore-appsettings.ps1") -Value $appSettingsRestoreScript

# 12. GENERATE BACKUP MANIFEST
$manifest = @{
    BackupDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Subscription = $SourceSubscription
    ResourceGroup = $SourceResourceGroup
    Location = $rgInfo.location
    ResourceCount = $resources.Count
    FunctionApps = $functionApps | ForEach-Object { $_.name }
    Files = @(
        "main.bicep"
        "parameters.json"
        "template.json"
        "template.clean.json"
        "restore.ps1"
        "restore-appsettings.ps1"
        "configs/appsettings-backup.json"
    )
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputPath "backup-manifest.json")

# DONE
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "BACKUP COMPLETE!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Backup location: $OutputPath" -ForegroundColor White
Write-Host ""
Write-Host "To restore infrastructure:" -ForegroundColor Yellow
Write-Host "  cd $OutputPath" -ForegroundColor White
Write-Host "  .\restore.ps1 -WhatIf    # Preview changes" -ForegroundColor White
Write-Host "  .\restore.ps1            # Apply changes" -ForegroundColor White
Write-Host ""
Write-Host "To restore app settings:" -ForegroundColor Yellow
Write-Host "  .\restore-appsettings.ps1 -WhatIf    # Preview" -ForegroundColor White
Write-Host "  .\restore-appsettings.ps1            # Apply" -ForegroundColor White
Write-Host ""
Write-Host "WARNING: configs/appsettings-backup.json contains SECRETS." -ForegroundColor Red
Write-Host "         Store this backup securely and do not commit to source control." -ForegroundColor Red
