# SPDX-License-Identifier: GPL-2.0+

if [ -z ${fit_conf_prefix+x} ] ; then
	fit_conf_prefix="conf-"
fi

make_FIT_image() {
	local kernel_compression
	local kernel_its=$output_dir/arch/$arch/boot/kernel_fdt.its

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

	cat <<EOF > $kernel_its
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

	for dtb in ${dtbs[@]} ${dt_overlays[@]} ; do
		local src=${dtb/:*/}
		local dst=${dtb/*:/}
		local load=

		if [ ! -z $fdtaddr ] ; then
			load="load = <$(printf 0x%08x $addr)>;"
			addr=$(($addr+0x40000))
		fi

		if [[ ${src} != /* ]] ; then
			src="$output_dir/arch/$arch/boot/dts/$src"
		fi

		dst=${dst/*\//}
		cat <<EOF >> $kernel_its
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

	local config=$(echo ${dtbs[0]} | sed 's/.*[:/]//')
	cat <<EOF >> $kernel_its
	};

	configurations {
		default = "${fit_conf_prefix}${config}";
EOF
	for dtb in ${dtbs[@]} ; do
		local dst=${dtb/*:/}
		dst=${dst/*\//}

		cat <<EOF >> $kernel_its
		${fit_conf_prefix}${dst} {
			description = "Boot Linux kernel with $dst blob";
			kernel = "kernel";
			fdt = "fdt-$dst";
		};
EOF
	done

	for dtbo in ${dt_overlays[@]} ; do
		local dst=${dtbo/*:/}
		dst=${dst/*\//}

		cat <<EOF >> $kernel_its
		${fit_conf_prefix}${dst} {
			description = "DT overlay $dst";
			fdt = "fdt-$dst";
		};
EOF
	done

	cat <<EOF >> $kernel_its
	};
};
EOF

	PATH="$output_dir/scripts/dtc:$PATH" mkimage -f $kernel_its ${kernel_its/its/itb}
}

_image_file=kernel_fdt.itb
