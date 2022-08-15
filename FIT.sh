# SPDX-License-Identifier: GPL-2.0+
# shellcheck disable=SC2154

if [ -z ${fit_conf_prefix+x} ] ; then
    fit_conf_prefix="conf-"
fi

get_dtb_feature() {
    local dtb_feature
    dtb_feature=$(basename "${1}" "$2")
    if [ -n "${dtb_feature/$platform-/}" ]; then
        dtb_feature=${dtb_feature/$platform-/}
    fi
    echo "${dtb_feature}"
}

get_fdt_name() {
    local fdt_name
    fdt_name=$1
    case "${fdt_name##*.}" in
        "dtb")
            fdt_name=$(basename "${fdt_name}" .dtb)
            ;;
        "dtbo")
            fdt_name=$(get_dtb_feature "${fdt_name}" .dtbo)
            ;;
        *)
            fatal "Invalid dtb file ${fdt_name} ${fdt_name##*.} "
            ;;
    esac
    echo "${fdt_name}"
}

make_FIT_image() {
    local kernel_compression
    local kernel_its=${1:-$output_dir/arch/$arch/boot/kernel_fdt.its}

    case $image_kernel in
    *.gz)
        kernel_compression=gzip
        ;;
    *.lz4)
        kernel_compression=lz4
        ;;
    *)
        kernel_compression=none
        ;;
    esac

    cat <<EOF > "$kernel_its"
/dts-v1/;
/ {
    description = "Kernel + FDT image for $platform board";
    #address-cells = <1>;

    images {
        kernel {
            description = "Linux kernel";
            data = /incbin/("$output_dir/arch/$arch/boot/$image_kernel");
            type = "kernel";
            arch = "$arch";
            os = "linux";
            compression = "$kernel_compression";
            load = <$loadaddr>;
            entry = <$loadaddr>;
            hash-1 {
                algo = "crc32";
            };
            hash-2 {
                algo = "sha1";
            };
        };
EOF

    local dtb
    local addr=$fdtaddr

    for dtb in "${dtbs[@]}" "${dt_overlays[@]}" ; do
        local src=${dtb/:*/}
        local dst=${dtb/*:/}
        local load=

        if [ -n "$fdtaddr" ] ; then
            load="load = <$(printf 0x%08x "$addr")>;"
            addr=$((addr+0x40000))
        fi

        if [[ ${src} != /* ]] ; then
            src="$output_dir/arch/$arch/boot/dts/$src"
        fi

        dst=$(get_fdt_name "${dst}")

        cat <<EOF >> "$kernel_its"
        fdt-$dst {
            description = "Flattened Device Tree blob $dst";
            data = /incbin/("$src");
            type = "flat_dt";
            arch = "$arch";
            compression = "none";
            $load
            hash-1 {
                algo = "crc32";
            };
            hash-2 {
                algo = "sha1";
            };
        };
EOF
    done

    local config=$platform
    cat <<EOF >> "$kernel_its"
    };

    configurations {
        default = "${fit_conf_prefix}${config}";
EOF
    for dtb in "${dtbs[@]}" ; do
        local dst=${dtb/*:/}
        dst=${dst/*\//}
        dst=$(get_fdt_name "${dst}")

        cat <<EOF >> "$kernel_its"
        ${fit_conf_prefix}${dst} {
            description = "Boot Linux kernel with $dst blob";
            kernel = "kernel";
            fdt = "fdt-$dst";
        };
EOF
    done

    for dtbo in "${dt_overlays[@]}" ; do
        local dst=${dtbo/*:/}
        dst=$(get_fdt_name "${dst}")

        cat <<EOF >> "$kernel_its"
        ${fit_conf_prefix}${dst} {
            description = "DT overlay $dst";
            fdt = "fdt-$dst";
        };
EOF
    done

    cat <<EOF >> "$kernel_its"
    };
};
EOF

    PATH="$output_dir/scripts/dtc:$PATH" mkimage -f "$kernel_its" "${kernel_its/its/itb}"
}



make_FIT_boot_script() {
    local boot_FIT
    local conf_overlays=("$@")
    boot_FIT=$tftp_dir/boot_fit
    cat <<EOF > "${boot_FIT}.cmd"
setenv nfsroot ${nfs_dir}
setenv tftproot ${tftp_dir/\/srv\/tftp\//}
setenv fdtconf ${platform}
setenv image \${tftproot}/kernel_fdt.itb

setenv fdtconf_overlays "${conf_overlays[@]}"

for overlay in \${fdtconf_overlays}; do
    echo Overlaying \${overlay}...;
    setenv overlaystring "\${overlaystring}\\#conf-\${overlay}"
done

echo Loading kernel \${image} to \${loadaddr} ...;
tftp \${loadaddr} \${serverip}:\${image}

setenv bootargs console=\${console} root=/dev/nfs ip=dhcp nfsroot=\${serverip}:\${nfsroot},v3,tcp

echo Booting ...;
bootm \${loadaddr}#conf-\${fdtconf}\${overlaystring}
EOF

    mkimage \
        -A arm \
        -T script \
        -C none \
        -n "${platform} boot script" \
        -d "${boot_FIT}.cmd" "${boot_FIT}.scr"
}
