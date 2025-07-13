sudo ./tools/kernel_flash/l4t_initrd_flash.sh  \
--no-flash \
-u ~/keyvault/ecp521.pem -v ~/keyvault/sbk.key \
--uefi-keys ~/keyvault/uefi_keys/uefi_keys.conf \
--uefi-enc ~/keyvault/gen_ekb/sym_t234.key \
--network usb0 \
--showlogs \
-p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
jetson-orin-nano-devkit-super internal

sudo ROOTFS_ENC=1 ./tools/kernel_flash/l4t_initrd_flash.sh \
    --no-flash \
    --showlogs \
    --network usb0 \
    --external-device nvme0n1p1 \
    -u ~/keyvault/ecp521.pem -v ~/keyvault/sbk.key \
    --uefi-keys ~/keyvault/uefi_keys/uefi_keys.conf \
    --uefi-enc ~/keyvault/gen_ekb/sym_t234.key \
    -c ./tools/kernel_flash/flash_l4t_t234_nvme_rootfs_enc.xml -S 474GiB \
    --external-only \
    --append \
    -i ~/keyvault/gen_ekb/sym2_t234.key \
    jetson-orin-nano-devkit-super \
    external

sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    -u ~/keyvault/ecp521.pem -v ~/keyvault/sbk.key \
    --uefi-keys ~/keyvault/uefi_keys/uefi_keys.conf \
    --uefi-enc ~/keyvault/gen_ekb/sym_t234.key \
    --network usb0 \
    --showlogs \
    --flash-only
