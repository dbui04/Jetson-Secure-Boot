// #show link.where(body: []): l => {
//   let heading-elem = query(l.dest).first()
//   link(l.dest, heading-elem.body)
// }
#align(center, text(17pt)[
  *Secure Boot and Disk Encryption on Jetson Orin devices*
])

This document was created on the basis of the official [NVIDIA developer guide for NVIDIA Jetson Linux version 36.4.4 GA](https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/index.html)

The (my own) scripts and configuration files to enable secure boot can be found in this directory

= Overview
- Secure Boot prevents unauthorized code from running on the device.
- NVIDIA SoCs contain multiple #link(<fuses>)[*fuses*] that control different items for security and boot.
  - Specific fuses need to be burned to enable Secure Boot.
- The root-of-trust that uses the fuses to authenticate the boot process begins from the BootRom and ends at the Bootloader. After this, the current Bootloader (UEFI) will use its own scheme to authenticate its payload (UEFI Secure Boot).
- Disk encryption should be enabled only when Secure Boot is enabled to be fully protected against physical tampering.

= Secure Boot

Prerequisites:
- An x86 host running ubuntu 22.04 LTS.
- `libftdi-dev` for USB debug port support.
- `openssh-server` package for OpenSSL.
- Refer to #link("https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/IN/QuickStart.html")[*Quick Start*] to set up the host.

Overall process:
- Generate a #link(<pkc>)[*PKC*] key pair.
- Prepare an #link(<sbk>)[*SBK*] key.
- Prepare the #link(<oem_k1>)[*K1*] key.
- Prepare #link(<ekb>)[*EKB*]
- Prepare the #link(<fuse_config_file>)[*Fuse Configuration file*].
- #link(<burn_fuses>)[*Burn fuses*] using `odmfuse.sh` script with a Fuse Configuration file.
- Sign the image and flash the device with `l4t_initrd_flash.sh`.

== Fuses <fuses>
- Fuses are one-time programmable components of the SoC. That means once a fuse bit is set to 1, it cannot be changed back to 0. Therefore, *be careful when burning fuses* since the process cannot be reversible.
- The flashing script can take in arguments in the form `fuse_name=value`, or read from a fuse configuration file (preferred).
- Some notable fuses:
  - `PublicKeyHash`:
    - Size: 64 bytes
    - Stores the hash of the #link(<pkc>)[*Public Key Certificate (PKC)*].
  - `SecureBootKey`:
    - Size: 32 bytes
    - Stores the #link(<sbk>)[*Secure Boot Key (SBK)*].
  - `OemK1`, `OemK2`:
    - Size: 32 bytes
    - Stores the #link(<oem_k1>)[*K1/K2 keys*]. We only use K1 key here for Secure Boot, so K2 can be ignored. The K1 key is used as the #link(<ekb>)[*EKB*] fuse key.
  - `BootSecurityInfo`:
    - Size: 4 bytes
    - Denote which fuses have been burned and activated. Be careful to calculate this value correctly or else the boot process may not work as expected or it might even brick the device. To derive the correct value, refer to the fuse specs sheet link in the official document.
    - As of 2025, Jetson SoCs will have the `BootSecurityInfo` fuse with the *default value of `0x1E0`*. Therefore, remember to bitwise-OR whatever value you calculated to this default value to get the correct value of the fuse.
    - For the example we're gonna use in this document, we burn the PKC fuse using a ECDSA P-521 key, the SBK fuse, and the OemK1 fuse. The official document shows that the `BootSecurityInfo` for this configuration was `0x20b`. However, this value is not correct for Jetson Orin devices manufactured in 2025 and onwards, as we should take `0x1e0` OR `0x20b`, which gives the correct value of *`0x3eb`*.
  - `SecurityMode`:
    - Size: 4 bytes
    - Can only be burned to `0x1`.
    - You cannot write to fuses anymore after this fuse is burned.
  - Some debug fuses that can be disabled for production devices: `ArmJtagDisable`, `CcplexDfdAccessDisable`, `DebugAuthentication`
=== Fuse Configuration file <fuse_config_file>
- Is a XML file containing info about fuses to be burned.
- A template of the file can be found in this directory.

== Public Key Certificate (PKC) <pkc>
- This is a public/private key pair used to sign the bootloader and other components (kernel, DTB). The hash of the public key is burned into the `PublicKeyHash` fuse.
- Each component is signed with the private key; at boot, the BootRom checks the signature of the components against the public key hash stored in the fuse, and proceeds the boot process only if the signature is valid.
- The security of the device depends on how securely you store the key files.
- If the `PublicKeyHash` fuse has already been burned, the PKC is required in order to re-flash the device.
- Jetson Orin series support 3 types of PKC: RSA 3K, ECDSA P-256, and ECDSA P-521.
  - ECDSA provides better authentication performance and security with smaller key size than RSA.
  - *ECDSA P-521* provides best security. The performance overhead vs ECDSA P-256 is negligible given the Orin series' hardware.
