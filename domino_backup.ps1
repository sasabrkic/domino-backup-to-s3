#-----------------------------------------------------------------------------------------------------------------#
#---                         PowerShell 2.0 Script for backing up Domino data to Amazon S3 Storage             ---#
#-----------------------------------------------------------------------------------------------------------------#
#                                                                                                                 #
# This script does the following:                                                                                 #
# - stops Domino server                                                                                           #
# - copies files from Domino data or program directory to a temporary location                                    #
# - archives files using 7-Zip                                                                                    #
# - uploads the archive to an S3 Storage bucket                                                                   #
# - starts Domino server                                                                                          #
#                                                                                                                 #
# The prerequisites:                                                                                              #
# - 7-Zip:        Used to archive and compress backup files. The script uses 7z algorithm and strongest           #
#                 compression. Download and install. Change the variable $7zipfilepath if you did not install     #
#                 in default location. http://www.7-zip.org/                                                      #
# - S3Sync:       Used to sync local folder with Amazon S3 bucket. Download and copy to appropriate location      #
#                 (no install necessary). Script assumes that S3Sync.exe is located in                            #
#                 C:\Program Files (x86)\S3Sync\. Change the variable $s3syncfilepath to reflect the actual       #
#                 location. http://sprightlysoft.com/S3Sync/                                                      #
#                                                                                                                 #
# Mandatory variables:                                                                                            #
# - $dominoserver: name of the Domino server service. Open Computer > Manage > Services And Applications >        #
#                  Services and look for Lotus Domino server. Copy value from the Name column,                    #
#                  e.g. Lotus Domino Server (DDominoData).                                                        #
# - $datafolder:   Location of the Domino data folder, e.g. D:\Domino\Data\                                       #
# - $datafiles:    Domino files to backup. Enter path relative to datafolder. For example, names.nsf or           #
#                  mail\jsmith.nsf. Separate entries with comma. Do not remove @ sign or parantheses.             #
# - $workfolder:   path of the folder where files will be copied to, archived and uploaded. The script will       #
#                  automatically generate \working\ and \logs\ subfolders. E.g. D:\backups\                       #
# - $archivename:  name of the 7-Zip archive that is created, without extension. The script will automatically    #
#                  add today's date and time and 7z extension. E.g. data_backup                                   #
# - $s3accesskey:  Amazon S3 Storage Access Key                                                                   #
# - $s3secretkey:  Amazon S3 Storage Secret Key                                                                   #
# - $s3bucketname: name of the Amazon S3 bucket where you wish to upload the backup.                              #
# - $s3foldername: (optional) name of a folder in the bucket. Must end with trailing slash! E.g. domino_backups\  #
#                                                                                                                 #
# NOTE: Enclose file names and paths in quotations (e.g. "mail\jsmith.nsf"). Although not necessary if the path   #
# does not contain spaces, it won't hurt. Also, all path locations MUST end with backslash (\).                   #
#                                                                                                                 #
# Logging                                                                                                         #
# -------                                                                                                         #
# The script will create log file $workfolder\logs\backup_log.txt. The subsequent logs are appended to this file. #
# Relatively small amount of text is logged, so you don't need to worry about the file size.                      #
# The console shows same information that is logged in the file, with addition of runtime information from 7-Zip  #
# and S3Sync.                                                                                                     #
#                                                                                                                 #
# Execution Flow                                                                                                  #
# --------------                                                                                                  #
# The script first initializes some internal variables.                                                           #
#                                                                                                                 #
# Then, it initiates shut-down of the Domino server and waits for its completion. This is performed using         # 
# standard Windows services commands. If the Domino server fails to shut-down, the script will abort.             #
#                                                                                                                 #
# When the server shuths down, the script copies files from data directory to backup directory.                   #
#                                                                                                                 #
# As soon as the file copy operation is finished, the Domino server is started again. Should the server fail to   #
# start, the error is logged, but the execution is continued.                                                     #
#                                                                                                                 #
# The next in line is 7-Zip which zips all files in the backup directory in a single file. The file name consists #
# of an arbitrary part and today's date and time. Which means that we are not using the S3 versioning support and #
# each backup is a separate object in the S3 bucket.                                                              #
#                                                                                                                 #
# After the zip file has been made, S3Sync is called. S3Sync will upload to all *.7z files in the root of the     # 
# backup folder to the defined Amazon S3 bucket and folder.                                                       #
#                                                                                                                 #
# If upload fails, the archive file is left in the backup folder and will be automatically uploaded next time the #
# script runs.                                                                                                    #
#                                                                                                                 #
#-----------------------------------------------------------------------------------------------------------------#
# Author: Sasa Brkic <sasa.brkic@cs-computing.com>                                                                #
# Date: 2012-11-27                                                                                                #
# Version: 1.1                                                                                                    #
#-----------------------------------------------------------------------------------------------------------------#
# Revisions:                                                                                                      #
# v1.1 - The script checks and creates working and log folders if they do not already exist.                      #
# v1.0 - Initial Release                                                                                          #
#-----------------------------------------------------------------------------------------------------------------#

