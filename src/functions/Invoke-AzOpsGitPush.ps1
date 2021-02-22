﻿function Invoke-AzOpsGitPush {

    [CmdletBinding()]
    param (
        [string]
        $StatePath = (Get-PSFConfigValue -FullName AzOps.Core.State),

        [string]
        $ScmPlatform = (Get-PSFConfigValue -FullName AzOps.Core.SourceControl),

        [string]
        $GitHubHeadRef = (Get-PSFConfigValue -FullName AzOps.Actions.HeadRef),

        [string]
        $GitHubComment = (Get-PSFConfigValue -FullName AzOps.Actions.Comments),

        [string]
        $GitHubToken = (Get-PSFConfigValue -FullName AzOps.Actions.Token),

        [string]
        $AzDevOpsHeadRef = (Get-PSFConfigValue -FullName AzOps.Pipelines.HeadRef),

        [string]
        $AzDevOpsApiUrl = (Get-PSFConfigValue -FullName AzOps.Pipelines.ApiUrl),

        [string]
        $AzDevOpsProjectId = (Get-PSFConfigValue -FullName AzOps.Pipelines.ProjectId),

        [string]
        $AzDevOpsRepository = (Get-PSFConfigValue -FullName AzOps.Pipelines.Repository),

        [string]
        $AzDevOpsPullRequestId = (Get-PSFConfigValue -FullName AzOps.Pipelines.PullRequestId),

        [string]
        $AzDevOpsToken = (Get-PSFConfigValue -FullName AzOps.Pipelines.Token),

        [switch]
        $SkipResourceGroup = (Get-PSFConfigValue -FullName AzOps.Core.SkipResourceGroup),

        [switch]
        $SkipPolicy = (Get-PSFConfigValue -FullName AzOps.Core.SkipPolicy),

        [switch]
        $SkipRole = (Get-PSFConfigValue -FullName AzOps.Core.SkipRole),

        [switch]
        $StrictMode = (Get-PSFConfigValue -FullName AzOps.Core.StrictMode),

        [string]
        $AzOpsMainTemplate = (Get-PSFConfigValue -FullName AzOps.Core.MainTemplate)
    )

    begin {
        if ($ScmPlatform -notin 'GitHub', 'AzDevOps') {
            Stop-PSFFunction -String 'Invoke-AzOpsGitPush.Invalid.Platform' -StringValues $ScmPlatform -EnableException $true -Cmdlet $PSCmdlet -Category InvalidArgument
        }
        $headRef = switch ($ScmPlatform) {
            "GitHub" { $GitHubHeadRef }
            "AzureDevOps" { $AzDevOpsHeadRef }
        }

        Push-Location -Path $StatePath

        # Skip AzDevOps Run
        $skipChange = $false

        $common = @{
            Level = "Host"
            Tag   = 'git'
        }

        # Ensure git on the host has info about origin
        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Fetch'
        Invoke-AzOpsNativeCommand -ScriptBlock { git fetch origin } | Out-Host

        # If not in strict mode: quit begin and continue with process
        if (-not $StrictMode) { return }

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.StrictMode'

        #region Checkout & Update local repository
        #TODO: Clarify redundancy
        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Fetch'
        Invoke-AzOpsNativeCommand -ScriptBlock { git fetch origin } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Checkout' -StringValues main
        Invoke-AzOpsNativeCommand -ScriptBlock { git checkout origin/main } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Pull' -StringValues main
        Invoke-AzOpsNativeCommand -ScriptBlock { git pull origin main } | Out-Host

        Write-PSFMessage -Level Host -String 'Invoke-AzOpsGitPush.Repository.Initialize'
        $parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Inherit -Include SkipResourceGroup, SkipPolicy, SkipRole, StatePath
        Initialize-AzOpsRepository -InvalidateCache -Rebuild @parameters

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Add'
        Invoke-AzOpsNativeCommand -ScriptBlock { git add --intent-to-add $StatePath } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Diff'
        $diff = Invoke-AzOpsNativeCommand -ScriptBlock { git diff --ignore-space-at-eol --name-status }

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Reset'
        Invoke-AzOpsNativeCommand -ScriptBlock { git reset --hard } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Branch' -StringValues $headRef
        $branch = Invoke-AzOpsNativeCommand -ScriptBlock { git branch --list $headRef }

        if ($branch) {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Checkout.Existing' -StringValues $headRef
            Invoke-AzOpsNativeCommand -ScriptBlock { git checkout $headRef } | Out-Host
        }
        else {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Checkout.New' -StringValues $headRef
            Invoke-AzOpsNativeCommand -ScriptBlock { git checkout -b $headRef origin/$headRef } | Out-Host
        }
        #endregion Checkout & Update local repository

        if (-not $diff) {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.IsConsistent'
            return
        }

        #region Inconsistent State
        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Changes'
        $output = foreach ($entry in $diff -join "," -split ",") {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Changes.Item' -StringValues $entry
            '`{0}`' -f $entry
        }

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Rest.PR.Comment'
        switch ($ScmPlatform) {
            "GitHub" {
                Write-PSFMessage -String 'Invoke-AzOpsGitPush.Actions.Uri' -StringValues $GitHubComment
                $params = @{
                    Headers = @{
                        "Authorization" = "Bearer $GitHubToken"
                        "Content-Type"  = "application/json"
                    }
                    Body    = @{ body = "$(Get-Content -Path "$script:ModuleRoot/data/auxiliary/guidance/strict/github/README.md" -Raw) `n Changes: `n`n$($output -join "`n`n")" } | ConvertTo-Json
                }
                $null = Invoke-RestMethod -Method "Post" -Uri $GitHubComment @params
                #TODO: Clarify Intent
                exit 1
            }
            "AzureDevOps" {
                $params = @{
                    Uri     = "$($AzDevOpsApiUrl)$($AzDevOpsProjectId)/_apis/git/repositories/$AzDevOpsRepository/pullRequests/$AzDevOpsPullRequestId/threads?api-version=5.1"
                    Method  = "Post"
                    Headers = @{
                        "Authorization" = "Bearer $AzDevOpsToken"
                        "Content-Type"  = "application/json"
                    }
                    Body    = @{
                        comments = @(
                            @{
                                "parentCommentId" = 0
                                "content"         = "$(Get-Content -Path "$script:ModuleRoot/data/auxiliary/guidance/strict/azdevops/README.md" -Raw) `n Changes: `n`n$($output -join "`n`n")"
                                "commentType"     = 1
                            }
                        )
                    } | ConvertTo-Json -Depth 5
                }
                Invoke-RestMethod @params
                #TODO: Clarify Intent
                exit 1
            }
        }
        #endregion Inconsistent State
    }

    process {
        #region Change
        switch ($ScmPlatform) {
            "GitHub" {
                $changeSet = Invoke-AzOpsNativeCommand -ScriptBlock {
                    git diff origin/main --ignore-space-at-eol --name-status
                }
            }
            "AzureDevOps" {
                Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Pipelines.Branch.Switch'
                Invoke-AzOpsNativeCommand -ScriptBlock { git checkout $AzDevOpsHeadRef } | Out-Host

                $commitMessage = Invoke-AzOpsNativeCommand -ScriptBlock { git log -1 --pretty=format:%s }
                Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Pipelines.Commit.Message' -StringValues $commitMessage

                #TODO: Clarify whether this really should only be checked for Azure DevOps
                if ($commitMessage -match "System push commit") {
                    $skipChange = $true
                }

                if ($skipChange -eq $true) {
                    $changeSet = @()
                }
                else {
                    $changeSet = Invoke-AzOpsNativeCommand -ScriptBlock {
                        git diff origin/main --ignore-space-at-eol --name-status
                    }
                }
            }
        }
        if ($changeSet) {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.AzOps.Change.Invoke'
            Invoke-AzOpsChange -ChangeSet $changeSet -StatePath $StatePath -AzOpsMainTemplate $AzOpsMainTemplate
        }
        else {
            Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.AzOps.Change.Skipped'
        }
        #endregion Change
    }

    end {
        if ($skipChange) {
            Pop-Location
            return
        }

        #region Rebuild
        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Checkout' -StringValues $headRef
        Invoke-AzOpsNativeCommand -ScriptBlock { git checkout $headRef } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Pull' -StringValues $headRef
        Invoke-AzOpsNativeCommand -ScriptBlock { git pull origin $headRef } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.AzOps.Initialize'
        Initialize-AzOpsRepository -InvalidateCache -Rebuild -SkipResourceGroup:$skipResourceGroup -SkipPolicy:$skipPolicy -SkipRole:$SkipRole -StatePath $StatePath

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Add'
        Invoke-AzOpsNativeCommand -ScriptBlock { git add $StatePath } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Status'
        $status = Invoke-AzOpsNativeCommand -ScriptBlock { git status --short }
        if (-not $status) {
            Pop-Location
            return
        }

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Commit'
        Invoke-AzOpsNativeCommand -ScriptBlock { git commit -m 'System push commit' } | Out-Host

        Write-PSFMessage @common -String 'Invoke-AzOpsGitPush.Git.Change.Push' -StringValues $headRef
        Invoke-AzOpsNativeCommand -ScriptBlock { git push origin $headRef } | Out-Host
        #endregion Rebuild

        Pop-Location
    }
}