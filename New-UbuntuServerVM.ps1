param (
  [string] $DownloadFolder = "$HOME\VM",
  [string] [Parameter(Mandatory=$true)] $VMName,
  [bool] $CloudInit = $true,
  $VMHardDiskSize = 25GB,
  $VMRamSize = 4GB,
  [string] $VMSwitch = "Virtual Switch",
  [bool] $Provision = $true,
  [switch] $Delete
)

#Requires -RunAsAdministrator

[System.String] $qemu_folder = "C:\Program Files\qemu-img"
[System.String] $qemu_file = "$qemu_folder\qemu-img.exe"
[System.String] $oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
[System.String] $global:output_img = ""
[System.String] $metadataIso = "$DownloadFolder\metadata.iso"
[System.String] $workingDirectory = "$DownloadFolder\$VMName"

$Ubuntu = @{
  Name = "";
  Version = "";
  Type = "live-server";
  Arch = "amd64"
}

if (!(Test-Path $oscdimg)) {
  throw "oscdimg.exe could not be found. Please make sure it is installed - https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install"
}

$metadata = @"
instance-id: iid-123456
local-hostname: yuh-m
"@

$userdata = @"
#cloud-config

users:
  - name: admin
    lock_passwd: false
    plain_text_passwd: passw0rd!
    ssh-authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICewR4jtOkn+rjZDwRrXtANUCsTrOz0nSmpq2BIE607u ricardo.valdovinos@aall.net
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
runcmd:
  - sed -i -e '/^Port/s/^.*$/Port 4444/' /etc/ssh/sshd_config
  - sed -i -e '/^PermitRootLogin/s/^.*$/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i -e '$aAllowUsers demo' /etc/ssh/sshd_config
  - restart ssh
write_files:
  - path: /etc/ssh/sshd_config
    content: |
          Port 4444
          Protocol 2
          HostKey /etc/ssh/ssh_host_rsa_key
          HostKey /etc/ssh/ssh_host_dsa_key
          HostKey /etc/ssh/ssh_host_ecdsa_key
          HostKey /etc/ssh/ssh_host_ed25519_key
          UsePrivilegeSeparation yes
          KeyRegenerationInterval 3600
          ServerKeyBits 1024
          SyslogFacility AUTH
          LogLevel INFO
          LoginGraceTime 120
          PermitRootLogin no
          StrictModes yes
          RSAAuthentication yes
          PubkeyAuthentication yes
          IgnoreRhosts yes
          RhostsRSAAuthentication no
          HostbasedAuthentication no
          PermitEmptyPasswords no
          ChallengeResponseAuthentication no
          X11Forwarding yes
          X11DisplayOffset 10
          PrintMotd no
          PrintLastLog yes
          TCPKeepAlive yes
          AcceptEnv LANG LC_*
          Subsystem sftp /usr/lib/openssh/sftp-server
          UsePAM yes
          AllowUsers demo
"@

function main {
  if ($Delete) {
    Write-Host "Deleting: $workingDirectory"
    Remove-Item -Force -Recurse -Path "$workingDirectory"
    return
  }
  New-Root-Directory
  New-Working-Directory
  Get-Required-Tools
  Get-Latest-Ubuntu-LTS
  $img_file = Get-Ubuntu
  if ($Provision) {
    Convert-VMDK-To-VHDX $img_file
    Set-CloudInit
  }
  New-Ubuntu-VM
  Set-Boot-ISO
  Set-Boot-Order
  Start-Ubuntu-VM
}

function New-Root-Directory {
  New-Item -ItemType Directory -Force -Path $DownloadFolder
}

function New-Working-Directory {
  New-Item -ItemType Directory -Force -Path "$DownloadFolder\$VMName"
}

function Get-Required-Tools {
  if (Test-Path $qemu_file) {
    Write-Host "qemu-img already installed"
    return
  }
  $qemu_download = "$env:temp\qemu-img.zip"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -URI "https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip" -OutFile $qemu_download
  Expand-Archive -LiteralPath $qemu_download -DestinationPath $qemu_folder
  Write-Host "qemu-img downloaded to: $qemu_folder"
}

function Get-Latest-Ubuntu-LTS {
  $lts_file = "$env:temp\lts.txt"
  if (!(Test-Path $lts_file)) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -URI "https://changelogs.ubuntu.com/meta-release-lts" -OutFile $lts_file
    Write-Host "retrieving latest Ubuntu LTS"
  }

  $lts = Get-Content $lts_file | Select-String -Pattern "Version:" | Select-Object -Last 1
  $Ubuntu['Version'] = ($lts -split " ")[1]

  $lts = Get-Content $lts_file | Select-String -Pattern "Name:" | Select-Object -Last 1
  $Ubuntu['Name'] = ($lts -split " ")[1]

  $LTSVersion = $Ubuntu['Version']
  Write-Host "Latest LTS version: $LTSVersion"

  $LTSName = $Ubuntu['Name']
  Write-Host "Latest LTS Name: $LTSName"
}

