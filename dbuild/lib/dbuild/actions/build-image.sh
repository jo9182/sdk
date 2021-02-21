#!/usr/bin/env bash

if [[ ! -f "${DBUILD_ROOTFS_DIR}.tar.gz" ]]; then
	msg_error "$(basename ${DBUILD_ROOTFS_DIR}.tar.gz) does not exist, please generate one."
	exit 1
fi

export TEMP_DIRS=()

exit_trap() {
	msg "Cleaning up rootfs"
	rootfs_cleanup
	msg "Removing rootfs and temporary directories"
	rm -rf "${DBUILD_ROOTFS_DIR}" "${DBUILD_BUILD_DIR}/live-${EXPIDUS_VERSION}-${TARGET_ARCH}" "${DBUILD_BUILD_DIR}/"*-"${EXPIDUS_VERSION}-${TARGET_ARCH}" "${TEMP_DIRS[@]}"
}

msg "Extracting tarball"
rm -rf "${DBUILD_ROOTFS_DIR}"
mkdir -p "${DBUILD_ROOTFS_DIR}"
tar -xf "${DBUILD_ROOTFS_DIR}.tar.gz" -C "${DBUILD_ROOTFS_DIR}"
trap "exit_trap" EXIT

msg "Generating fstab"
echo "# fstab generated by dbuild" >"${DBUILD_ROOTFS_DIR}/etc/fstab"
echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" >>"${DBUILD_ROOTFS_DIR}/etc/fstab"
for disk in "${DISK_IMAGES[@]}"; do
	disk_name=$(echo "${disk}" | cut -f1 -d ' ')
	disk_part=$(echo "${disk}" | cut -f2 -d ' ')
	disk_path=$(echo "${disk}" | cut -f3 -d ' ')
	disk_opts=$(echo "${disk}" | cut -f4 -d ' ')
	disk_uuid="UUID=$(uuidgen)"

	if [[ -z "${disk_opts}" ]]; then
		disk_opts="defaults"
	fi

	if [[ "${disk_part}" == "vfat" ]]; then
		disk_uuid="UUID=$(uuidgen | cut -f2 -d '-' | sed -E 's/([[:lower:]])|([[:upper:]])/\U\1\L\2/g')-$(uuidgen | cut -f2 -d '-' | sed -E 's/([[:lower:]])|([[:upper:]])/\U\1\L\2/g')"
	fi

	if [[ -z "${NOT_LIVE}" ]] && [[ "${disk_name}" == "rootfs" ]]; then
		msg_warn "Skipping rootfs in fstab"
	else
		echo "${disk_uuid} ${disk_path} ${disk_part} ${disk_opts} 0 $((i % 2 + 1))" >>"${DBUILD_ROOTFS_DIR}/etc/fstab"
	fi
done

if type get_kernel_version >/dev/null 2>&1; then
	KERNEL_VERSION=$(get_kernel_version)
else
	KERNEL_SERIES=$(xbps query -S linux | grep pkgver | cut -f2 -d '-' | cut -f1 -d '_')
	KERNEL_VERSION=$(xbps query -S "linux${KERNEL_SERIES}" | grep pkgver | cut -f2 -d '-')
fi

if type pre_build_disks >/dev/null 2>&1; then
	msg "Running pre-build disks hook"
	pre_build_disks
fi

msg "Reconfiguring system"
rootfs_exec "xbps-reconfigure --all --force >/dev/null 2>&1"

if type pre_build_initramfs >/dev/null 2>&1; then
	msg "Running pre-build initramfs hook"
	pre_build_initramfs
fi

msg "Generating initramfs"
if [[ -z "${NOT_LIVE}" ]]; then
	DRACUT_ARGS+=" --force-add dmsquash-live"
fi
rootfs_exec "dracut -N --gzip --omit systemd \"/boot/initramfs-${KERNEL_VERSION}.img\" --force ${DRACUT_ARGS} ${KERNEL_VERSION} >/dev/null 2>&1" || (msg_error "Failed to generate initramfs"; exit 1)

msg_debug "Cleaning rootfs before building disk images"
rootfs_cleanup