=== Generate a PKC key pair
- I recommend using ECDSA P-521.
- To generate a ECDSA P-521 key:
```
openssl ecparam -name secp521r1 -genkey -noout -out ecp521.pem
```
- To generate the hash of the public key, use `tegrasign_v3.py` from `Linux_for_Tegra/bootloader/` :
```
./tegrasign_v3.py --pubkeyhash <pkc.pubkey> <pkc.hash> --key <pkc.pem>
```
The sample output from the official document:
```
$ ./tegrasign_v3.py --pubkeyhash ecp521.pubkey ecp521.hash --key ecp521.pem
  Valid ECC key. Key size is 521
  Valid ECC key. Key size is 521
  Saving public key in ecp521.pubkey for ECC
  Sha saved in pcp.sha
  tegra-fuse format (big-endian): 0x9f0ebf0aec1e2bb30c0838096a6d9de5fb86b1277f182acf135b081e345970167a88612b916128984564086129900066255a881948ab83bebf78c7d627f8fe84
```
The hexadecimal value shown in the output can be used directly as the `PublicKeyHash` fuse data of the Fuse Configuration file.


== Secure Boot Key (SBK) <sbk>
- This key is used to encrypt bootloader components, prevent attackers from reading, and possibly, modifying them to compromise the boot process.
  - Without the PKC, an attacker theoretically cannot re-flash the device. However, if a SBK is not used, the attacker can still read (reverse-engineer) the unencrypted bootloader binaries to look for vulnerabilities for more sophisticated attacks.
- The Orin SoC requires a SBK of eight 32-bit words (32 bytes / 256 bits). The SBK file is stored in big-endian hexadecimal format.
- To generate one, use:
```
openssl rand -hex 32 > sbk.key
```
- For example, the generated SBK is
```
123456789abcdef0fedcba9876543210
```
then in the fuse configuration file, we set the `SecureBootKey` fuse value to
```
0x123456789abcdef0fedcba9876543210
```


== K1/K2 Keys (OemK1/OemK2) <oem_k1>
- We ignore the K2 key in this guide.
- The K1 key is used as the #link(<ekb>)[*EKB*] fuse key.
- This key is also 32 bytes, so in order to generate it:
```
openssl rand -hex 32 > oem_k1.key
```
- Set the `OemK1` value in the fuse configuration file to `0x<oem_k1.key>`
For example, if the content of `oem_k1.key` is
```
112233445566778899aabbccddeeff00ffeeddccbbaa99887766554433221100
```
then the value of `OemK1` is
```
0x112233445566778899aabbccddeeff00ffeeddccbbaa99887766554433221100
```
== Encrypted Key Blob (EKB) <ekb>
- This is a block of data on the Jetson's storage containing other keys.
- The EKB fuse key (the K1 key) is used to derive the encryption and authentication keys of the EKB.
- Imagine it like a digital safe to store important keys like the LUKS key for disk encryption or other sensitive data.
- Without EKB, important data would be stored in plain text, leaving it vulnerable to attackers with physical access to the device.
- In order to generate a EKB image, use the `gen_ekb` tool in this directory. The `example.sh` script generates necessary keys and use them in conjunction with the K1 key burned to the fuse to generate the EKB image.
  - Remember to locate the correct path of the `OemK1.key` file in the script.
- Copy the EKB image to the `<Linux_for_Tegra>/bootloader` folder on the host.

== Burn fuses with the Fuse Configuration file <burn_fuses>
- The command is:
```
sudo ./odmfuse.sh -X <fuse_config> -i <chip_id> <target_config>
```
  - `<fuse_config>`: The fuse configuration XML file
  - `<pkc.pem>`: is the PKC key pair (`.pem` file)
  - `<chip_id>`: `0x23` for Jetson Orin devices
  - `<target config>`: is the name of the configuration for the Jetson device and carrier board. See the table in #link("https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/IN/QuickStart.html#in-quickstart-jetsonmodulesandconfigurations")[*Jetson Modules and Configurations*]
For example:
```
sudo ./odmfuse.sh -X fuses.xml -i 0x23 jetson-orin-nano-devkit-super
```