# Domino server details:
$dominoserver = "DOMINO_SERVICE_NAME"

# Backup locations and files. Trailing backslash mandatory for folders (e.g. d:\domino\)! 
$datafolder = "FULL_PATH_TO_DOMINO_DATA_FOLDER"
$datafiles = @("FILE_1", "SOME\PATH\FILE2", "PATH\FILE3")
$workfolder = "FULL_PATH_TO_BACKUP_FOLDER"

# Archive file details:
$archivename = "BACKUP_SET_NAME"

# Amazon S3 Storage details:
$s3accesskey = "S3_ACCESS_KEY"
$s3secretkey = "S3_SECRET_KEY"
$s3bucketname = "S3_BUCKET"
# S3 folder name must end with trailing slash (e.g. backups/)!
$s3foldername = "S3_FOLDER"


# Utility program locations, check if they are correct.
# 7-Zip:
$7zipfilepath = "C:\Program Files\7-Zip\7z.exe"
# S3Sync (64-bit)
$s3syncfilepath = "C:\Program Files (x86)\S3Sync\S3Sync.exe"
# S3Sync (32-bit)
# $s3syncfilepath = "C:\Program Files\S3Sync\S3Sync.exe"


# This function is used to write events to log file.
function Write-Log([string] $info, [bool] $timestamp) {
  if($loginitialized -eq $false) {
    Add-Content $logfile $fileheader
    $script:loginitialized = $true
  } 
  if ($timestamp) {
    Add-Content $logfile ($(Get-Date -Format "HH:mm:ss") + "`t$info")
    Write-Output ($(Get-Date -Format "HH:mm:ss") + "`t$info")
  } else {
    Add-Content $logfile "`t$info"
    Write-Output "`t$info"
  }
}

function Clear-Backup-Folder([string] $excludeext) {
  # excludeext should be in following format: *.7z
  # This will clear backup folder.
  # We have possibility to exclude one type of files in the folder, for example
  # we can delete everything except .7z files - these are files from previous
  # backup jobs, waiting to be sent to the S3 Storage.
  if ($excludeext -eq "") {
    Remove-Item $backupfolder* -Recurse
  } else {
    Remove-Item $backupfolder* -Recurse -Exclude $excludeext
  }
}

function Initialize-Folders () {
  # This function creates backup and log folders if they do not exist.
  if (-not (Test-Path -Path $logfolder)) {
    New-Item -ItemType directory -Path $logfolder | Out-Null
  }
  if (-not (Test-Path -Path $backupfolder)) {
    New-Item -ItemType directory -Path $backupfolder | Out-Null
  }
}
           
# Starting backup job.
$shutdownok = $true
$startupok = $true
$zipok = $true
$syncok = $true
$jobstart = Get-Date
$backupfolder = $workfolder + "working\"
$logfolder = $workfolder + "logs\"
$archivename = $archivename + "_" + (Get-Date -Format "dd_MM_yyyy-HH_mm_ss") + ".7z"
$arhivepath = $backupfolder + $archivename
# Log file details:
$logfile = $logfolder + "backup_log.txt"
$loginitialized = $false
$separator = @"
$("*" * 45)
"@
$fileheader = @"
`r`n
$separator
`tJob Start Date: $(Get-Date -Format "dd.MM.yyyy")
$separator
`n
"@ 

Initialize-Folders

Write-Log "Backup Job Started" $true

Write-Log "Cleaning working folder" $true
Clear-Backup-Folder "*.7z"
if (((Get-ChildItem $backupfolder -Filter "*.7z").Count) -gt 0) {
  # We have 7z files, we'll upload them later.
  # Any existing 7z file will have unique name.
  Write-Log "Previous archive(s) found. Will be uploaded together with today's archive." $true
}

# Initiate Domino server shutdown.
try {
  Write-Log "Shutting down Domino server..." $true
  $shutdowntime = (Measure-Command {Stop-Service $dominoserver -ErrorAction Stop}).TotalSeconds
  $shutdowntime = "{0:N0}" -f $shutdowntime
  Write-Log "Domino server successfully shut-down after $shutdowntime seconds." $true
} catch [Exception] {
  Write-Log "ERROR: Domino server shut-down UNSUCCESSFUL!" $true
  $shutdownok = $false
}