msg "Generating disk images"
while read line; do
	if [[ ! "$line" == \#* ]]; then
		blkdev=$(echo "${line}" | cut -f1 -d ' ')
		path=$(echo "${line}" | cut -f2 -d ' ')
		part=$(echo "${line}" | cut -f3 -d ' ')
		if ! [[ "$part" == "tmpfs" ]]; then
			disk_name=$(find_disk "${path}" | cut -f1 -d ' ')

			if [[ ! -d "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}" ]]; then
				msg "Moving ${path} out of rootfs"
				mv "${DBUILD_ROOTFS_DIR}${path}" "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}"
				mkdir -p "${DBUILD_ROOTFS_DIR}${path}"
			fi

			sz=$(du --apparent-size -sm "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}" | awk '{ print $1 }')
			if [[ "${sz}" != "0" ]]; then
				sz=$((sz * 3))

				msg "Allocating ${sz}M for ${disk_name}"
				truncate -s "${sz}M" "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" >/dev/null 2>&1 || (msg_error "Failed to allocate space for ${disk_name}."; exit 1)

				if [[ "${part}" == "vfat" ]]; then
					hex="${blkdev/UUID=/}"
					mkfs_args="-i ${hex/-/}"
				fi

				msg "Formatting ${disk_name} with ${part}"
				eval "mkfs.${part}" ${mkfs_args[@]} "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" >/dev/null 2>&1 || (msg_error "Failed to format ${disk_name} with ${part}."; exit 1)
				if ! [[ -z "$mkfs_args" ]]; then
					unset mkfs_args
				fi

				if ! [[ "${part}" == "vfat" ]]; then
					tune2fs -U "${blkdev/UUID=/}" "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" >/dev/null
				fi

				tmp=$(mktemp -d)
				TEMP_DIRS+=("$tmp")

				msg "Writing files to ${disk_name}"
				mount -t "${part}" -o loop "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" "${tmp}"
				cp -a "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}"/* "${tmp}/" || (msg_error "Failed to write files to ${disk_name}."; umount "${tmp}"; rm -rf "${tmp}"; exit 1)
				umount "${tmp}"
				rm -rf "${tmp}"
			fi
		fi
	fi
done <"${DBUILD_ROOTFS_DIR}/etc/fstab"

if [[ -z "${NOT_LIVE}" ]]; then
	msg "Building a live disk image"

	mkdir -p "${DBUILD_BUILD_DIR}/live-${EXPIDUS_VERSION}-${TARGET_ARCH}/LiveOS"
	mksquashfs "${DBUILD_ROOTFS_DIR}" "${DBUILD_BUILD_DIR}/live-${EXPIDUS_VERSION}-${TARGET_ARCH}/LiveOS/squashfs.img" >/dev/null 2>&1 || (msg_error "Failed to create squashfs image."; exit 1)
	cp -r "${DBUILD_ROOTFS_DIR}/boot" "${DBUILD_BUILD_DIR}/live-${EXPIDUS_VERSION}-${TARGET_ARCH}/boot"

	if type post_build_live >/dev/null 2>&1; then
		msg "Running post hook for live image"
		post_build_live
	fi
fi

if [[ ! -z "${EXTRA_DISK_IMAGES}" ]]; then
	for name in "${EXTRA_DISK_IMAGES[@]}"; do
		msg "Creating disk ${name}"
		eval "build_disk_${name}"
	done
fi

if [[ ! -z "${COMBINE_DISKS}" ]] && [[ ! -z "${DISK_NAME}" ]] && [[ ! -z "${DISK_FORMAT}" ]]; then
	total_size=0
	case "${DISK_FORMAT}" in
		mbr)
			total_size=512
			;;
		gpt)
			total_size=1024
			;;
		*)
			msg_error "Unrecognized disk format: ${DISK_FORMAT}"
			exit 1
			;;
	esac

	for disk in "${COMBINE_DISKS[@]}"; do
		disk_name=$(echo "${disk}" | cut -f1 -d ' ')
		disk_size=$(du --apparent-size -sm "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" | awk '{ print $1 }')
		total_size=$((total_size + (disk_size + disk_size / 6)))
	done

	msg "Creating ${DISK_NAME} with size of ${total_size}M"
	truncate -s "${total_size}M" "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null 2>&1 || (msg_error "Failed to allocate space."; exit 1)

	msg "Formating disk with ${DISK_FORMAT}"
	case "${DISK_FORMAT}" in
		mbr)
			cat << EOF | fdisk "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null 2>&1 || (msg_error "Failed to format disk."; exit 1)
o
w
EOF
			;;
		gpt)
			cat << EOF | fdisk "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null 2>&1 || (msg_error "Failed to format disk."; exit 1)
g
w
EOF
			;;
	esac

	part_num=1
	for disk in "${COMBINE_DISKS[@]}"; do
		disk_name=$(echo "${disk}" | cut -f1 -d ' ')
		disk_type=$(echo "${disk}" | cut -f2 -d ' ')
		disk_size=$(du --apparent-size -sm "${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" | awk '{ print $1 }')
		disk_size=$((disk_size + disk_size / 6))
		case "${DISK_FORMAT}" in
			mbr)
				cat << EOF | fdisk "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null 2>&1 || (msg_error "Failed to format disk."; exit 1)
n
p
${part_num}

+${disk_size}M
t
${part_num}
${disk_type}
w
EOF
				;;
			gpt)
				cat << EOF | fdisk "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null 2>&1 || (msg_error "Failed to format disk."; exit 1)
n
${part_num}

+${disk_size}M
t
${part_num}
${disk_type}
w
EOF
				;;
		esac
		part_num=$((part_num + 1))
	done

	loops=($(kpartx -av "${DBUILD_BUILD_DIR}/${DISK_NAME}" | cut -f3 -d ' '))
	i=0
	for disk in "${COMBINE_DISKS[@]}"; do
		disk_name=$(echo "${disk}" | cut -f1 -d ' ')
		loop="${loops[$i]}"
		msg "Writing ${disk_name} to ${loop}"
		dd if="${DBUILD_BUILD_DIR}/${disk_name}-${EXPIDUS_VERSION}-${TARGET_ARCH}.img" of="/dev/mapper/${loop}" bs=1M status=none || kpartx -dv "${DBUILD_BUILD_DIR}/${DISK_NAME}"
		i=$((i + 1))
	done

	sync
	kpartx -d "${DBUILD_BUILD_DIR}/${DISK_NAME}" >/dev/null
fi

if type post_build_images >/dev/null 2>&1; then
	msg "Running post hook"
	post_build_images
fi
