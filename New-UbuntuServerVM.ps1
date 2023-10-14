param (
  [string] $DownloadFolder = "$HOME",
  [string] [Parameter(Mandatory=$true)] $VMName,
  [bool] $CloudInit = $true,
  $VMHardDiskSize = 25GB,
  $VMRamSize = 4GB,
  [string] $VMSwitch = "Default Switch",
  [bool] $Provision = $true
)

#Requires -RunAsAdministrator

[System.String] $qemu_folder = "C:\Program Files\qemu-img"
[System.String] $qemu_file = "$qemu_folder\qemu-img.exe"
[System.String] $oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
[System.String] $global:output_img = ""
[System.String] $metadataIso = "$DownloadFolder\metadata.iso"

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
local-hostname: ubuntu-vm
"@

$userdata = @"
#cloud-config
password: passw0rd
runcmd:
 - [ useradd, -m, -p, "", dev ]
 - [ chage, -d, 0, dev ]
"@

function main {
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
  return $download_file
}

function Set-CloudInit {
  if (Test-Path $metaDataIso) {
    Write-Host "cloudinit ISO exists: $metaDataIso"
    return
  }
  $metadata_dir = "$env:temp\vm-metadata"

  New-Item -ItemType Directory -Force -Path $metadata_dir
  Set-Content "$metadata_dir\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
  Set-Content "$metadata_dir\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte

  & $oscdimg "$metadata_dir" $metaDataIso -j2 -lcidata
}

function Convert-VMDK-To-VHDX  {
  param ($img_file)
  $global:output_img = $img_file -replace ".img", ".vhdx"
  if (Test-Path $output_img) {
    Write-Host "VHDX file exists: $output_img"
    return
  }
  Write-Host "converting .img file to .vhdx"
  & "$qemu_file" convert -f qcow2 $img_file -O vhdx -o subformat=dynamic $output_img
  Write-Host "converted file at: $output_img"
}

function New-Ubuntu-VM {
  $exists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if ($exists) {
    Write-Host "VM exists: $VMName"
    return
  }
  Write-Host "Creating new Ubuntu VM: $VMName"
  if ($Provision) {
    New-VM -VHDPath $global:output_img -Name $VMName -Generation 2 -MemoryStartupBytes $VMRamSize -SwitchName $VMSwitch
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
  $VMComponent = ""
  $index = 0
  foreach ($disk in $disks.Path) {
    if ($disk -eq $metadataIso) {
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