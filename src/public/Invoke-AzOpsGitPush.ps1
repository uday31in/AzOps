function Invoke-AzOpsGitPush {

    [CmdletBinding()]
    [OutputType()]
    param ()

    begin {
        if ($global:AzOpsSkipResourceGroup -eq "1") {
            $skipResourceGroup = $true
        }
        else {
            $skipResourceGroup = $false
        }
        if ($global:AzOpsSkipPolicy -eq "1") {
            $skipPolicy = $true
        }
        else {
            $skipPolicy = $false
        }
        
        # Skip AzDevOps Run
        $skip = $false

        Write-AzOpsLog -Level Information -Topic "git" -Message "Fetching latest origin changes"
        Start-AzOpsNativeExecution {
            git fetch origin
        } | Out-Host

        if ($global:AzOpsStrictMode -eq 1) {
            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "AzOpsStrictMode is set to 1, verifying pull before push"
            
            Write-AzOpsLog -Level Information -Topic "git" -Message "Fetching latest origin changes"
            Start-AzOpsNativeExecution {
                git fetch origin
            } | Out-Host

            Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out origin branch (main)"
            Start-AzOpsNativeExecution {
                git checkout origin/main
            } | Out-Host

            Write-AzOpsLog -Level Information -Topic "git" -Message "Pulling origin branch (main) changes"
            Start-AzOpsNativeExecution {
                git pull origin main
            } | Out-Host

            Write-AzOpsLog -Level Information -Topic "Initialize-AzOpsRepository" -Message "Invoking repository initialization"
            Initialize-AzOpsRepository -InvalidateCache -Rebuild -SkipResourceGroup:$skipResourceGroup -SkipPolicy:$skipPolicy

            Write-AzOpsLog -Level Information -Topic "git" -Message "Adding azops file changes"
            Start-AzOpsNativeExecution {
                git add --intent-to-add $global:AzOpsState
            } | Out-Host

            Write-AzOpsLog -Level Information -Topic "git" -Message "Checking for additions / modifications / deletions"
            $diff = Start-AzOpsNativeExecution {
                git diff --ignore-space-at-eol --name-status
            }

            Write-AzOpsLog -Level Information -Topic "git" -Message "Resetting local main branch"
            Start-AzOpsNativeExecution {
                git reset --hard
            } | Out-Host

            switch ($global:SCMPlatform) {
                "GitHub" {
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Checking if local branch ($global:GitHubHeadRef) exists"
                    $branch = Start-AzOpsNativeExecution {
                        git branch --list $global:GitHubHeadRef
                    }
        
                    if ($branch) {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out existing local branch ($global:GitHubHeadRef)"
                        Start-AzOpsNativeExecution {
                            git checkout $global:GitHubHeadRef
                        } | Out-Host
                    }
                    else {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out new local branch ($global:GitHubHeadRef)"
                        Start-AzOpsNativeExecution {
                            git checkout -b $global:GitHubHeadRef origin/$global:GitHubHeadRef
                        } | Out-Host
                    }
                }
                "AzureDevOps" {
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Checking if local branch ($global:AzDevOpsHeadRef) exists"
                    $branch = Start-AzOpsNativeExecution {
                        git branch --list $global:AzDevOpsHeadRef
                    }
        
                    if ($branch) {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out existing local branch ($global:AzDevOpsHeadRef)"
                        Start-AzOpsNativeExecution {
                            git checkout $global:AzDevOpsHeadRef
                        } | Out-Host
                    }
                    else {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out new local branch ($global:AzDevOpsHeadRef)"
                        Start-AzOpsNativeExecution {
                            git checkout -b $global:AzDevOpsHeadRef origin/$global:AzDevOpsHeadRef
                        } | Out-Host
                    }
                }
            }

            if ($diff) {
                Write-AzOpsLog -Level Information -Topic "git" -Message "Formatting diff changes"
                $diff = $diff -join ","

                Write-AzOpsLog -Level Information -Topic "git" -Message "Changes:"
                $output = @()
                $diff.Split(",") | ForEach-Object {
                    $output += ( "``" + $_ + "``")
                    $output += "`n`n"
                    Write-AzOpsLog -Level Information -Topic "git" -Message $_
                }

                switch ($global:SCMPlatform) {
                    "GitHub" {
                        Write-AzOpsLog -Level Information -Topic "rest" -Message "Writing comment to pull request"
                        Write-AzOpsLog -Level Verbose -Topic "rest" -Message "Uri: $global:GitHubComments"
                        $params = @{
                            Headers = @{
                                "Authorization" = ("Bearer " + $global:GitHubToken)
                                "Content-Type"  = "application/json"
                            }
                            Body    = (@{
                                    "body" = "$(Get-Content -Path "$PSScriptRoot/../auxiliary/guidance/strict/github/README.md" -Raw) `n Changes: `n`n$output"
                                } | ConvertTo-Json)
                        }
                        Invoke-RestMethod -Method "Post" -Uri $global:GitHubComments @params | Out-Null
                        exit 1
                    }
                    "AzureDevOps" {
                        Write-AzOpsLog -Level Information -Topic "rest" -Message "Writing comment to pull request"
                        $params = @{
                            Uri     = ($global:AzDevOpsApiUrl + $global:AzDevOpsProjectId + "/_apis/git/repositories/" + $global:AzDevOpsRepository + "/pullRequests/" + $global:AzDevOpsPullRequestId + "/threads?api-version=5.1")
                            Method  = "Post"
                            Headers = @{
                                "Authorization" = ("Bearer " + $global:AzDevOpsToken)
                                "Content-Type"  = "application/json"
                            }
                            Body    = (@{
                                    comments = @(
                                        (@{
                                                "parentCommentId" = 0
                                                "content"         = "$(Get-Content -Path "$PSScriptRoot/../auxiliary/guidance/strict/azdevops/README.md" -Raw) `n Changes: `n`n$output"
                                                "commentType"     = 1
                                            })
                                    )
                                }  | ConvertTo-Json -Depth 5)
                        }
                        Invoke-RestMethod @params
                        exit 1
                    }
                    default {
                        Write-AzOpsLog -Level Error -Topic "rest" -Message "Could not determine SCM platform from SCMPLATFORM. Current value is $global:SCMPlatform"
                    }
                }
            }
            else {
                Write-AzOpsLog -Level Information -Topic "git" -Message "Branch is consistent with Azure"
            }
        
        }
    }

    process {
        switch ($global:SCMPlatform) {
            "GitHub" {
                $changeSet = @()
                $changeSet = Start-AzOpsNativeExecution {
                    git diff origin/main --ignore-space-at-eol --name-status
                }
            }
            "AzureDevOps" {
                Write-AzOpsLog -Level Information -Topic "git" -Message "Switching to branch"
                Start-AzOpsNativeExecution {
                    git checkout $global:AzDevOpsHeadRef
                } | Out-Host

                $commitMessage = Start-AzOpsNativeExecution {
                    git log -1 --pretty=format:%s
                }
                Write-AzOpsLog -Level Verbose -Topic "git" -Message "Commit message: $commitMessage"

                if ($commitMessage -match "System push commit") {
                    $skip = $true
                }

                if ($skip -eq $true) {
                    $changeSet = @()
                }
                else {
                    $changeSet = @()
                    $changeSet = Start-AzOpsNativeExecution {
                        git diff origin/main --ignore-space-at-eol --name-status
                    }
                }
            }
        }

        if ($changeSet) {
            Write-AzOpsLog -Level Information -Topic "git" -Message "Deployment required"
            
            $deleteSet = @()
            $addModifySet = @()
            foreach ($change in $changeSet) {
                $filename = ($change -split "`t")[-1]
                if (($change -split "`t" | Select-Object -first 1) -eq 'D') {
                    $deleteSet += $filename
                }
                elseif (($change -split "`t" | Select-Object -first 1) -eq 'A' -or 'M' -or 'R') {
                    $addModifySet += $filename
                }
            }

            Write-AzOpsLog -Level Information -Topic "git" -Message "Add / Modify:"
            $addModifySet | ForEach-Object {
                Write-AzOpsLog -Level Information -Topic "git" -Message $_
            }

            Write-AzOpsLog -Level Information -Topic "git" -Message "Delete:"
            $deleteSet | ForEach-Object {
                Write-AzOpsLog -Level Information -Topic "git" -Message $_
            }

            $addModifySet `
            | Where-Object -FilterScript { $_ -match '/*.subscription.json$' } `
            | Sort-Object -Property $_ `
            | ForEach-Object {
                Write-AzOpsLog -Level Information -Topic "Invoke-AzOpsGitPush" -Message "Invoking new state deployment - *.subscription.json for a file $_"
                New-AzOpsStateDeployment -filename $_
            }

            $addModifySet `
            | Where-Object -FilterScript { $_ -match '/*.providerfeatures.json$' } `
            | Sort-Object -Property $_ `
            | ForEach-Object {
                Write-AzOpsLog -Level Information -Topic "Invoke-AzOpsGitPush" -Message "Invoking new state deployment - *.providerfeatures.json for a file $_"
                New-AzOpsStateDeployment -filename $_
            }

            $addModifySet `
            | Where-Object -FilterScript { $_ -match '/*.resourceproviders.json$' } `
            | Sort-Object -Property $_ `
            | ForEach-Object {
                Write-AzOpsLog -Level Information -Topic "Invoke-AzOpsGitPush" -Message "Invoking new state deployment - *.resourceproviders.json for a file $_"
                New-AzOpsStateDeployment -filename $_
            }

            $AzOpsDeploymentList = @()
            $addModifySet `
            | Where-Object -FilterScript { $_ -match ((get-item $Global:AzOpsState).Name) } `
            | Foreach-Object {
                $scope = (New-AzOpsScope -path $_)
                if ($scope) {
                    $templateFilePath = $null
                    $templateParameterFilePath = $null
                    $deploymentName = $null
                    #Find the template
                    if ($_.EndsWith('.parameters.json')) {
                        $templateParameterFilePath = (Get-Item $_).FullName

                        if (Test-Path (Get-Item $_).FullName.Replace('.parameters.json', '.json')) {
                            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "Template found $(($(Get-Item $_).FullName.Replace('.parameters.json', '.json')))"
                            $templateFilePath = (Get-Item $_).FullName.Replace('.parameters.json', '.json')
                        }
                        else {
                            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "Template NOT found $(($(Get-Item $_).FullName.Replace('.parameters.json', '.json')))"
                            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "Determining resource type $((Get-Item $global:AzOpsMainTemplate).FullName)"
                            # Determine Resource Type in Parameter file
                            $templateParameterFileHashtable = Get-Content ($_) | ConvertFrom-Json -AsHashtable
                            $effectiveResourceType = $null
                            if (
                                ($null -ne $templateParameterFileHashtable) -and
                                ($templateParameterFileHashtable.Keys -contains "`$schema") -and
                                ($templateParameterFileHashtable.Keys -contains "parameters") -and
                                ($templateParameterFileHashtable.parameters.Keys -contains "input")
                            ) {
                                if ($templateParameterFileHashtable.parameters.input.value.Keys -contains "Type") {
                                    # ManagementGroup and Subscription
                                    $effectiveResourceType = $templateParameterFileHashtable.parameters.input.value.Type
                                }
                                elseif ($templateParameterFileHashtable.parameters.input.value.Keys -contains "ResourceType") {
                                    # Resource
                                    $effectiveResourceType = $templateParameterFileHashtable.parameters.input.value.ResourceType
                                }
                            }
                            # Check if generic template is supporting the resource type for the deployment.
                            if ($effectiveResourceType -and
                                ((Get-Content (Get-Item $global:AzOpsMainTemplate).FullName) | ConvertFrom-Json -AsHashtable).variables.apiVersionLookup.ContainsKey($effectiveResourceType)) {
                                Write-AzOpsLog -Level Information -Topic "pwsh" -Message "effectiveResourceType: $effectiveResourceType AzOpsMainTemplate supports resource type $effectiveResourceType in $((Get-Item $global:AzOpsMainTemplate).FullName)"
                                $templateFilePath = (Get-Item $global:AzOpsMainTemplate).FullName
                            }
                            else {
                                Write-AzOpsLog -Level Warning -Topic "pwsh" -Message "effectiveResourceType: $effectiveResourceType AzOpsMainTemplate does NOT supports resource type $effectiveResourceType in $((Get-Item $global:AzOpsMainTemplate).FullName). Deployment will be ignored"
                            }
                        }
                    }
                    #Find the template parameter file
                    elseif ($_.EndsWith('.json')) {
                        $templateFilePath = (Get-Item $_).FullName
                        if (Test-Path (Get-Item $_).FullName.Replace('.json', '.parameters.json')) {
                            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "Template Parameter found $(($(Get-Item $_).FullName.Replace('.json', '.parameters.json')))"
                            $templateParameterFilePath = (Get-Item $_).FullName.Replace('.json', '.parameters.json')
                        }
                        else {
                            Write-AzOpsLog -Level Information -Topic "pwsh" -Message "Template Parameter NOT found $(($(Get-Item $_).FullName.Replace('.json', '.parameters.json')))"
                        }
                    }
                    #Deployment Name
                    if ($null -ne $templateParameterFilePath) {
                        $deploymentName = (Get-Item $templateParameterFilePath).BaseName.replace('.parameters', '').Replace(' ', '_')
                        if ($deploymentName.Length -gt 64) {
                            $deploymentName = $deploymentName.SubString($deploymentName.IndexOf('-') + 1)
                        }
                    }
                    elseif ($null -ne $templateFilePath) {
                        $deploymentName = (Get-Item $templateFilePath).BaseName.replace('.json', '').Replace(' ', '_')
                        if ($deploymentName.Length -gt 64) {
                            $deploymentName = $deploymentName.SubString($deploymentName.IndexOf('-') + 1)
                        }
                    }
                    #construct deployment object
                    $AzOpsDeploymentList += [PSCustomObject] @{
                        [string] 'templateFilePath'          = $templateFilePath
                        [string] 'templateParameterFilePath' = $templateParameterFilePath
                        [string] 'deploymentName'            = $deploymentName
                        [string] 'scope'                     = $scope.scope
                    }
                    #New-AzOpsDeployment -templateFilePath $templateFilePath -templateParameterFilePath $templateParameterFilePath
                }
                else {
                    Write-AzOpsLog -Level Information -Topic "pwsh" -Message "$_ is not under $($Global:AzOpsState) and ignored for the deployment"
                }
            }
            #Starting Tenant Deployment
            $AzOpsDeploymentList `
            | Where-Object -FilterScript { $null -ne $_.templateFilePath } `
            | Select-Object  scope, deploymentName, templateFilePath, templateParameterFilePath -Unique `
            | ForEach-Object {
                New-AzOpsDeployment -templateFilePath $_.templateFilePath `
                                    -templateParameterFilePath  ($_.templateParameterFilePath ? $_.templateParameterFilePath : $null)
            }
        }
        else {
            Write-AzOpsLog -Level Information -Topic "git" -Message "Deployment not required"
        }
    }

    end {
        if ($skip -eq $false) {
            switch ($global:SCMPlatform) {
                "GitHub" {
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out existing local branch ($global:GitHubHeadRef)"
                    Start-AzOpsNativeExecution {
                        git checkout $global:GitHubHeadRef
                    } | Out-Host
                
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Pulling origin branch ($global:GitHubHeadRef) changes"
                    Start-AzOpsNativeExecution {
                        git pull origin $global:GitHubHeadRef
                    } | Out-Host
                }
                "AzureDevOps" {
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Checking out existing local branch ($global:AzDevOpsHeadRef)"
                    Start-AzOpsNativeExecution {
                        git checkout $global:AzDevOpsHeadRef
                    } | Out-Host
                
                    Write-AzOpsLog -Level Information -Topic "git" -Message "Pulling origin branch ($global:AzDevOpsHeadRef) changes"
                    Start-AzOpsNativeExecution {
                        git pull origin $global:AzDevOpsHeadRef
                    } | Out-Host
                }
            }
        
            Write-AzOpsLog -Level Information -Topic "Initialize-AzOpsRepository" -Message "Invoking repository initialization"
            Initialize-AzOpsRepository -InvalidateCache -Rebuild -SkipResourceGroup:$skipResourceGroup -SkipPolicy:$skipPolicy
        
            Write-AzOpsLog -Level Information -Topic "git" -Message "Adding azops file changes"
            Start-AzOpsNativeExecution {
                git add $global:AzOpsState
            } | Out-Host
        
            Write-AzOpsLog -Level Information -Topic "git" -Message "Checking for additions / modifications / deletions"
            $status = Start-AzOpsNativeExecution {
                git status --short
            }
        
            if ($status) {
                Write-AzOpsLog -Level Information -Topic "git" -Message "Creating new commit"
                Start-AzOpsNativeExecution {
                    git commit -m 'System push commit'
                } | Out-Host
        
                switch ($global:SCMPlatform) {
                    "GitHub" {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Pushing new changes to origin ($global:GitHubHeadRef)"
                        Start-AzOpsNativeExecution {
                            git push origin $global:GitHubHeadRef
                        } | Out-Host
                    }
                    "AzureDevOps" {
                        Write-AzOpsLog -Level Information -Topic "git" -Message "Pushing new changes to origin ($global:AzDevOpsHeadRef)"
                        Start-AzOpsNativeExecution {
                            git push origin $global:AzDevOpsHeadRef
                        } | Out-Host
                    }
                }
            }
        }
    }
}