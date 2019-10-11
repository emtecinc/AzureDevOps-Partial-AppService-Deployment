#Kudo Api Authorization token

function Get-KuduApiAuthorisationHeaderValue($userName, $password){
	Write-Host "Get-KuduApiAuthorisationHeaderValue Start"
    return ("Basic {0}" -f [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $userName, $password))))
	Write-Host "Get-KuduApiAuthorisationHeaderValue End"
}

# Fetch the publishing credential
function Get-AzureRmWebAppPublishingCredentials($webAppName,$resourceGroupName,$slotName){
	Write-Host "Get-AzureRmWebAppPublishingCredentials Start"
	if ([string]::IsNullOrWhiteSpace($slotName)){
		$resourceType = "Microsoft.Web/sites/config"
		$resourceName = "$webAppName/publishingcredentials"
	}
	else{
		$resourceType = "Microsoft.Web/sites/slots/config"
		$resourceName = "$webAppName/$slotName/publishingcredentials"
	}
	$publishingCredentials = Invoke-AzureRmResourceAction -ResourceGroupName $resourceGroupName -ResourceType $resourceType -ResourceName $resourceName -Action list -ApiVersion 2015-08-01 -Force
    return $publishingCredentials
	Write-Host "Get-AzureRmWebAppPublishingCredentials End"
}

#Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE = 0 , so that KUDU can replace the files/folders
function Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE($webapp,$webAppName){
		Write-Host "Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE Start"
		$oldAppSettings = $webapp.SiteConfig.AppSettings
		$newAppSettings = @{}
		ForEach ($item in $oldAppSettings) {
			$newAppSettings[$item.Name] = $item.Value
		}
		$newAppSettings.WEBSITE_RUN_FROM_PACKAGE = "0"
		Set-AzureRmWebApp -AppSettings $newAppSettings -Name $webAppName -ResourceGroupName $webapp.ResourceGroup 
		return $oldAppSettings
		Write-Host "Set-SiteAppSettings-WEBSITE_RUN_FROM_PACKAGE End"
}

#Revert the old Site settings
function Revert-SiteAppSettings($appSettings, $webapp,$webAppName)
{
	Write-Host "Revert-SiteAppSettings Start"
	$appSettings = $webapp.SiteConfig.AppSettings
	$oldAppSettingsHashTable = @{}
	ForEach ($ap in $appSettings) {
		$oldAppSettingsHashTable[$ap.Name] = $ap.Value
	}

	$oldAppSettingsHashTable.WEBSITE_RUN_FROM_PACKAGE = "1"
	Set-AzureRmWebApp -AppSettings $oldAppSettingsHashTable -Name $webAppName -ResourceGroupName $webapp.ResourceGroup 
	Write-Host "Revert-SiteAppSettings End"
}

