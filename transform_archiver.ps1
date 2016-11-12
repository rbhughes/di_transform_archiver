$xform_repo_home = "\\xyz.net\shared\SandRidge\GeologyDept\Transform\aux_dir"
$xform_exes = "C:\DrillingInfo\Transform\5.1.0"
$periodic_backup_dir = "e:\transform_backups\weekly"
$vault_backup_dir = "e:\transform_backups\vault"
$backup_xml_file = "C:\DrillingInfo\Transform\5.1.0\backups.xml"

$backup_xml_repos = @()

$repo_days_ago = 50     # (days) backup repos modified within the last __ days
$periodic_too_old = 30  # (days) backups older than __ days are deleted


<#
R. Bryan Hughes | rbhughes@logicalcat.com | 303-949-8125

Archive Transform project repositories and store backups in two categories:

1. a "periodic" backup that archives all repositories with any files modified
within a user-defined ($repo_days_ago) time window

2. a "vault" backup that retains a single up-to-date archive of every 
repository.

To ensure that disk space doesn't just fill up, aged periodic backups are 
removed after a user-defined number of days ($periodic_too_old).


xform_repo_home     : network path containing Transform repositories
xform_exes          : installation path to Transform. Contains DBBackup.exe.
periodic_backup_dir : contains several periodic backups of only modified repos
vault_backup_dir    : contains single repo backup for each live repos
backup_xml_file     : xml file read by DBBackup.exe


* Beware! I do not love PowerShell. Use at your own risk. No warranty, etc.

* For simplicity, this script runs a .bat file to launch DBBackup.exe, as
  defined in Transform's System Administration guide (one line):

  "c:\DrillingInfo\Transform\5.1.0\DBBackup.exe -backupConfigFile 
    "C:\DrillingInfo\Transform\5.1.0\backups.xml"

* Why is Transform installed in C:\DrillingInfo? Because Windows UAC enforces
  super-triple-stupid protections on c:\program files, and I did not want to
  slog through super-triple-stupid incantations.

* Only tested on Server 2012 R2 + MySQL. Should work with Oracle too.

Here are the Task Scheduler settings from the Actions tab using a server-locked
"service account" that was also a member of the local Administrators group:

                  Action:  Start a program
          Program/script:  PowerShell.exe
Add arguments (optional):  -ExecutionPolicy Bypass .\transform_archiver.ps1 
     Start in (optional):  C:\DrillingInfo\Transform\5.1.0
#>



#----------
# Scan the live repositories folder (assume v:\transform\aux_dir\<REPO>)
# to collect a list of "live" repo directories.
#
Write-Host " "
Write-Host "Collecting list of live repos..."
$live_repos = Get-ChildItem $xform_repo_home | ? { $_.PSIsContainer }



#----------
# Check the vault to see if it is missing backups of any live repos and
# add the list of repos that need to be backed up.
#
$live_repo_names = $live_repos | % { $_.Name } | sort
$vault_repo_names = Get-ChildItem -recurse $vault_backup_dir |
  ? { $_.PSIsContainer } |
  % { $_.Name } | sort
foreach($live_repo in $live_repos | sort)
{
  if ($vault_repo_names -notcontains $live_repo.Name) {
    Write-Host "Adding repo missing from vault: " $live_repo
    $backup_xml_repos += $live_repo
  }
}



#----------
# Delete aged backups from the periodic backup location.
#
Write-Host "Deleting aged periodic backups..."
Get-ChildItem -Path $periodic_backup_dir -Recurse |
  Where { $_.LastWriteTime -lt (Get-Date).AddDays(-$periodic_too_old) } |
  Remove-Item -Force -Recurse



#----------
# Recurse each repo for any file-writes have occurred since $repo_days_ago. 
# If changes exist, write a row in the backups.xml file used by DBBackup.exe
#
foreach($repo in $live_repos)
{
  $latest = Get-ChildItem $repo.FullName -recurse | 
    ? { -not $_.PsIsContainer } |
    ? { $_.LastWriteTime -gt (Get-Date).AddDays(-$repo_days_ago) } | 
    sort LastWriteTime | 
    select -last 1
  if ($latest) {
    $do_backup = (Get-Item $latest.Directory).Parent.Name
    $backup_xml_repos += $do_backup
    #$modified_repos += $do_backup
  }
}
'<backups rootDir="' + $periodic_backup_dir + '">'     > $backup_xml_file
'  <mySQL host="OKC1TRA0001.SDRGE.NET" port="3306">'  >> $backup_xml_file
$backup_xml_repos = $backup_xml_repos | select -Unique
foreach ($row in $backup_xml_repos)
{
  Write-Host "Adding modified repo to backup xml: " $row
  '    <repository>' + $row + '</repository>'         >> $backup_xml_file
}
'  </mySQL>'                                          >> $backup_xml_file
'</backups>'                                          >> $backup_xml_file



#----------
# Trigger Transform's DBBackup.exe, which references the new .xml from above.
# Note that this pauses script execution until DBBackup finishes.
#
$bak = Join-Path $xform_exes "backup_runner.bat"
Write-Host "Running Transform DBBackup.exe..."
Start-Process -Wait -NoNewWindow -WorkingDirectory $xform_exes -FilePath $bak



#----------
# Replace repos in the vault with the latest copies from now and add repos
# that were missing from the vault
#
foreach ($new_repo in $backup_xml_repos)
{
  $old_vault_repo = Get-ChildItem -recurse $vault_backup_dir |
    ? { $_.PSIsContainer } |
    Where { $_.Name -eq $new_repo } |
    select -last 1 |
    %{ $_.FullName }

  $replacement_repo = Get-ChildItem -recurse $periodic_backup_dir | 
    ? { $_.PSIsContainer } |
    Where { $_.Name -eq $new_repo  } |
    sort LastWriteTime | select -last 1 |
    %{ $_.FullName }
  
  if ($old_vault_repo) {
    Write-Host "Deleting prior vault repo: " $old_vault_repo
    Get-ChildItem -Path $old_vault_repo -Recurse | Remove-Item -Force -Recurse
    Remove-Item $old_vault_repo -Force
  }

  if ($replacement_repo) {
    Write-Host "Adding repo to vault: " $replacement_repo
    Copy-Item -Recurse -Force $replacement_repo $vault_backup_dir
  }
  
}



Write-Host " "
Write-Host "Transform Archiver is Complete!"
Write-Host " "
