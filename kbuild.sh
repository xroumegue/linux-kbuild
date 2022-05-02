#! /usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0

set -e

root_dir=$(dirname "$(realpath "$0")")

# shellcheck source="${root_dir}/helpers.sh"
# shellcheck disable=SC1091
. "${root_dir}/helpers.sh"

function usage {
cat << EOF
    $(basename "$0") [OPTIONS] CMD
        --help, -h
            This help message
        --verbose, -v
            Show build commands
        --output-dir, -O
            Specify the output directory
        --nfs-dir, -N
            Specify the NFS directory exporting the root file system
        --sysroot-dir, -S
            Specify the sysroot directory
        --tftp-dir, -T
            Specify the TFTP directory exporting the boot images
        --modules-dir, -M
            A list of modules directory separated with ','
        --kernel-dir, -K
            Specify the kernel source directory
        --configs-dir, -C
            Specify the config files directory
        --fragments-config, -f
            A list of config fragment files separated with ','
        --platform, -p
            The platform name, used for selecting the dtb to copy to tftp_dir
        --cross-compile, -c
            Set the cross compile environment variable. Use LLVM if not set.
        --bootargs, -b
            Set additional bootargs to kernel command line
        --doc-dirs, -D
            Specify the documentation folder to generate
        --dt-bindings, -d
            Check specified dt bindings file
    Possible commands:
        config
        build
        doc
        install
        install_tftp
        dt_check
        all

EOF
}

opts_short=vhb:D:N:T:M:K:S:f:C:c:p:O:o:d:
opts_long=verbose,help,bootargs:,doc-dirs:,nfs-dir:,tftp-dir:,modules-dir:,kernel-dir:,sysroot-dir:,fragments-config:,configs-dir:,cross-compile:,platform:,output-dir:,overlays:,dt-bindings:

options=$(getopt -o ${opts_short} -l ${opts_long} -- "$@" )

# shellcheck disable=SC2181
[ $? -eq 0 ] || {
    echo "Incorrect options provided"
    exit 1
}

eval set -- "$options"

while true; do
    case "$1" in
        --verbose | -v)
            v=1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --bootargs | -b)
            shift
            bootargs=$1
            ;;
        --output-dir | -O)
            shift
            output_dir=$1
            ;;
        --nfs-dir | -N)
            shift
            nfs_dir=$1
            ;;
        --sysroot-dir | -S)
            shift
            sysroot_dir=$1
            ;;
        --tftp-dir | -T)
            shift
            tftp_dir=$1
            ;;
        --modules-dir | -M)
            shift
            IFS=',' read -r -a modules_dir <<< "$1"
            unset IFS
            ;;
        --kernel-dir | -K)
            shift
            kdir=$1
            ;;
        --configs-dir | -C)
            shift
            configs_dir=$1
            ;;
        --fragments-config | -f)
            shift
            IFS=',' read -r -a fragments <<< "$1"
            unset IFS
            ;;
        --overlays | -o)
            shift
            IFS=',' read -r -a overlays <<< "$1"
            ;;
        --platform | -p)
            shift
            platform=$1
            ;;
        --cross-compile | -c)
            shift
            cross_compile=$1
            ;;
        --doc-dirs | -D)
            shift
            doc_dirs=$1
            ;;
        --dt-bindings | -d)
            shift
            dt_bindings=$1
            ;;
       --)
            shift
            break
            ;;
        *)
            ;;
    esac
    shift
done

declare -a commands
commands+=("${@:-all}")