#Deploy the files and folder inside wwwroot directory
function Deploy-File-Folder($sourcePath,$sourceRelativePath,$kuduApiUrl,$kuduApiAuthorisationToken){
	Write-Host "Deploy-File-Folder Start"
    $path = Get-Item $sourcePath
    $sourcePath = $sourcePath.trim()

    if((Get-Item $sourcePath) -is [System.IO.DirectoryInfo]){
        Write-Host "directory/folder"
		$tempDr = $env:AGENT_TEMPDIRECTORY
        $sourcePath = $sourcePath.Replace("/", "\")
		Write-Host $sourcePath
		$fileName =  [System.IO.Path]::GetFileName($sourcePath)  
        if($fileName -eq "")
        {
            Write-Host "File name is empty..generating temporary file name"
            $currentDateTime = Get-Date -Format "MM-dd-yyyy-HH-mm-ss"
            $destinationFilePath = "$tempDr\$currentDateTime.zip"
     	    Write-Host "Creating .zip file - $destinationFilePath"
		    [io.compression.zipfile]::CreateFromDirectory($sourcePath,$destinationFilePath) #Do not include the base directory
	        Write-Host "Created .zip file"    
        }
        else 
        {    
            $destinationFilePath = "$tempDr\$fileName"
     	    Write-Host "Creating .zip file - $destinationFilePath"		
            [io.compression.zipfile]::CreateFromDirectory($sourcePath,$destinationFilePath, 0, $true)
	        Write-Host "Created .zip file"      
	    }
    }else{
        Write-Host "file"
        $destinationFilePath = $path.DirectoryName + "\" + $path.BaseName + ".zip"
        Write-Host "Creating .zip file"
        Compress-Archive -Path $sourcePath -Update -DestinationPath $destinationFilePath
        Write-Host "Created .zip file"
    }
    if($sourceRelativePath -ne "")
    {
	    Write-Host "source relative path: $sourceRelativePath"
        $destKuduApiUrl = ([System.IO.Path]::GetDirectoryName("$sourceRelativePath")).Replace("\", "/")
	    Write-Host "dest url: $destKuduApiUrl"
	    if($destKuduApiUrl -eq ""){
		    Write-Host "dest url Empty"
		    $destKuduApiUrl = "$kuduApiUrl"
	    }else{
		    $destKuduApiUrl = "$kuduApiUrl/$destKuduApiUrl/"
	    }
	}
    else 
    {
    	    $destKuduApiUrl = "$kuduApiUrl"
    }

	Write-Host "$destKuduApiUrl is destination kudu URL"

    Invoke-RestMethod -Uri $destKuduApiUrl `
                        -Headers @{"Authorization"=$kuduApiAuthorisationToken;"If-Match"="*"} `
                        -Method PUT `
                        -InFile $destinationFilePath `
                        -ContentType "multipart/form-data"


    Write-Host "Folder Uploaded successfully"

    Write-Host "Removing .zip file created"
    Remove-Item -Path $destinationFilePath
    Write-Host "Removed created .zip file "
	Write-Host "Deploy-File-Folder End"
}

 function Extract-ZipFileContent($zipFilePath){
    $zip = [System.IO.Compression.ZipFile]::Open($zipFilePath, 'read')
    $currentDateTime = Get-Date -Format "MM-dd-yyyy-HH-mm-ss"
    $extractPath = "$env:AGENT_TEMPDIRECTORY\Extracted\$currentDateTime"
    [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $extractPath)
    return $extractPath;
}

# Get list of files and folder within given path
function Get-DirectoryContent($webAppName,$directoryKuduPath,$slotName,$kuduApiAuthorisationToken,$alternativeUrl){
	Write-Host "Get-DirectoryContent Start"
	$directoryKuduPath = $directoryKuduPath.trim()

	if ($slotName -eq ""){

		$kuduApiUrl = "https://$webAppName.scm.azurewebsites.net/api/vfs/site/wwwroot/"
	}
	else{
		$kuduApiUrl = "https://$webAppName`-$slotName.scm.azurewebsites.net/api/vfs/site/wwwroot/"
	}

	if(($alternativeUrl) -and ($alternativeUrl -ne "")){
		$kuduApiUrl = $kuduApiUrl.Replace("scm.azurewebsites.net","$alternativeUrl")
	}
    #if ($directoryKuduPath -eq '/') {
    #    $directoryKuduPath = ""	    
    #}

    $apiUrl = "$kuduApiUrl$directoryKuduPath"
	Write-Host "Api Url: $apiUrl"
	try {
    	$dirList = Invoke-RestMethod -Uri $apiUrl `
									 -Headers @{"Authorization"=$kuduApiAuthorisationToken;"If-Match"="*"} `
									 -Method GET `
									 -ContentType "application/json"		
		return $dirList
	}
	catch {
		if($_.Exception.Response.StatusCode.value__ -eq "404"){
			Write-Host "File not found (but ignored because of setting)"

            return 0
		}
		else {
			Write-Host "Exception" 
			throw $_.Exception
		}
	}

	Write-Host "Get-DirectoryContent End"
}

#This function will Cleanup the directory with files 
function Cleanup-DestinationDirectory($directoryContent, $kuduApiAuthorisationToken)
{
	Write-Host "Cleanup-DestinationDirectory Start"
	foreach($content in $directoryContent)
    {
		Write-Host $content.mime
              
            if($content.mime -eq "inode/directory")
            {
                    Write-Host "Deleting DIRECTORY"
                    $childContent = Invoke-RestMethod -Uri $content.href -Headers @{"Authorization"=$kuduApiAuthorisationToken;"If-Match"="*"}  -Method GET -ContentType "application/json"
                    Cleanup-DestinationDirectory -directoryContent $childContent -kuduApiAuthorisationToken $kuduApiAuthorisationToken
            }
              
            Write-Host "Delete: $($content.href)"
            Invoke-RestMethod -Uri $content.href -Headers @{"Authorization"=$kuduApiAuthorisationToken;"If-Match"="*"}  -Method DELETE -ContentType "application/json"
    }
    Write-Host "File Deleted successfully"

	Write-Host "Cleanup-DestinationDirectory End"
}

#Prepare .zip file of wwwroot directory and store it into temp location
function Compress-The-Directory($destinationBackupFilePath, $kuduApiUrl, $kuduApiAuthorisationToken){
	Write-Host "Compress-The-Directory Start"
	Write-Host "Kudu API Url : $kuduApiUrl and destinationBackupFilePath : $destinationBackupFilePath"

    Invoke-RestMethod -Uri $kuduApiUrl `
                        -Headers @{"Authorization"=$kuduApiAuthorisationToken;"If-Match"="*"} `
                        -Method GET `
                        -OutFile "$destinationBackupFilePath" `
                        -ContentType "application/zip"
    Write-Output "Folder backed up successfully"
	Write-Host "Compress-The-Directory End"
}

#Copy the wwwroot.zip folder from temp location and store it into the Azure blob storage.
function Backup-File-To-Storage($sourceFilePath, $storageContainerName, $storageAccountName, $resourceGroupName){
	Write-Host "Backup-File-To-Storage Start"
    Write-Host "Moving $sourceFilePath file to storage account"
    $acctKey = (Get-AzureRmStorageAccountKey -Name $storageAccountName -ResourceGroupName $resourceGroupName).Value[0]
    $storageContext = New-AzureStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $acctKey
    $destFileName = (Get-Item $sourceFilePath).Name
	Set-AzureStorageBlobContent -File $sourceFilePath -Container $storageContainerName -Blob "$destFileName" -Context $storageContext -Force:$Force | Out-Null
	Write-Host "Backup-File-To-Storage execution completed"
	#Remove-Item –path $sourceFilePath
	Write-Host "Backup-File-To-Storage End"
}