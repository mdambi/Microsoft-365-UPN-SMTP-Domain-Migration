<#
.SYNOPSIS
    Interactive UPN/Email domain migration script using Microsoft Graph.
    Migrates users from .onmicrosoft.com (or any domain) to a target domain,
    with support for per-user domain overrides, exemptions, and alias retention.

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
    Scopes needed: User.ReadWrite.All, Domain.Read.All, Directory.Read.All
    Compatible with Windows PowerShell 5.1
    Run in a FRESH session — do not connect to Exchange Online first (assembly conflict).
#>

#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement

function Connect-Tenant {
    Write-Host "`n=== Connecting to Microsoft Graph ===" -ForegroundColor Cyan
    Connect-MgGraph -Scopes "User.ReadWrite.All","Domain.Read.All","Directory.Read.All" -NoWelcome
    $ctx = Get-MgContext
    Write-Host "Connected to tenant: $($ctx.TenantId)" -ForegroundColor Green
}

function Get-AllTenantDomains {
    # Returns ALL domains registered in the tenant (verified or not)
    $domains = Get-MgDomain | Select-Object Id, IsVerified
    if (-not $domains) {
        Write-Host "No domains found on this tenant at all. Exiting." -ForegroundColor Red
        exit
    }
    return $domains
}

function Select-DefaultDomain {
    param($domainList)

    Write-Host "`nDomains registered on this tenant:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $domainList.Count; $i++) {
        $verifiedTag = if ($domainList[$i].IsVerified) { "verified" } else { "NOT verified" }
        Write-Host "[$i] $($domainList[$i].Id)  ($verifiedTag)"
    }
    Write-Host "[M] Manually type a domain not listed above (e.g. pre-DNS-cutover migration)"

    $sel = Read-Host "`nSelect the DEFAULT target domain by index, or 'M' to type one manually"

    if ($sel -match '^[Mm]$') {
        $manual = Read-Host "Enter the target domain (e.g. contoso.com)"
        Write-Host "NOTE: If this domain is not added to the tenant in Entra ID, Graph will reject updates for it. Errors will be logged per-user, not fatal." -ForegroundColor Yellow
        return $manual.Trim().ToLower()
    }

    return $domainList[[int]$sel].Id
}

function Get-Mode {
    Write-Host "`nWhat do you want to update?" -ForegroundColor Cyan
    Write-Host "[1] UPN only"
    Write-Host "[2] Primary SMTP (mail) only"
    Write-Host "[3] Both UPN and mail"
    $choice = Read-Host "Choice"
    switch ($choice) {
        "1" { return "UPN" }
        "2" { return "SMTP" }
        "3" { return "BOTH" }
        default { Write-Host "Invalid choice, defaulting to BOTH"; return "BOTH" }
    }
}

function Get-Exemptions {
    $raw = Read-Host "`nEnter email/UPN addresses to fully EXEMPT (no changes at all), comma-separated (or press Enter for none)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return $raw.Split(",") | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
}

function Get-DomainOverrides {
    param($domainList)

    Write-Host "`nDo any users need a DIFFERENT target domain than the default? (Y/N)" -ForegroundColor Cyan
    $ans = Read-Host
    $overrides = @{}
    if ($ans -notmatch '^[Yy]') { return $overrides }

    Write-Host "`nAvailable domains:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $domainList.Count; $i++) { Write-Host "[$i] $($domainList[$i].Id)" }
    Write-Host "[M] Type a domain manually"

    do {
        $userInput = Read-Host "`nEnter user's current email/UPN to override (or press Enter to finish)"
        if ([string]::IsNullOrWhiteSpace($userInput)) { break }

        $domSel = Read-Host "Which domain should '$userInput' be migrated to? (index or 'M' for manual)"
        if ($domSel -match '^[Mm]$') {
            $chosenDomain = (Read-Host "Enter domain for this user").Trim().ToLower()
        } else {
            $chosenDomain = $domainList[[int]$domSel].Id
        }

        $overrides[$userInput.Trim().ToLower()] = $chosenDomain
        Write-Host "Mapped: $userInput -> $chosenDomain" -ForegroundColor Green
    } while ($true)

    return $overrides
}

