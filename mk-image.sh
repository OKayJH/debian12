#!/bin/bash -e

TARGET_ROOTFS_DIR=./binary

if [ $RK_ROOTFS_IMAGE ]; then
	ROOTFSIMAGE=$RK_ROOTFS_IMAGE
else
	ROOTFSIMAGE=linaro-$SOC-$TARGET-rootfs.img
fi

echo Making rootfs!

if [ -e ${ROOTFSIMAGE} ]; then
	rm -f ${ROOTFSIMAGE}
fi

# for script in ./post-build.sh ../device/rockchip/common/post-build.sh; do
# 	[ -x $script ] || continue
# 	sudo $script "$(realpath "$TARGET_ROOTFS_DIR")"
# done

sudo ./add-build-info.sh ${TARGET_ROOTFS_DIR}

# Apparent size + maxium alignment(file_count * block_size) + maxium journal size
IMAGE_SIZE_MB=$(( $(sudo du --apparent-size -sm ${TARGET_ROOTFS_DIR} | cut -f1) + \
	$(sudo find ${TARGET_ROOTFS_DIR} | wc -l) * 4 / 1024 + 64 ))

# Extra 10%
IMAGE_SIZE_MB=$(( $IMAGE_SIZE_MB * 110 / 100 ))

sudo mkfs.ext4 -m 0 -d ${TARGET_ROOTFS_DIR} ${ROOTFSIMAGE} ${IMAGE_SIZE_MB}M

# Shrink to minimum and reserve 32MB free space for root emergency
sudo resize2fs -M ${ROOTFSIMAGE}
BLOCK_SIZE=$(sudo tune2fs -l ${ROOTFSIMAGE} | grep "Block size" | awk '{print $3}')
BLOCKS_32MB=$((32 * 1024 * 1024 / BLOCK_SIZE))
TOTAL_BLOCKS=$(sudo tune2fs -l ${ROOTFSIMAGE} | grep "Block count" | awk '{print $3}')
sudo resize2fs ${ROOTFSIMAGE} $((TOTAL_BLOCKS + BLOCKS_32MB))
sudo tune2fs -r ${BLOCKS_32MB} ${ROOTFSIMAGE}

echo Rootfs Image: ${ROOTFSIMAGE}