function Get-Ubuntu {
  $LTSVersion = $Ubuntu['Version']
  $LTSName = $Ubuntu['Name'].ToString().ToLower()
  $LTSType = $Ubuntu['Type']
  $LTSArch = $Ubuntu['Arch']

  $file_name = "ubuntu-${LTSVersion}.iso"
  $download_url = "https://releases.ubuntu.com/${LTSVersion}/ubuntu-${LTSVersion}-${LTSType}-${LTSArch}.iso"
  if ($Provision) {
    $download_url = "https://cloud-images.ubuntu.com/${LTSName}/current/${LTSName}-server-cloudimg-amd64.img"
    $file_name = $file_name -replace ".iso", ".img"
  }

  $download_file =  "$DownloadFolder\$file_name"
  if (Test-Path $download_file) {
    Write-Host "file already exists: $download_file"
  } else {
    Write-Host "Downloading file from $download_url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -URI $download_url -OutFile $download_file
    Write-Host "Saved file to $download_file"
  }
  Copy-Item $download_file -Destination $workingDirectory -Force
  Write-Host "Placed copy into: $workingDirectory"
  return "$download_file"
}

function Set-CloudInit {
  $metadata_dir = "$env:temp\vm-metadata"

  New-Item -ItemType Directory -Force -Path $metadata_dir
  Set-Content "$metadata_dir\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
  Write-Host "Writing meta-data to: $metadata_dir\meta-data"
  Set-Content "$metadata_dir\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte
  Write-Host "Writing user-data to: $metadata_dir\user-data"

  & $oscdimg "$metadata_dir" $metaDataIso -j2 -lcidata
  Copy-Item $metaDataIso -Destination $workingDirectory -Force
  Write-Host "Placed copy into: $workingDirectory"
}

function Convert-VMDK-To-VHDX  {
  param ($img_file)
  $global:output_img = $img_file -replace ".img", ".vhdx"
  if (Test-Path $output_img) {
    Write-Host "VHDX file exists: $output_img"
    Copy-Item $output_img -Destination $workingDirectory -Force
    Write-Host "Placed copy into: $workingDirectory"
    return
  }
  Write-Host "converting .img file to .vhdx"
  & "$qemu_file" convert -f qcow2 $img_file -O vhdx -o subformat=dynamic $output_img
  Write-Host "converted file at: $output_img"

  Copy-Item $output_img -Destination $workingDirectory -Force
  Write-Host "Placed copy into: $workingDirectory"
}

function New-Ubuntu-VM {
  $exists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if ($exists) {
    Write-Host "VM exists: $VMName"
    Remove-VM -VMName $VMName -Force
    return
  }
  Write-Host "Creating new Ubuntu VM: $VMName"
  if ($Provision) {
    $LTSVersion = $Ubuntu['Version']
    New-VM -VHDPath "$workingDirectory\ubuntu-$LTSVersion.vhdx" -Name $VMName -Generation 2 -MemoryStartupBytes $VMRamSize -SwitchName $VMSwitch
  } else {
    New-VM -NewVHDPath "$VMName.vhdx" -Name $VMName -NewVHDSizeBytes $VMHardDiskSize -Generation 2 -MemoryStartupBytes $VMRamSize -SwitchName $VMSwitch
  }
  Set-Vm -Name $VMName
  Write-Host "Finished creating VM: $VMName"
}

function Set-Boot-ISO {
  $disks = (Get-VMDvdDrive -VMName $VMName).Path
  foreach ($disk in $disks) {
    if ($disks -eq $metadataIso) {
      Write-Host "VM DVD Drive alread exists: $disk"
      return
    }
  }
  if ($Provision) {
    Write-Host "Setting VMDvdDrive: $metaDataIso"
    Add-VMDvdDrive -VMName $VMName -Path $metaDataIso
    return
  }
  Write-Host "Setting VM ISO: $DownloadFolder"
  Add-VMDvdDrive -VMName $VMName -Path $DownloadFolder
}

function Set-Boot-Order {
  $disks = (Get-VMDvdDrive -VMName $VMName)
  $index = 0
  foreach ($disk in $disks.Path) {
    if ($disk -eq $metadataIso) {
      Write-Host "found: $disk"
      break
    }
    $index += 1
  }
  Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -FirstBootDevice $disks[$index]
}

function Start-Ubuntu-VM {
  Start-VM -VMName $VMName
}

main
