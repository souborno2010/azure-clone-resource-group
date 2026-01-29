# Export-AzureResourceGroup.ps1
# "THE FINAL REFINED VERSION - v2 (Validation Fix)"
# Fixes: Strips Read-Only properties (Sku, Location on child resources) that cause BCP073 errors.

param(
    [Parameter(Mandatory=$false)] [string]$SourceSubscription = "",
    [Parameter(Mandatory=$false)] [string]$SourceResourceGroup = "rg-your-project-dev",
    [Parameter(Mandatory=$false)] [string]$SourceEnvironment = "dev",
    [Parameter(Mandatory=$false)] [string]$TargetEnvironment = "sit",
    [Parameter(Mandatory=$false)] [string]$OutputPath = ".\exported-bicep"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Azure Export Tool: V2 (Deep Clean)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

$SourceSubscription = $SourceSubscription.Trim()
$SourceResourceGroup = $SourceResourceGroup.Trim()

# 1. HOUSEKEEPING
if (Test-Path -Path $OutputPath) {
    Write-Host "Cleaning output folder..." -ForegroundColor Yellow
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
# Ensure deterministic ordering so parameter-name matching is stable across runs
$resources = $resources | Sort-Object -Property type, name

if (!$resources -or $resources.Count -eq 0) {
    Write-Host "ERROR: Resource Group is empty." -ForegroundColor Red
    exit 1
}
Write-Host "  Found $($resources.Count) resources" -ForegroundColor Green

Write-Host "Capturing App Settings..." -ForegroundColor Yellow
$functionApps = $resources | Where-Object { $_.type -eq "Microsoft.Web/sites" -and $_.kind -match "functionapp" }
$functionAppConfigs = @{}
$manualSettings = @()
$packageSettings = @()
foreach ($app in $functionApps) {
    $settings = az functionapp config appsettings list --name $app.name --resource-group $SourceResourceGroup --output json | ConvertFrom-Json
    $functionAppConfigs[$app.name] = @{ Settings = $settings; Kind = $app.kind }
}

# 4. EXPORT TO JSON
Write-Host "Exporting to ARM JSON..." -ForegroundColor Yellow
$armTemplateFile = Join-Path $OutputPath "template.json"
az group export --name $SourceResourceGroup --output json > $armTemplateFile 2>$null

if (!(Test-Path -Path $armTemplateFile)) {
    Write-Host "CRITICAL ERROR: Export failed." -ForegroundColor Red
    exit 1
}

# 5. DEEP CLEANING (The Fix)
Write-Host "Pruning noise and Read-Only properties..." -ForegroundColor Yellow
$jsonContent = Get-Content -Path $armTemplateFile -Raw | ConvertFrom-Json
$initialCount = $jsonContent.resources.Count

$cleanedResources = @()

foreach ($r in $jsonContent.resources) {
    # 5a. Remove unwanted resource types
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
    if ($r.type -match "Microsoft.Web/sites/hostNameBindings") { continue } # Often causes conflict on import
    if ($r.type -match "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules") { continue }
    # APIM system groups cannot be modified - they are created automatically
    if ($r.type -eq "Microsoft.ApiManagement/service/groups" -and $r.properties.type -eq "system") { continue }
    # APIM group user assignments for system groups also cannot be modified
    if ($r.type -match "Microsoft.ApiManagement/service/groups/users" -and $r.name -match "administrators|developers|guests") { continue }
    # APIM properties is deprecated - use namedValues instead (avoid duplicates)
    if ($r.type -eq "Microsoft.ApiManagement/service/properties") { continue }
    # APIM built-in notifications cannot be modified
    if ($r.type -eq "Microsoft.ApiManagement/service/notifications") { continue }
    # APIM master subscription is built-in and cannot be modified
    if ($r.type -eq "Microsoft.ApiManagement/service/subscriptions" -and $r.name -match "/master$") { continue }
    # Key Vault secrets cannot be exported (sensitive data) - must be created manually
    if ($r.type -eq "Microsoft.KeyVault/vaults/secrets") { continue }
    
    # 5b. Strip Read-Only Properties that cause BCP073/BCP187 validation errors
    
    # Remove Provisioning State (Always read-only)
    if ($r.properties -and $r.properties.provisioningState) { $r.properties.PSObject.Properties.Remove("provisioningState") }
    
    # Child Resources (3 segments or more in type) usually inherit Location and Tags, and SKU is often read-only
    # e.g. Microsoft.Storage/storageAccounts/blobServices
    $typeSegments = $r.type -split "/"
    if ($typeSegments.Count -gt 2) {
        if ($r.PSObject.Properties.Match("location").Count -gt 0) { $r.PSObject.Properties.Remove("location") }
        if ($r.PSObject.Properties.Match("tags").Count -gt 0) { $r.PSObject.Properties.Remove("tags") }
        if ($r.PSObject.Properties.Match("sku").Count -gt 0) { $r.PSObject.Properties.Remove("sku") }
    }

    # Service Bus specific cleanup
    if ($r.type -match "Microsoft.ServiceBus") {
        if ($r.properties -and $r.properties.status) { $r.properties.PSObject.Properties.Remove("status") }
    }
    
    # Storage Account specific cleanup - remove read-only 'tier' from SKU
    if ($r.type -eq "Microsoft.Storage/storageAccounts") {
        if ($r.sku -and $r.sku.tier) { 
            $r.sku.PSObject.Properties.Remove("tier")
        }
    }

    # App Service Plan specific cleanup - remove read-only 'tier' from SKU
    if ($r.type -eq "Microsoft.Web/serverfarms") {
        if ($r.sku -and $r.sku.tier) { 
            $r.sku.PSObject.Properties.Remove("tier")
        }
    }

    # Cosmos DB specific cleanup - remove defaultPriorityLevel if enablePriorityBasedExecution is false
    if ($r.type -eq "Microsoft.DocumentDB/databaseAccounts") {
        if ($r.properties -and $r.properties.enablePriorityBasedExecution -eq $false) {
            if ($r.properties.defaultPriorityLevel) {
                $r.properties.PSObject.Properties.Remove("defaultPriorityLevel")
            }
        }
    }

    $cleanedResources += $r
}

$jsonContent.resources = $cleanedResources
Write-Host "  Pruned from $initialCount to $($cleanedResources.Count) resources." -ForegroundColor Green

$cleanJsonFile = Join-Path $OutputPath "template.clean.json"
$jsonContent | ConvertTo-Json -Depth 100 | Set-Content -Path $cleanJsonFile

# 6. DECOMPILE TO BICEP
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

# 7. BICEP SANITIZER (BCP034 Fix + VNet/Subnet Cycle Fix)
Write-Host "Sanitizing broken dependencies..." -ForegroundColor Yellow
$bicepLines = Get-Content -Path $bicepFile
$cleanBicepLines = @()
$insideDependsOn = $false
$skipResource = $false
$braceDepth = 0

# First pass: collect standalone subnet resource names that would cause cycles
$standaloneSubnets = @()
foreach ($line in $bicepLines) {
    if ($line -match "resource\s+(\w+)\s+'Microsoft\.Network/virtualNetworks/subnets@") {
        $standaloneSubnets += $matches[1]
    }
}

foreach ($line in $bicepLines) {
    # Skip entire standalone subnet resources (they cause cycles with inline VNet subnets)
    if ($line -match "resource\s+(\w+)\s+'Microsoft\.Network/virtualNetworks/subnets@") {
        $skipResource = $true
        $braceDepth = 0
    }
    
    if ($skipResource) {
        $braceDepth += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count
        $braceDepth -= ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
        if ($braceDepth -le 0 -and $line -match '}') {
            $skipResource = $false
        }
        continue
    }
    
    # Remove id references to standalone subnets inside VNet inline subnet definitions
    if ($standaloneSubnets.Count -gt 0) {
        foreach ($subnetName in $standaloneSubnets) {
            if ($line -match "id:\s*$subnetName\.id") {
                continue  # Skip this line entirely
            }
        }
    }
    
    # Remove the read-only tier warnings if they slipped through JSON cleaning
    if ($line -match 'dependsOn:\s*\[') { $insideDependsOn = $true; $cleanBicepLines += $line; continue }
    if ($insideDependsOn -and $line -match '\]') { $insideDependsOn = $false; $cleanBicepLines += $line; continue }
    if ($insideDependsOn) {
        if ($line -match "'") { continue }
    }
    $cleanBicepLines += $line
}
$bicepContent = $cleanBicepLines -join "`n"

# 8. WIRE APP SETTINGS (String Replace)
Write-Host "Wiring up App Settings..." -ForegroundColor Yellow
$appSettingsVars = ""
foreach ($appName in $functionAppConfigs.Keys) {
    $cleanName = $appName -replace "-","_"
    $appSettingsVars += "`n// Settings for $appName`nvar appSettings_$cleanName = [`n"
    foreach ($setting in $functionAppConfigs[$appName].Settings) {
        $val = $setting.value -replace $SourceEnvironment, '${environmentName}'
        $isManual = $false

        # Mask obvious secrets / keys
        if ($setting.name -match "key|secret|connectionstring|token") {
            $val = "MANUAL_CONFIGURATION_REQUIRED"
            $isManual = $true
        }

        if ($isManual) {
            $manualSettings += [pscustomobject]@{
                AppName     = $appName
                SettingName = $setting.name
            }
        }

        # Track package locations so we know where function code must be uploaded
        if ($setting.name -in @("WEBSITE_RUN_FROM_PACKAGE", "SCM_RUN_FROM_PACKAGE")) {
            $packageSettings += [pscustomobject]@{
                AppName     = $appName
                SettingName = $setting.name
                Value       = $setting.value
            }
        }

        $valueLiteral = "'$val'"
        if ($val -eq '${environmentName}') {
            $valueLiteral = "environmentName"
        }

        $appSettingsVars += "  { name: '$($setting.name)', value: $valueLiteral }`n"
    }
    $appSettingsVars += "]`n"
}

$header = @"
// Auto-generated parameters
@description('Environment name (dev, sit, test, prod)')
param environmentName string

$appSettingsVars
"@
$bicepContent = $header + $bicepContent

foreach ($appName in $functionAppConfigs.Keys) {
    $cleanName = $appName -replace "-","_"
    # Look for the config block
    $childConfigPattern = "(?ms)resource\s+\w+\s+'Microsoft.Web/sites/config@[^']+'\s*=\s*\{\s*parent:\s*(?<parentSymbolic>\w+).*?name:\s*'web'.*?properties:\s*\{(.*?)\}"
    $matches = [regex]::Matches($bicepContent, $childConfigPattern)
    
    foreach ($m in $matches) {
        $fullMatch = $m.Value
        $parentSymbolic = $m.Groups['parentSymbolic'].Value
        $propertiesContent = $m.Groups[1].Value
        
        if ($parentSymbolic -match ($appName -replace "-","_")) {
             if ($propertiesContent -notmatch "appSettings:") {
                 $newProperties = "`n    appSettings: appSettings_$cleanName" + $propertiesContent
                 $bicepContent = $bicepContent.Replace($fullMatch, $fullMatch.Replace($propertiesContent, $newProperties))
             }
        }
    }
}

# 9. REMOVE UNUSED PARAMETERS
Write-Host "Removing unused parameters..." -ForegroundColor Yellow
$bicepLines = $bicepContent -split "`n"
$finalBicepLines = @()
$paramNames = @()

foreach ($line in $bicepLines) {
    if ($line -match '^param\s+(?<name>[a-zA-Z0-9_]+)\s+') {
        $paramNames += $matches['name']
    }
}

$usedParams = @{}
foreach ($p in $paramNames) {
    if ($bicepContent -match "(?<!param\s+)\b$p\b") {
        $usedParams[$p] = $true
    }
}

foreach ($line in $bicepLines) {
    if ($line -match '^param\s+(?<name>[a-zA-Z0-9_]+)\s+') {
        $pName = $matches['name']
        # Always keep environmentName (we inject it), skip unused params
        if ($pName -eq "environmentName") { 
            $finalBicepLines += $line
            continue 
        }
        if (-not $usedParams.ContainsKey($pName)) { continue }
    }
    $finalBicepLines += $line
}
$bicepContent = $finalBicepLines -join "`n"
Set-Content -Path $bicepFile -Value $bicepContent

# 10. GENERATE PARAMETERS
Write-Host "Generating parameters..." -ForegroundColor Yellow
$paramRegex = [regex]::Matches($bicepContent, 'param\s+([a-zA-Z0-9_]+)\s+string')
# Build list of actual parameters defined in the template
$templateParams = @()
foreach ($match in $paramRegex) {
    $templateParams += $match.Groups[1].Value
}

$sitParameters = @{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        environmentName = @{ value = $TargetEnvironment }
    }
}

foreach ($match in $paramRegex) {
    $pName = $match.Groups[1].Value
    if ($pName -eq "environmentName") { continue }
    
    $matchRes = $resources | Where-Object { $pName -match ($_.name -replace "-","_") } | Select-Object -First 1
    if ($matchRes) {
        $newValue = $matchRes.name -replace $SourceEnvironment, $TargetEnvironment

        # Only certain resource types are globally unique and MUST be renamed if
        # the dev->sit replacement does not change the name. Other resources
        # (e.g. function apps, routes, identities) can safely keep the same
        # logical name across environments because they live in different
        # resource groups or hosts.
        $forceUnique = $false
        $maxLen = 63

        switch ($matchRes.type) {
            "Microsoft.Storage/storageAccounts" {
                $forceUnique = $true
                $maxLen = 24   # storage account name length limit
            }
            "Microsoft.DocumentDB/databaseAccounts" {
                $forceUnique = $true
                $maxLen = 44   # Cosmos DB account name limit
            }
            "Microsoft.ServiceBus/namespaces" {
                $forceUnique = $true
                $maxLen = 50   # Service Bus namespace name limit
            }
            "Microsoft.Web/sites" {
                $forceUnique = $true
                $maxLen = 60   # Web App/Function App name limit (globally unique)
            }
            "Microsoft.KeyVault/vaults" {
                $forceUnique = $true
                $maxLen = 24   # Key Vault name limit (globally unique)
            }
        }

        # If this is a globally-unique resource and the name didn't change
        # after dev->sit replacement, we MUST make it unique for the target env.
        if ($forceUnique -and $newValue -eq $matchRes.name) {
            Write-Host "  Renaming: '$newValue' -> " -ForegroundColor Yellow -NoNewline

            if (($TargetEnvironment + $newValue).Length -le $maxLen) {
                $newValue = $TargetEnvironment + $newValue
            } else {
                # Truncate to fit
                $newValue = $TargetEnvironment + $newValue.Substring(0, $maxLen - $TargetEnvironment.Length)
            }
            Write-Host "'$newValue'" -ForegroundColor Green
        }

        $sitParameters.parameters[$pName] = @{ value = $newValue }
    } else {
        if ($pName -match "workspace.*externalid") {
             # Try to find actual Log Analytics workspace in source RG
             $laWorkspace = az monitor log-analytics workspace list --resource-group $SourceResourceGroup --query "[0].id" -o tsv 2>$null
             if ($laWorkspace) {
                 $sitParameters.parameters[$pName] = @{ value = $laWorkspace }
             } else {
                 $sitParameters.parameters[$pName] = @{ value = "/subscriptions/$SourceSubscription/resourceGroups/$SourceResourceGroup/providers/Microsoft.OperationalInsights/workspaces/PLACEHOLDER" }
             }
        } elseif ($pName -match "workspace") {
             $sitParameters.parameters[$pName] = @{ value = "CHANGE_ME" }
        } elseif ($pName -match "user") {
             $sitParameters.parameters[$pName] = @{ value = "Administrator" }
        } else {
             $sitParameters.parameters[$pName] = @{ value = "CHANGE_ME" }
        }
    }
}

# 10b. DETECT AND FIX DUPLICATE PARAMETER VALUES
# Group parameters by resource type prefix (e.g., components_, sites_, storageAccounts_)
# Within each group, if multiple parameters resolve to the same value, make them unique.
Write-Host "Checking for duplicate parameter values..." -ForegroundColor Yellow
$duplicatesFixed = 0

# Build a map of value -> list of param names (only for resource-name parameters)
$valueToParams = @{}
foreach ($pName in $sitParameters.parameters.Keys) {
    if ($pName -eq "environmentName") { continue }
    $val = $sitParameters.parameters[$pName].value
    if (-not $valueToParams.ContainsKey($val)) {
        $valueToParams[$val] = @()
    }
    $valueToParams[$val] += $pName
}

# For each value that has multiple parameters, check if they are the same resource type
# If so, we have a naming collision that will cause ARM deployment to fail
foreach ($val in $valueToParams.Keys) {
    $params = $valueToParams[$val]
    if ($params.Count -le 1) { continue }
    
    # Group by resource type prefix (first segment before underscore, e.g., "components", "sites")
    $byPrefix = @{}
    foreach ($p in $params) {
        $prefix = ($p -split "_")[0]
        if (-not $byPrefix.ContainsKey($prefix)) {
            $byPrefix[$prefix] = @()
        }
        $byPrefix[$prefix] += $p
    }
    
    # Within each prefix group, if there are duplicates, fix them
    foreach ($prefix in $byPrefix.Keys) {
        $group = $byPrefix[$prefix]
        if ($group.Count -le 1) { continue }
        
        # These parameters all have the same value and same resource type prefix - collision!
        Write-Host "  WARNING: Duplicate value '$val' for parameters: $($group -join ', ')" -ForegroundColor Yellow
        
        # Keep the first one as-is, rename the rest using their original parameter name suffix
        for ($i = 1; $i -lt $group.Count; $i++) {
            $pName = $group[$i]
            # Extract the meaningful part of the parameter name (after prefix_)
            $nameParts = $pName -split "_"
            if ($nameParts.Count -gt 1) {
                # Use the last part of the param name as the unique value
                $uniqueSuffix = $nameParts[-2..-1] -join ""
                $newVal = $uniqueSuffix.ToLower()
            } else {
                $newVal = $pName.ToLower()
            }
            
            Write-Host "    Fixing: $pName -> '$newVal'" -ForegroundColor Green
            $sitParameters.parameters[$pName] = @{ value = $newVal }
            $duplicatesFixed++
        }
    }
}

if ($duplicatesFixed -gt 0) {
    Write-Host "  Fixed $duplicatesFixed duplicate parameter value(s)" -ForegroundColor Green
} else {
    Write-Host "  No duplicates found" -ForegroundColor Green
}

$sitParamsFile = Join-Path $OutputPath "parameters.sit.json"
$sitParameters | ConvertTo-Json -Depth 10 | Set-Content -Path $sitParamsFile

# 11. PRE-DEPLOY MANIFEST
$predeployFile = Join-Path $OutputPath "PREDEPLOY.md"
$preLines = @()
$preLines += "# Pre-deployment checklist for SIT"
$preLines += ""
$preLines += "This file is generated by Export-AzureResourceGroup.ps1. It highlights manual actions you must take"
$preLines += "after deploying main.bicep into rg-your-project-sit."
$preLines += ""

$preLines += "## Function App package locations"
if ($packageSettings.Count -eq 0) {
    $preLines += "- No WEBSITE_RUN_FROM_PACKAGE / SCM_RUN_FROM_PACKAGE settings were detected."
} else {
    $groupedPackages = $packageSettings | Group-Object AppName
    foreach ($g in $groupedPackages) {
        $preLines += "- **$($g.Name)**"
        foreach ($p in $g.Group) {
            $preLines += "  - $($p.SettingName): `$($p.Value)".Replace("`r","")
        }
    }
}

$preLines += ""
$preLines += "## App settings requiring real values"
if ($manualSettings.Count -eq 0) {
    $preLines += "- No app settings were marked as MANUAL_CONFIGURATION_REQUIRED."
} else {
    $groupedManual = $manualSettings | Group-Object AppName
    foreach ($g in $groupedManual) {
        $preLines += "- **$($g.Name)**"
        foreach ($m in $g.Group) {
            $preLines += "  - $($m.SettingName) (value will be MANUAL_CONFIGURATION_REQUIRED in SIT)"
        }
    }
}

$preLines += ""
$preLines += "## Key Vault access policies"
$kvResources = $jsonContent.resources | Where-Object { $_.type -eq "Microsoft.KeyVault/vaults" }
if (-not $kvResources -or $kvResources.Count -eq 0) {
    $preLines += "- No Key Vaults were exported."
} else {
    foreach ($kv in $kvResources) {
        $preLines += "- **$($kv.name)**"
        $policies = $kv.properties.accessPolicies
        if ($policies) {
            foreach ($p in $policies) {
                $preLines += "  - objectId: $($p.objectId) (verify this principal is correct for SIT)"
            }
        } else {
            $preLines += "  - No accessPolicies array present."
        }
    }
}

Set-Content -Path $predeployFile -Value ($preLines -join "`n")

# 12. DEPLOY SCRIPT
$deployScript = @"
# Deployment script for SIT environment
param([switch]`$Validate, [switch]`$WhatIf)
`$ResourceGroup = "rg-your-project-sit"
`$Location = "uksouth"
`$TemplateFile = "main.bicep"
`$ParametersFile = "parameters.sit.json"

Write-Host "Deploying to `$ResourceGroup..." -ForegroundColor Cyan
az account set --subscription "$SourceSubscription"
az group create --name "`$ResourceGroup" --location "`$Location"

Write-Host "Validating Bicep syntax..." -ForegroundColor Yellow
# Use bicep build for validation - capture output to check for actual errors (not just warnings)
`$buildOutput = az bicep build --file "`$TemplateFile" --stdout 2>&1
`$hasErrors = `$buildOutput | Select-String -Pattern ": Error " -Quiet
if (`$hasErrors) {
    Write-Host "Bicep validation failed!" -ForegroundColor Red
    `$buildOutput | Where-Object { `$_ -match ": Error " }
    exit 1
}
Write-Host "Validation passed! (warnings ignored)" -ForegroundColor Green
if (`$Validate) { exit 0 }
if (`$WhatIf) { az deployment group what-if --resource-group "`$ResourceGroup" --template-file "`$TemplateFile" --parameters "@`$ParametersFile"; exit 0 }

az deployment group create --resource-group "`$ResourceGroup" --template-file "`$TemplateFile" --parameters "@`$ParametersFile"
"@
Set-Content -Path (Join-Path $OutputPath "deploy-sit.ps1") -Value $deployScript

Write-Host ""
Write-Host "SUCCESS!" -ForegroundColor Green
Write-Host "1. Run .\exported-bicep\Export-AzureResourceGroup.ps1 to re-export" -ForegroundColor White