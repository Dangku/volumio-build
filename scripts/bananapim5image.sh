#!/bin/sh

# Default build for Debian 32bit (to be changed to armv8)
ARCH="armv7"

while getopts ":v:p:a:" opt; do
  case $opt in
    v)
      VERSION=$OPTARG
      ;;
    p)
      PATCH=$OPTARG
      ;;
    a)
      ARCH=$OPTARG
      ;;
  esac
done

BUILDDATE=$(date -I)
IMG_FILE="Volumio-${VERSION}-${BUILDDATE}-bananapim5.img"

if [ "$ARCH" = arm ]; then
  DISTRO="Raspbian"
else
  DISTRO="Debian 32bit"
fi

echo "INFO Creating Image File ${IMG_FILE} with $DISTRO rootfs"
dd if=/dev/zero of=${IMG_FILE} bs=1M count=2800

echo "INFO Creating Image Bed"
LOOP_DEV=`losetup -f --show ${IMG_FILE}`

parted -s "${LOOP_DEV}" mklabel msdos
parted -s "${LOOP_DEV}" mkpart primary fat32 1 64
parted -s "${LOOP_DEV}" mkpart primary ext3 65 2500
parted -s "${LOOP_DEV}" mkpart primary ext3 2500 100%
parted -s "${LOOP_DEV}" set 1 boot on
parted -s "${LOOP_DEV}" print
partprobe "${LOOP_DEV}"
kpartx -s -a "${LOOP_DEV}"