== Sign and flash secured image <flash>
- The bootloader components (flashed into QSPI) will need to be signed witk PKC and encrypted with SBK.
- It is recommended to also enable #link(<uefi_secure_boot>)[*UEFI Secure Boot*].
- Also, refer to the #link(<disk_encryption>)[*Disk Encryption*] section to setup the NVMe partition table used by the flashing script.
- The template flashing script `disk_enc.sh` <flashing_script> in this directory is for Jetson Orin Nano Super devices with a NVMe, enabling Secure Boot, UEFI Secure Boot and Disk Encryption.

= UEFI Secure Boot <uefi_secure_boot>
- Uses digital signatures (RSA) to validate the authenticity and integrity of the codes that it loads.
- UEFI Secure Boot implementations use PK, KEK and db keys:
  - Platform Key (PK): Top-level key, used to sign KEK
  - Key exchange key (KEK): Key used to sign the Signature Database
  - Signature Database (db): Contain keys to sign the UEFI payloads.
- The process to enable UEFI Secure Boot:
  - Prepare the PK, KEK, and db RSA key pairs, their certificates, and the EFI signature list files:
```
cd to <LDK_DIR>
mkdir uefi_keys
cd uefi_keys
GUID=$(uuidgen)

openssl req -newkey rsa:2048 -nodes -keyout PK.key  -new -x509 -sha256 -days 3650 -subj "/CN=my Platform Key/" -out PK.crt
cert-to-efi-sig-list -g "${GUID}" PK.crt PK.esl

openssl req -newkey rsa:2048 -nodes -keyout KEK.key  -new -x509 -sha256 -days 3650 -subj "/CN=my Key Exchange Key/" -out KEK.crt
cert-to-efi-sig-list -g "${GUID}" KEK.crt KEK.esl

openssl req -newkey rsa:2048 -nodes -keyout db_1.key  -new -x509 -sha256 -days 3650 -subj "/CN=my Signature Database key/" -out db_1.crt
cert-to-efi-sig-list -g "${GUID}" db_1.crt db_1.esl

openssl req -newkey rsa:2048 -nodes -keyout db_2.key  -new -x509 -sha256 -days 3650 -subj "/CN=my another Signature Database key/" -out db_2.crt
cert-to-efi-sig-list -g "${GUID}" db_2.crt db_2.esl
```
  - Create a UEFI config file `uefi_keys.conf`:
```
#Use the correct path for these files
UEFI_DB_1_KEY_FILE="db_1.key";  # UEFI payload signing key
UEFI_DB_1_CERT_FILE="db_1.crt"; # UEFI payload signing key certificate

UEFI_DEFAULT_PK_ESL="PK.esl"
UEFI_DEFAULT_KEK_ESL_0="KEK.esl"

UEFI_DEFAULT_DB_ESL_0="db_1.esl"
UEFI_DEFAULT_DB_ESL_1="db_2.esl"
```

  - Generate `UefiDefaultSecurityKeysUefiDefaultSecurityKeys.dtbo` and the auth files.
```
sudo tools/gen_uefi_keys_dts.sh <uefi_keys.conf path>
```
  - Generate the #link(<ekb>)[*EKB*] with the `example.sh` script and copy the image to `<Linux_for_Tegra>/bootloader` basically allows enabling both #link("https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/SD/Security/SecureBoot.html#sd-security-secureboot-uefipayloadencryption")[*UEFI Payload Encryption*] and #link("https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/SD/Security/SecureBoot.html#sd-security-secureboot-uefivariableprotection")[*UEFI Variable Encryption*].
  - Flash the device with the script specified #link(<flashing_script>)[*above*].

= Disk Encryption <disk_encryption>
- The disk encryption key is generated and stored in the #link(<ekb>)[*EKB*] when flashed (only if specified, which the `example.sh` script does). Therefore the encrypted disk can be safely unlocked automatically by the bootloader by reading from the EKB in the secure world.
- The #link(<flashing_script>)[*flashing script*] mentioned above uses a dedicated partition table for the NVMe, specified in the `flash_l4t_t234_nvme_rootfs_enc.xml` file in this directory. Remember to double-check this file's path in the flashing script.
  - Also, double-check the `num_sectors` field in this file. The value is related to the size of the NVMe. To determine this value (on Linux):
    - `sudo fdisk -l` and find the device name (e.g. `/dev/nvme0n1p1`)
    - For example, if the device is `/dev/nvme0n1p1`, use:
    ```
    sudo blockdev --getsize64 /dev/nvme0n1p1
    ```
    This will return a large number. For example: 512110190592 for a 512GB SSD.
    - `num_sectors` = (Total Bytes / Sector Size) (round down if floating point number)
    For example, the sector size as specified in the partition table file (right above the `num_sectors` field in the file) is 512, therefore the `num_sectors` value is 512110190592/512 = 1000215216.

    i.e. `num_sectors="1000215216"`
