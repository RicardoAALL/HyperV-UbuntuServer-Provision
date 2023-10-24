# HyperV-UbuntuServer-Provision

## Description

A small script to create and provision new HyperV Virtual Machines using the most recent LTS of Ubuntu Server with cloud-init.

[hyperv-vm-provision](https://github.com/schtritoff/hyperv-vm-provisioning/blob/master/New-HyperVCloudImageVM.ps1) was used as a reference and inspiration.

## Requirements

First and foremost, you must run this script as an administrator. Attempting to run it with user privileges will throw an error.

In order for this script to work properly you must also have:
- [QEMU](https://cloudbase.it/qemu-img-windows/)
- [oscdimg](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) (Part of the Windows Assessment and Deployment Kit)

Both of these tools will be automatically installed. 

You will also need an SSH key. If you do not have one, then use the following command to generate one `ssh-keygen -t ed25519 -C "your_email@example.com"`.

Once you have obtained an SSH Key, you can pass it to the script using `-PublicSSHKey`.

The `-VMName` parameter is mandatory.

## Defaults

This script creates a basic, barebones Ubuntu Server VM with the following defaults if not specified:
- **System**:
  - *root folder*: $HOME\VM
- **VM**
  - *storage*: 25G
  - *RAM*: 4G
  - *network switch*: Default Switch
- **Admin User**
  - *username*: user
  - *password*: passw0rd!
- **SSH**
  - *port*: 4444
- **Network (static ip)**:
  - *ipv4 address*: 192.168.1.x where x is 100 + number of directories in the root folder.
  - *default gateway*: 192.168.1.1
  - *dns*: 8.8.8.8
  - *subnet mask*: 255.255.255.0
 
## Example Usage

`New-UbuntuServerVM -VMName "Web Server"`

Creates a new VM named "Web Server". Use default values of 25 gigabytes of storage, 4 gigabytes of RAM, a network switch called "Default Switch", SSH Port at 4444 and root folder path of $HOME\VM

`New-UbuntuServerVM -VMName "Web Server" -RootFolder C:\ -VMHardDiskSize = 50G -VMRamSize 8G -VMSwitch "Virtual Switch"`

Creates a new VM named "Web Server" with root folder at C:\\, 50 gigabytes of storage, 8 gigabytes of RAM and a network switch called "Virtual Switch". Use default values for SSH Port (4444).