BOOT_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p1`
SYS_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p2`
DATA_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p3`

if [ ! -b "${BOOT_PART}" ]
then
	echo "INFO ${BOOT_PART} doesn't exist"
	exit 1
fi

echo "INFO Creating boot and rootfs filesystems"
mkfs -t vfat -n BOOT "${BOOT_PART}"
mkfs -F -t ext4 -L volumio "${SYS_PART}"
mkfs -F -t ext4 -L volumio_data "${DATA_PART}"
sync

echo "INFO Preparing for the Bananapi M5 kernel/ platform files"
if [ -d ./platform-bananapi/bananapim5 ]
then
	echo "INFO Platform folder already exists - keeping it"
    # if you really want to re-clone from the repo, then delete the platform-bananapi folder
    # that will refresh all the bananapi platforms, see below
	cd platform-bananapi
	if [ -f bananapim5.tar.xz ]; then
	   echo "INFO Found a new tarball, unpacking..."
	   rm -r bananapim5
	   tar xfJ bananapim5.tar.xz
	   rm bananapim5.tar.xz
	fi
	cd ..
else
	echo "INFO Getting sthe Bananapi M5 files from repo"
	mkdir platform-bananapi
	cd platform-bananapi
	[ ! -f bananapim5.tar.xz ] || rm bananapim5.tar.xz
	wget https://raw.githubusercontent.com/Dangku/volumio-platform-bananapi/master/bananapim5.tar.xz
	echo "INFO Unpacking the Bananapi M5 platform files"
	tar xfJ bananapim5.tar.xz
	rm bananapim5.tar.xz
	cd ..
fi

echo "INFO Copying the bootloader"
dd if=platform-bananapi/bananapim5/u-boot/u-boot.bin of=${LOOP_DEV} conv=fsync,notrunc bs=512 seek=1
sync

echo "INFO Preparing for Volumio rootfs"
if [ -d /mnt ]
then
	echo "INFO /mount folder exist"
else
	mkdir /mnt
fi
if [ -d /mnt/volumio ]
then
	echo "INFO Volumio Temp Directory Exists - Cleaning it"
	rm -rf /mnt/volumio/*
else
	echo "INFO Creating Volumio Temp Directory"
	mkdir /mnt/volumio
fi

echo "INFO Creating mount point for the images partition"
mkdir /mnt/volumio/images
mount -t ext4 "${SYS_PART}" /mnt/volumio/images
mkdir /mnt/volumio/rootfs
mkdir /mnt/volumio/rootfs/boot
mount -t vfat "${BOOT_PART}" /mnt/volumio/rootfs/boot

echo "INFO Copying Volumio RootFs"
cp -pdR build/$ARCH/root/* /mnt/volumio/rootfs
echo "INFO Copying bananapim5 boot files"
cp platform-bananapi/bananapim5/boot/*boot.ini /mnt/volumio/rootfs/boot
cp platform-bananapi/bananapim5/boot/*.dtb /mnt/volumio/rootfs/boot
cp -dR platform-bananapi/bananapim5/boot/overlays /mnt/volumio/rootfs/boot
cp platform-bananapi/bananapim5/boot/config-* /mnt/volumio/rootfs/boot
cp platform-bananapi/bananapim5/boot/Image* /mnt/volumio/rootfs/boot
cp -pdR platform-bananapi/bananapim5/lib/firmware /mnt/volumio/rootfs/boot/lib

echo "INFO Copying bananapim5 performance tweaking"
cp platform-bananapi/bananapim5/etc/rc.local /mnt/volumio/rootfs/etc

echo "INFO Copying bananapim5 modules and firmware"
cp -pdR platform-bananapi/bananapim5/lib/modules /mnt/volumio/rootfs/lib/

sync

echo "INFO Preparing to run chroot for more bananapi-m5 configuration"
cp scripts/bananapim5config.sh /mnt/volumio/rootfs
cp scripts/initramfs/init.nextarm /mnt/volumio/rootfs/root/init
cp scripts/initramfs/mkinitramfs-custom.sh /mnt/volumio/rootfs/usr/local/sbin
#copy the scripts for updating from usb
wget -P /mnt/volumio/rootfs/root http://repo.volumio.org/Volumio2/Binaries/volumio-init-updater

mount /dev /mnt/volumio/rootfs/dev -o bind
mount /proc /mnt/volumio/rootfs/proc -t proc
mount /sys /mnt/volumio/rootfs/sys -t sysfs

echo $PATCH > /mnt/volumio/rootfs/patch

echo "UUID_DATA=$(blkid -s UUID -o value ${DATA_PART})
UUID_IMG=$(blkid -s UUID -o value ${SYS_PART})
UUID_BOOT=$(blkid -s UUID -o value ${BOOT_PART})
" > /mnt/volumio/rootfs/root/init.sh
chmod +x /mnt/volumio/rootfs/root/init.sh

if [ -f "/mnt/volumio/rootfs/$PATCH/patch.sh" ] && [ -f "config.js" ]; then
        if [ -f "UIVARIANT" ] && [ -f "variant.js" ]; then
                UIVARIANT=$(cat "UIVARIANT")
                echo "INFO Configuring variant $UIVARIANT"
                echo "INFO Starting config.js for variant $UIVARIANT"
                node config.js $PATCH $UIVARIANT
                echo $UIVARIANT > /mnt/volumio/rootfs/UIVARIANT
        else
                echo "INFO Starting config.js"
                node config.js $PATCH
        fi
fi

chroot /mnt/volumio/rootfs /bin/bash -x <<'EOF'
su -
/bananapim5config.sh
EOF

UIVARIANT_FILE=/mnt/volumio/rootfs/UIVARIANT
if [ -f "${UIVARIANT_FILE}" ]; then
    echo "INFO Starting variant.js"
    node variant.js
    rm $UIVARIANT_FILE
fi

echo "Copying LIRC configuration files for HK stock remote"
cp platform-bananapi/bananapim5/etc/lirc/lircd.conf /mnt/volumio/rootfs/etc/lirc
cp platform-bananapi/bananapim5/etc/lirc/hardware.conf /mnt/volumio/rootfs/etc/lirc
cp platform-bananapi/bananapim5/etc/lirc/lircrc /mnt/volumio/rootfs/etc/lirc
ls -l /mnt/volumio/rootfs/etc/lirc

echo "Copy Triggerhappy configuration files for aml-remote overlay"
cp platform-bananapi/bananapim5/etc/triggerhappy/triggers.d/audio.conf /mnt/volumio/rootfs/etc/triggerhappy/triggers.d
cp platform-bananapi/bananapim5/etc/sudoers.d/triggerhappy /mnt/volumio/rootfs/etc/sudoers.d
cp platform-bananapi/bananapim5/usr/local/bin/shutdown.sh /mnt/volumio/rootfs/usr/local/bin
chmod +x /mnt/volumio/rootfs/usr/local/bin/shutdown.sh

echo "INFO Cleaning up temp files"
rm /mnt/volumio/rootfs/bananapim5config.sh /mnt/volumio/rootfs/root/init.sh /mnt/volumio/rootfs/root/init

echo "INFO Unmounting temp devices"
umount -l /mnt/volumio/rootfs/dev
umount -l /mnt/volumio/rootfs/proc
umount -l /mnt/volumio/rootfs/sys

echo "INFO ==> bananapi-m5 device installed"
sync

echo "INFO Finalizing Rootfs creation"
sh scripts/finalize.sh

echo "INFO Preparing rootfs base for SquashFS"

if [ -d /mnt/squash ]; then
	echo "INFO Volumio SquashFS Temp Dir Exists - Cleaning it"
	rm -rf /mnt/squash/*
else
	echo "INFO Creating Volumio SquashFS Temp Dir"
	mkdir /mnt/squash
fi

echo "INFO Copying Volumio rootfs to Temp Dir"
cp -rp /mnt/volumio/rootfs/* /mnt/squash/

if [ -e /mnt/kernel_current.tar ]; then
	echo "INFO Volumio Kernel Partition Archive exists - Cleaning it"
	rm -rf /mnt/kernel_current.tar
fi

echo "INFO Creating Kernel Partition Archive"
tar cf /mnt/kernel_current.tar --exclude='resize-volumio-datapart' -C /mnt/squash/boot/ .

echo "INFO Removing the Kernel"
rm -rf /mnt/squash/boot/*

echo "INFO Creating SquashFS, removing any previous one"
rm -r Volumio.sqsh
mksquashfs /mnt/squash/* Volumio.sqsh

echo "INFO Squash filesystem created"
echo "INFO Cleaning squash environment"
rm -rf /mnt/squash

#copy the squash image inside the boot partition
cp Volumio.sqsh /mnt/volumio/images/volumio_current.sqsh
sync
echo "INFO Unmounting Temp Devices"
umount -l /mnt/volumio/images
umount -l /mnt/volumio/rootfs/boot

dmsetup remove_all
losetup -d ${LOOP_DEV}
sync

md5sum "$IMG_FILE" > "${IMG_FILE}.md5"