function Get-AliasChoice {
    $ans = Read-Host "`nKeep each user's OLD address as a secondary alias (proxyAddress)? (Y/N)"
    return $ans -match '^[Yy]'
}

function Get-TargetUsers {
    param($sourceFilterSubstring)

    Write-Host "`nFetching users..." -ForegroundColor Cyan
    $all = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,Mail,ProxyAddresses,OnPremisesSyncEnabled,MailNickname

    if ([string]::IsNullOrWhiteSpace($sourceFilterSubstring)) {
        return $all
    }
    return $all | Where-Object {
        $_.UserPrincipalName -like "*$sourceFilterSubstring*" -or $_.Mail -like "*$sourceFilterSubstring*"
    }
}

function Get-SourceFilter {
    Write-Host "`nOnly process users whose CURRENT UPN/mail contains a specific string?" -ForegroundColor Cyan
    Write-Host "(e.g. type 'onmicrosoft.com' to only touch cloud-only default accounts, or press Enter for ALL users)"
    return Read-Host "Filter string"
}

function Start-Migration {
    Connect-Tenant
    $allDomains   = Get-AllTenantDomains
    $targetDomain = Select-DefaultDomain -domainList $allDomains
    $mode         = Get-Mode
    $sourceFilter = Get-SourceFilter
    $exempt       = Get-Exemptions
    $overrides    = Get-DomainOverrides -domainList $allDomains
    $keepAlias    = Get-AliasChoice
    $users        = Get-TargetUsers -sourceFilterSubstring $sourceFilter

    if (-not $users) {
        Write-Host "`nNo matching users found. Nothing to do." -ForegroundColor Yellow
        return
    }

    Write-Host "`nFound $($users.Count) candidate user(s)." -ForegroundColor Cyan
    $confirm = Read-Host "Proceed with dry-run preview first? (Y/N)"
    $dryRun = $confirm -match '^[Yy]'

    $log = New-Object System.Collections.Generic.List[object]

    foreach ($u in $users) {
        $mailLower = ""
        if ($u.Mail) { $mailLower = $u.Mail.ToLower() }
        $upnLower = $u.UserPrincipalName.ToLower()

        if ($exempt -contains $upnLower -or $exempt -contains $mailLower) {
            Write-Host "SKIP (exempted): $($u.UserPrincipalName)" -ForegroundColor DarkYellow
            continue
        }

        if ($u.OnPremisesSyncEnabled) {
            Write-Host "SKIP (hybrid-synced, must change on-prem): $($u.UserPrincipalName)" -ForegroundColor DarkYellow
            continue
        }

        $effectiveDomain = $targetDomain
        if ($overrides.ContainsKey($upnLower)) {
            $effectiveDomain = $overrides[$upnLower]
        } elseif ($overrides.ContainsKey($mailLower)) {
            $effectiveDomain = $overrides[$mailLower]
        }

        $localPart = $u.MailNickname
        if (-not $localPart) { $localPart = ($u.UserPrincipalName -split "@")[0] }
        $newUpn  = "$localPart@$effectiveDomain"
        $newMail = "$localPart@$effectiveDomain"
        $oldUpn  = $u.UserPrincipalName
        $oldMail = $u.Mail

        $updateParams = @{}
        if ($mode -eq "UPN"  -or $mode -eq "BOTH") { $updateParams["UserPrincipalName"] = $newUpn }
        if ($mode -eq "SMTP" -or $mode -eq "BOTH") { $updateParams["Mail"] = $newMail }

        if ($keepAlias) {
            $proxies = @($u.ProxyAddresses)
            if ($oldMail -and ($proxies -notcontains "SMTP:$oldMail") -and ($proxies -notcontains "smtp:$oldMail")) {
                $proxies += "smtp:$oldMail"
            }
            $updateParams["ProxyAddresses"] = $proxies
        }

        $finalUpn  = $oldUpn
        if ($updateParams.ContainsKey("UserPrincipalName")) { $finalUpn = $updateParams["UserPrincipalName"] }

        $finalMail = $oldMail
        if ($updateParams.ContainsKey("Mail")) { $finalMail = $updateParams["Mail"] }

        $entry = [PSCustomObject]@{
            DisplayName     = $u.DisplayName
            OldUPN          = $oldUpn
            NewUPN          = $finalUpn
            OldMail         = $oldMail
            NewMail         = $finalMail
            TargetDomain    = $effectiveDomain
            OverrideApplied = ($effectiveDomain -ne $targetDomain)
            AliasKept       = $keepAlias
            Status          = "Pending"
        }

        if ($dryRun) {
            $entry.Status = "DryRun"
            Write-Host "[DRY RUN] $($u.DisplayName): $oldUpn -> $finalUpn | $oldMail -> $finalMail" -ForegroundColor Gray
        } else {
            try {
                Update-MgUser -UserId $u.Id -BodyParameter $updateParams
                $entry.Status = "Updated"
                Write-Host "UPDATED: $($u.DisplayName) -> $finalUpn" -ForegroundColor Green
            } catch {
                $entry.Status = "FAILED: $($_.Exception.Message)"
                Write-Host "FAILED: $($u.DisplayName) - $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        $log.Add($entry)
    }

    $csvPath = ".\UPN-Migration-Log-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
    $log | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Host "`nLog saved to $csvPath" -ForegroundColor Cyan

    if ($dryRun) {
        $go = Read-Host "`nDry run complete. Run for real now? (Y/N)"
        if ($go -match '^[Yy]') {
            $log2 = New-Object System.Collections.Generic.List[object]

            foreach ($u in $users) {
                $mailLower2 = ""
                if ($u.Mail) { $mailLower2 = $u.Mail.ToLower() }
                $upnLower2 = $u.UserPrincipalName.ToLower()

                if ($exempt -contains $upnLower2 -or $exempt -contains $mailLower2) { continue }
                if ($u.OnPremisesSyncEnabled) { continue }

                $effectiveDomain2 = $targetDomain
                if ($overrides.ContainsKey($upnLower2)) {
                    $effectiveDomain2 = $overrides[$upnLower2]
                } elseif ($overrides.ContainsKey($mailLower2)) {
                    $effectiveDomain2 = $overrides[$mailLower2]
                }

                $localPart = $u.MailNickname
                if (-not $localPart) { $localPart = ($u.UserPrincipalName -split "@")[0] }

                $updateParams = @{}
                if ($mode -eq "UPN"  -or $mode -eq "BOTH") { $updateParams["UserPrincipalName"] = "$localPart@$effectiveDomain2" }
                if ($mode -eq "SMTP" -or $mode -eq "BOTH") { $updateParams["Mail"] = "$localPart@$effectiveDomain2" }

                if ($keepAlias -and $u.Mail) {
                    $proxies = @($u.ProxyAddresses)
                    if ($proxies -notcontains "smtp:$($u.Mail)") { $proxies += "smtp:$($u.Mail)" }
                    $updateParams["ProxyAddresses"] = $proxies
                }

                $entry2 = [PSCustomObject]@{
                    DisplayName  = $u.DisplayName
                    OldUPN       = $u.UserPrincipalName
                    TargetDomain = $effectiveDomain2
                    Status       = "Pending"
                }

                try {
                    Update-MgUser -UserId $u.Id -BodyParameter $updateParams
                    $entry2.Status = "Updated"
                    Write-Host "UPDATED: $($u.DisplayName)" -ForegroundColor Green
                } catch {
                    $entry2.Status = "FAILED: $($_.Exception.Message)"
                    Write-Host "FAILED: $($u.DisplayName) - $($_.Exception.Message)" -ForegroundColor Red
                }

                $log2.Add($entry2)
            }

            $csvPath2 = ".\UPN-Migration-FinalRun-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
            $log2 | Export-Csv -Path $csvPath2 -NoTypeInformation
            Write-Host "`nFinal run log saved to $csvPath2" -ForegroundColor Cyan
        }
    }

    Write-Host "`nDone." -ForegroundColor Cyan
}

Start-Migration
