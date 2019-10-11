[CmdletBinding()] 
param() 
Trace-VstsEnteringInvocation $MyInvocation 
try { 
	Write-Host "Hello World"
    # Get inputs. 
	$ConnectedServiceName = Get-VstsInput -Name ConnectedServiceName -Require
	$WebAppName = Get-VstsInput -Name WebAppName -Require
	$SourceBasePath = Get-VstsInput -Name SourceFolder -Require
	$SourceRelativePath = Get-VstsInput -Name filePath -Require
	$AlternativeUrl = Get-VstsInput -Name alternativeKuduUrl 
	$StorageAccountName = Get-VstsInput -Name storageAccountName
	$StorageContainerName = Get-VstsInput -Name storageContainerName
    $SlotName = Get-VstsInput -Name slotName
    
    if ($SourceRelativePath -eq '/') {
        $sourceRelativePath = ""	    
    }

    Write-Host "Hello $ConnectedServiceName, $WebAppName, $SourceBasePath, $SourceRelativePath, $AlternativeKuduUrl, $StorageAccountName, $StorageContainerName, $SlotName " 
	
    Write-Host "Adding system.io.compression"
    Add-Type -assembly "system.io.compression.filesystem"


	Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
	Initialize-Azure
	Write-Output "Azure Initialized"

	Import-Module -Force $PSScriptRoot\vfs
	Write-Output "VFS scripts Initialized"
	
	$webapp = Get-AzureRmWebApp -name "$WebAppName"
	$resourceGroup = $webapp.ResourceGroup

	Write-Output "Retrieved web app: $webapp in Resource group: $resourceGroup"
	Write-Output "Retrieving publishing profile"
	$login = Get-AzureRmWebAppPublishingCredentials -webAppName "$WebAppName" -resourceGroupName "$resourceGroup" 
	Write-Output "Publishing profile retrieved"

	$userName = $login.Properties.PublishingUserName
	$password = $login.Properties.PublishingPassword
	
	Write-Host "Retrieving kudo Api authorization token"
	$kuduApiAuthorisationToken = Get-KuduApiAuthorisationHeaderValue $userName $password
	Write-Host "Retrieved kudo Api authorization token"

   
	if ($SlotName -eq ""){
        Write-Host 'Slot is not provided'
		$kuduApiUrl = "https://$webAppName.scm.azurewebsites.net/api/zip/site/wwwroot/"
	}
	else{
		$kuduApiUrl = "https://$webAppName`-$slotName.scm.azurewebsites.net/api/zip/site/wwwroot/"
	}

   
	if(($alternativeUrl) -and ($alternativeUrl -ne "")){
            Write-Host "Alternate URL provided:$alternativeUrl"
			$kuduApiUrl = $kuduApiUrl.Replace("scm.azurewebsites.net","$alternativeUrl")
	}

	Write-Host "Kudu Api URL: $kuduApiUrl"
    if(((Get-Item $sourceBasePath) -isnot [System.IO.DirectoryInfo]) -and ((Get-Item $sourceBasePath).Extension.ToLower() -eq ".zip")) {
          Write-Host "Provided source path is zip file"
          $extractPath = Extract-ZipFileContent -zipFilePath $sourceBasePath
          $sourceBasePath = $extractPath
          Write-Host "Updated source path : $sourceBasePath"
    }
	else 
    {
        Write-Host "Provided source path is directory"
    }

	if (($storageAccountName -ne "") -and ($storageContainerName -ne ""))
	{
		Write-Host "Taking Backup.." 
		$backupDirectory = "$env:AGENT_TEMPDIRECTORY"		
		Write-Host "Taking backup of wwwroot folder at location: $backupDirectory" 
		$currentDateTime = Get-Date -Format "MM-dd-yyyy-HH-mm-ss"
		$backupFilePath = "$backupDirectory\wwwroot_$currentDateTime.zip"

		Compress-The-Directory -destinationBackupFilePath $backupFilePath -kuduApiUrl $kuduApiUrl -kuduApiAuthorisationToken $kuduApiAuthorisationToken

		Backup-File-To-Storage -sourceFilePath $backupFilePath -storageContainerName $storageContainerName -storageAccountName $storageAccountName -resourceGroupName $resourceGroup
		
		Write-Host "Backup process completed" 
	}

    Write-Host "Inside AppServiceDeploy file"   
    
    #Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE = 0 , so that KUDU can replace the files/folders
    Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE -webapp $webapp -webAppName $WebAppName  

    $directoryList = $sourceRelativePath.split(",")

    foreach ($directory in $directoryList) {
	    $sourceDirectoryPath = $directory.trim().trim('/').trim('\')
	    Write-Host "Directory path: $sourceDirectoryPath"
	    $isDirectoryPresent = Get-DirectoryContent -webAppName $webAppName -directoryKuduPath "$sourceDirectoryPath/" -slotName `
            $slotName  -kuduApiAuthorisationToken $kuduApiAuthorisationToken -alternativeUrl $alternativeUrl
	    foreach($dp in $isDirectoryPresent){
		    $ch = $dp.href
		    Write-Host "File hrf from ech: $ch"
	    }
	    $sourcePath = "$sourceBasePath/$sourceDirectoryPath"
	    Write-Host "Source path: $sourcePath"
	    if(((Get-Item $sourcePath) -is [System.IO.DirectoryInfo]) -and ($isDirectoryPresent -ne 0)){
		    # Delete only if this is directory
		    $dirs = Get-DirectoryContent -webAppName $webAppName -directoryKuduPath "$sourceDirectoryPath/" -slotName `
            $slotName  -kuduApiAuthorisationToken $kuduApiAuthorisationToken -alternativeUrl $alternativeUrl

		    Cleanup-DestinationDirectory -directoryContent $dirs -directoryKuduPath "$sourceDirectoryPath/" -kuduApiAuthorisationToken $kuduApiAuthorisationToken
	    }

	    Deploy-File-Folder -sourcePath "$sourcePath" -sourceRelativePath $sourceDirectoryPath -kuduApiUrl $kuduApiUrl -kuduApiAuthorisationToken $kuduApiAuthorisationToken
    }

    Write-Host "AppServiceDeploy file execution completed" 


} finally { 
    Trace-VstsLeavingInvocation $MyInvocation 
}