param (
  [string] [Parameter(Mandatory=$true)] $VMName,
  [object] $VMHardDiskSize = 25GB,
  [object] $VMRamSize = 4GB,
  [string] $VMSwitch = "Default Switch",
  [string] $VMCPUCount = 1,
  [bool] $VMDynamicMemory,
  [string] $RootFolder = "$HOME\VM",
  [string] $PublicSSHKey,
  [int] $SSHPort = 4444
)

[string] $working_directory = "$RootFolder\$VMName"
[string] $metadata_iso = "$working_directory\metadata.iso"
[string] $qemu_folder = "C:\Program Files\qemu-img"
[string] $qemu_file = "$qemu_folder\qemu-img.exe"
[string] $oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
[string] $oscdimg_file = "$oscdimg\oscdimg.exe"

[hashtable] $Ubuntu = @{
  Name = ""
  Version = "";
  Type = "live-server";
  Arch = "amd64"
}

#Requires -RunAsAdministrator

Write-Host $PublicSSHKey

# Check if SSH Key exists
if (!($PSBoundParameters.ContainsKey('PublicSSHKey')) -and ($null -eq $env:PublicSSHKey)) {
  throw "PublicSSHKey was not passed to the script or set as an environment variable."
}

# Create root VM folder
if (Test-Path $RootFolder) {
  Write-Host "$RootFolder already exists. Continuing..."
} else {
  New-Item -ItemType Directory -Force -Path $RootFolder
}

# Create folder for VM files
if (Test-Path $working_directory) {
  throw "$working_directory already exists. Either delete it or use a different value for the 'VMName' parameter."
} else {
  New-Item -ItemType Directory -Force -Path $working_directory
}

# Download qemu (used to convert iso to img) if not found
if (Test-Path $qemu_file) {
  Write-Host "qemu-img already installed"
} else {
  $qemu_download = "$env:temp\qemu-img.zip"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -URI "https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip" -OutFile $qemu_download
  Expand-Archive -LiteralPath $qemu_download -DestinationPath $qemu_folder
  Write-Host "qemu-img downloaded to: $qemu_folder"
}

# Download Windows ADK (oscdimg.exe - used to create ) if not found
if (Test-Path $oscdimg_file) {
  Write-Host "Windows ADK (oscdimg.exe) already installed"
} else {
  $adk_download = "$env:temp\adksetup.exe"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -URI "https://go.microsoft.com/fwlink/?linkid=2196127" -OutFile $adk_download
  & $adk_download /quiet /features OptionId.DeploymentTools
  Write-Host "Windows ADK (oscdimg.exe) downloaded to: $qemu_folder"
}

# Download Ubuntu Server LTS if not found
$lts_file = "$env:temp\lts.txt"
if (!(Test-Path $lts_file)) {
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -URI "https://changelogs.ubuntu.com/meta-release-lts" -OutFile $lts_file
  Write-Host "Retrieving list of Ubuntu Server LTS's..."
}

$lts = Get-Content $lts_file | Select-String -Pattern "Version:" | Select-Object -Last 1
$Ubuntu['Version'] = ($lts -split " ")[1]

$lts = Get-Content $lts_file | Select-String -Pattern "Name:" | Select-Object -Last 1
$Ubuntu['Name'] = ($lts -split " ")[1]

$LTSVersion = $Ubuntu['Version']
Write-Host "Latest LTS version: $LTSVersion"

$LTSName = $Ubuntu['Name'].ToString().ToLower()
Write-Host "Latest LTS Name: $LTSName"

# Download latest Ubuntu Server LTS ISO
$ubuntu_download_url = "https://cloud-images.ubuntu.com/${LTSName}/current/${LTSName}-server-cloudimg-amd64.img"
$ubuntu_img_filename = "ubuntu-${LTSVersion}.img"
$ubuntu_download_path =  "$RootFolder\$ubuntu_img_filename"
if (Test-Path $ubuntu_download_path) {
  Write-Host "file already exists: $ubuntu_download_path"
} else {
  Write-Host "Downloading file from $ubuntu_download_url"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -URI $ubuntu_download_url -OutFile $ubuntu_download_path
  Write-Host "Saved file to $ubuntu_download_path"
}

# Copy Ubuntu ISO from root folder to VM working directory
Copy-Item $ubuntu_download_path -Destination $working_directory -Force
Write-Host "Placed copy into: $working_directory"