soc=${platform%%-*}
board=${platform#*-}
defconfig=${defconfig:-defconfig}
arch=${arch:-arm64}
kdir=${kdir:-$(pwd)}
configs_dir=${configs_dir:-arch/${arch}/configs}
v="${v:-0}"
output_dir=${output_dir:-${kdir}}
image_kernel=Image
loadaddr=${loadaddr:-0x48000000}
fdtaddr=${fdtaddr:-0x43000000}
doc_dirs=${doc_dirs:-$(pwd)}
bootargs=${bootargs:-}
dt_bindings=${dt_bindings:-}

declare -a kargs
kargs+=(-C "${kdir}")
kargs+=(-j"$(nproc)")
kargs+=(ARCH="${arch}")
kargs+=(V="${v}")
kargs+=(INSTALL_MOD_PATH="${nfs_dir}")
kargs+=(SPHINXDIRS="${doc_dirs}")
kargs+=(DT_CHECKER_FLAGS="-m")
if [ -n "${dt_bindings}" ];
then
kargs+=(DT_SCHEMA_FILES="${dt_bindings}")
fi

if [ -d "${sysroot_dir}" ]; then
    kargs+=(INSTALL_HDR_PATH="${sysroot_dir}/usr/src/kernels")
fi

if [ -z "${cross_compile}" ];
then
    kargs+=(LLVM=1)
else
    kargs+=(CROSS_COMPILE="${cross_compile}")
fi

if [ "${output_dir}" != "${kdir}" ];
then
    [ -d "${output_dir}" ] || mkdir -p "${output_dir}"
    kargs+=(O="${output_dir}")
fi

[ -d "${nfs_dir}" ] || fatal "${nfs_dir} does not exist!"
[ -d "${tftp_dir}" ] || fatal "${tftp_dir} does not exist!"

# shellcheck source="${root_dir}"/FIT.sh
# shellcheck disable=SC1091
. "${root_dir}"/FIT.sh || fatal "Sourcing FIT.sh returned with error!"

function do_config {
    force=${1:-notforce}
    if [ ! -e "${output_dir}"/.config ] || [ "${force}" == "force" ];
    then
        if [ ${#fragments[@]} -gt 0 ];
        then
            "${kdir}"/scripts/kconfig/merge_config.sh \
                -O "${output_dir}" \
                -m "arch/${arch}/configs/${defconfig}" \
                "$(printf "${configs_dir}/%s " "${fragments[@]}")"
            make "${kargs[@]}" olddefconfig
        else
            make "${kargs[@]}" "${defconfig}"
        fi
    fi
}

function do_build {
    make "${kargs[@]}" "${image_kernel}" dtbs modules
    for module_dir in "${modules_dir[@]}";
    do

        [ -d "${module_dir}" ] || fatal "${module_dir} does not exist!"
        echo "Compiling $module_dir..."
        make "${kargs[@]}" M="${module_dir}" clean modules
    done

    "${kdir}"/scripts/clang-tools/gen_compile_commands.py . "${modules_dir[@]}"
}

function do_doc {
	if [[ ! -f "$output_dir/doc/bin/activate" ]] ; then
		python -m venv "$output_dir/doc"
        # shellcheck disable=SC1091
		. "$output_dir/doc/bin/activate"
		pip install -r Documentation/sphinx/requirements.txt
	else
        # shellcheck disable=SC1091
		. "$output_dir/doc/bin/activate"
	fi

    make "${kargs[@]}" htmldocs
    deactivate
}

function do_dt_check {
    make "${kargs[@]}" dt_binding_check
}

function do_install_tftp {
    echo "Copying ${platform} (soc:${soc} / board:${board}) dtbs, ${image_kernel} to ${tftp_dir}"

    find "${tftp_dir}" -iname '*.dtb' -iname '*.dtbo' -delete

    find \
        "${output_dir}/arch/${arch}/boot/dts" \
        -iname "${platform}.dtb" \
        -exec cp {} "${tftp_dir}" \;

    find \
        "${output_dir}/arch/${arch}/boot/dts" \
        -regex ".*${soc}-\(${board}-\)*[a-zA-Z0-9_]+-overlay.dtb" \
        -exec bash -c 'F=${1##*/}; cp $1 $2/${F/-overlay.dtb/.dtbo}' - '{}' "${tftp_dir}" \;

    cp "${output_dir}/arch/${arch}/boot/${image_kernel}" "$tftp_dir/"

    # shellcheck disable=SC2034
    mapfile -t dtbs < <(find "${tftp_dir}" -type f -name "*.dtb" | sort -r)
    mapfile -t dt_overlays < <(find "${tftp_dir}" -type f -name "*.dtbo" | sort -r)

    dtb_basename=$(basename "${dtbs[0]}" .dtb)
    if [ "${dtb_basename}" != "${platform}" ]; then
        platform=${dtb_basename}
        echo "Inconsistent platform name, fixing to ${platform}"
    fi
    echo "${dtbs[@]}"
    echo "${dt_overlays[@]}"

    kernel_its=$output_dir/arch/$arch/boot/kernel_fdt.its
    kernel_itb=${kernel_its/its/itb}
    eval make_FIT_image "$kernel_its"
    eval make_FIT_boot_script "${overlays[@]}"
    cp "${kernel_itb}" "${tftp_dir}"
}

function do_install {
    sudo=sudo
    echo "Installing modules..."
    ${sudo} make "${kargs[@]}" modules_install
    for module_dir in "${modules_dir[@]}";
    do
        [ -d "${module_dir}" ] || fatal "${module_dir} does not exist!"
        echo "Installing $module_dir..."
        ${sudo} make "${kargs[@]}" M="${module_dir}" modules_install
    done

    if [ -d "${sysroot_dir}" ]; then
        ${sudo} make "${kargs[@]}"  headers_install
    fi
}

for cmd in "${commands[@]}";
do
    case "$cmd" in
        "config")
            echo Configuring the kernel ...
            do_config force
            ;;
        "build")
            echo Building...
            do_build
            ;;
        "doc")
            echo Generating documentation
            do_doc
            ;;
        "dt_check")
            echo Checking dt bindings
            do_dt_check
            ;;
        "install")
            echo Installing...
            do_install
            ;;
        "install_tftp")
            echo Installing to tftp...
            do_install_tftp
            ;;
        "all")
            do_config
            do_build
            do_install
            do_install_tftp
            ;;
        *)
            echo "Running $cmd..."
            make "${kargs[@]}" "$cmd"
            ;;
    esac
done