if ($shutdownok) {
  # Server shut-down properly, we can copy files.
  Write-Log "Starting to copy files." $true
  cd "$datafolder"
  foreach ($filetobackup in $datafiles) {
    $pathtobackup = "$datafolder" + "$filetobackup"
    if (Test-Path ("$pathtobackup")) {
      # The following two lines make it possible to easily copy folder structure.
      New-Item -ItemType File -Path ("$backupfolder" + "$filetobackup") -Force | Out-Null
      Copy-Item ("$pathtobackup") ("$backupfolder" + "$filetobackup") -Force
      Write-Log "`tFile successfully copied: $pathtobackup" $false
    } else {
      Write-Log "`tWARNING: File does not exist, skipping: $pathtobackup" $false
    }
  }

  # As soon as file copy has finished, we can start Domino server
  try {
    Write-Log "File copy finished: it is safe to start Domino server." $true
    Write-Log "Starting Domino server..." $true
    Start-Service $dominoserver -ErrorAction Stop
    Write-Log "Domino server successfully started." $true
  } catch [Exception] {
    Write-Log "ERROR: Domino server start-up UNSUCCESSFUL!" $true
    $startupok = $false
  }

  # File copy finished, call 7-Zip to archive them.
  Write-Log "Starting archiving..." $true
  # 7-Zip options: [add to archive] [archive type = 7-Zip] [archive path] [files & folders to include]
  # [files to exclude = 7-Zip (in case there is an archive left from previous job)] [compression = max]
  & $7zipfilepath "a" "-t7z" "$arhivepath" "$backupfolder*" "-x!*.7z" "-mx9"
  if ($LASTEXITCODE -ne 0) {
    # Detect errors from 7-Zip. Note: 7z will crash sometimes if file already exists.
    Write-Log "ERROR: Archiving operation terminated with exit code $LASTEXITCODE. Aborting backup." $true
    $zipok = $false
  }

  
  if ($zipok) {
    Write-Log "Archiving operation successfully finished." $true
    # Archiving operation was successful, we now need to send files to the S3 Storage.
    Write-Log "Ready to upload files to S3 Storage bucket $s3bucketname, folder $s3foldername ." $true
    Write-Log "Uploading files:" $true
    $filestoupload = Get-ChildItem $backupfolder -Filter "*.7z"
    $totalsize = 0
    foreach ($filetoupload in $filestoupload) {
      $totalsize = $totalsize + $filetoupload.Length
      Write-Log ("`t"+$filetoupload.Name) $false
    }
    # S3Sync.exe seems to be very sensitive to running environment, so we can't use Measure-Command to measure
    # upload time.
    $uploadstart = Get-Date
    & $s3syncfilepath -AWSAccessKeyId $s3accesskey -AWSSecretAccessKey $s3secretkey -SyncDirection "upload" -LocalFolderPath $backupfolder -IncludeLocalSubFolders "False" -IncludeOnlyLocalFilesRegularExpression ".*\.7z$" -BucketName $s3bucketname -S3FolderKeyName $s3foldername -DeleteS3ItemsWhereNotInLocalList "False"
    $uploadend = Get-Date
    # Detect errors from S3Sync.
    if ($LASTEXITCODE -eq 0) {
      $totalsize = "{0:N2}" -f ($totalsize/1MB)
      $uploadtime = ($uploadend - $uploadstart).TotalSeconds
      $uploadtime = "{0:N0}" -f ($uploadtime)
      Write-Log "Upload finished. Uploaded $totalsize MB in $uploadtime seconds." $true
    } else {
      Write-Log "ERROR: Upload to Amazon S3 Storage terminated with exit code $LASTEXITCODE. Aborting backup." $true
      $syncok = $false
    }
  } 
} else {
  Write-Log "ERROR: Server still running after $shutdowntimeout. Aborting backup." $true
}


# Stop the job clock, the rest is going to take less than a second.
$jobend = Get-Date
$jobtime = ($jobend - $jobstart).TotalMinutes
$jobtime = "{0:N2}" -f $jobtime

# Now we need to examine exit codes and wrap-up the backup job.
if ($shutdownok -and $startupok -and $syncok -and $zipok) {
  $jobstatus = "SUCCESS"
} elseif ($syncok) {
  $jobstatus = "FAIL_CLEAR"
} else {
  $jobstatus = "FAIL_LEAVE"
}

if ($jobstatus -eq "SUCCESS") {
  # Everything OK, clear all temporary files.
  Clear-Backup-Folder
  Write-Log "Backup job finished SUCCESSFULLY after $jobtime minutes." $true
  Exit 0
} elseif ($jobstatus -eq "FAIL_CLEAR") {
  # Some of the operations failed, but upload was OK. Clear all temporary files.
  Clear-Backup-Folder
  Write-Log "Some operations reported errors. Please examine the log carefully to see what went wrong." $true
  Write-Log "`tBackup job did NOT finish successfully after $jobtime minutes."
  Exit 1
} else {
  # Some of the operations failed, we'll leave archive files if any.
  Clear-Backup-Folder "*.7z"
  Write-Log "Some operations reported errors. Please examine the log carefully to see what went wrong." $true
  Write-Log "`tBackup job did NOT finish successfully after $jobtime minutes."
  Exit 2
}