# Create ISO from cloud-init configs (meta-data, user-data)
# https://cloudinit.readthedocs.io/en/latest/reference/examples.html#yaml-examples
$metadata_dir = "$env:temp\vm-metadata"

$vm_hostname = $VMName.Replace(" ", "-").ToLower();
$date = (Get-Date).ToUniversalTime()
$metadata = @"
instance-id: $vm_hostname-$date
local-hostname: $vm_hostname
"@

$host_address = (Get-ChildItem -Directory $RootFolder).Count + 100;
$subnet_mask = 24;
$userdata = @"
#cloud-config

users:
  - name: user
    lock_passwd: false
    plain_text_passwd: passw0rd!
    ssh-authorized-keys:
      - $PublicSSHKey
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
runcmd:
  - sed -i -e '/^Port/s/^.*$/Port $SSHPort/' /etc/ssh/sshd_config
  - sed -i -e '/^PermitRootLogin/s/^.*$/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i -e 'user' /etc/ssh/sshd_config
  - restart ssh
  - rm /etc/netplan/50-cloud-init.yaml
  - netplan generate
  - netplan apply
write_files:
  - path: /etc/ssh/sshd_config
    content: |
          Port $SSHPort
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
          AllowUsers user
  - path: /etc/cloud/cloud.cfg.d/99-custom-networking.cfg
    permissions: '0644'
    content: |
      network: {config: disabled}
  - path: /etc/netplan/network-config.yaml
    permissions: '0644'
    content: |
      network:
        ethernets:
          eth0:
            addresses: [192.168.1.$host_address/$subnet_mask]
            gateway4: 192.168.1.1
            dhcp4: Off
            nameservers:
              addresses: [8.8.8.8]
            optional: true
        version: 2
"@
Write-Host "VM IP: 192.168.1.$host_address/$subnet_mask"

New-Item -ItemType Directory -Force -Path $metadata_dir
Set-Content "$metadata_dir\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
Write-Host "Writing meta-data to: $metadata_dir\meta-data"
Set-Content "$metadata_dir\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte
Write-Host "Writing user-data to: $metadata_dir\user-data"

& $oscdimg_file "$metadata_dir" $metadata_iso -j2 -lcidata

# Convert VMDK to VHDX
$ubuntu_vhdx = $ubuntu_download_path -replace ".img", ".vhdx"
if (Test-Path $ubuntu_vhdx) {
  Write-Host "VHDX file exists: $ubuntu_vhdx"
} else {
  Write-Host "converting .img file to .vhdx"
  & "$qemu_file" convert -f qcow2 $ubuntu_download_path -O vhdx -o subformat=dynamic $ubuntu_vhdx
  Write-Host "converted file at: $ubuntu_vhdx"
}

# Copy Ubuntu VHDX from root folder to VM working directory
Copy-Item $ubuntu_vhdx -Destination $working_directory -Force
Write-Host "Placed copy into: $working_directory"

# Create VM
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
  throw "VM exists: $VMName"
}
Write-Host "Creating new Ubuntu VM: $VMName"

New-VM -VHDPath "$working_directory\ubuntu-$LTSVersion.vhdx" -Name $VMName -Generation 2 -MemoryStartupBytes $VMRamSize -SwitchName $VMSwitch
Set-VMProcessor -VMName $VMName -Count $VMCPUCount
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $VMDynamicMemory
Set-Vm -Name $VMName
Write-Host "Finished creating VM: $VMName"

# Resize VHD to more reasonable size (as in greater than 3gb)
Resize-VHD -Path "$working_directory\ubuntu-$LTSVersion.vhdx" -SizeBytes $VMHardDiskSize

# Set boot drive
$disks = (Get-VMDvdDrive -VMName $VMName).Path
foreach ($disk in $disks) {
  if ($disks -eq $metadata_iso) {
    Write-Host "VM DVD Drive alread exists: $disk"
    break
  }
}
Write-Host "Setting VMDvdDrive: $metadata_iso"
Add-VMDvdDrive -VMName $VMName -Path $metadata_iso

# Set boot order
$disks = (Get-VMDvdDrive -VMName $VMName)
$index = 0
foreach ($disk in $disks.Path) {
  if ($disk -eq "$working_directory\metadata.iso") {
    Write-Host "found: $disk"
    break
  }
  $index += 1
}
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -FirstBootDevice $disks[$index]

# Start VM
Start-VM -VMName $VMName
