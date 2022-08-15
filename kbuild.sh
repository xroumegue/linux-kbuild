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
EOF
}

opts_short=vhN:T:M:K:S:f:C:c:p:
opts_long=verbose,help,nfs-dir:,tftp-dir:,modules-dir:,kernel-dir:,sysroot-dir:,fragments-config:,configs-dir:,cross-compile:,platform:

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
        --platform | -p)
            shift
            platform=$1
            ;;
        --cross-compile | -c)
            shift
            cross_compile=$1
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

defconfig=${defconfig:-defconfig}
arch=${arch:-arm64}
kdir=${kdir:-$(pwd)}
configs_dir=${configs_dir:-arch/${arch}/configs}
v="${v:-0}"

declare -a kargs
kargs+=(-C "${kdir}")
kargs+=(-j"$(nproc)")
kargs+=(ARCH="${arch}")
kargs+=(V="${v}")
kargs+=(INSTALL_MOD_PATH="${nfs_dir}")
if [ -d "${sysroot_dir}" ]; then
    kargs+=(INSTALL_HDR_PATH="${sysroot_dir}/usr/src/kernels")
fi

if [ -z "${cross_compile}" ];
then
    kargs+=(LLVM=1)
else
    kargs+=(CROSS_COMPILE="${cross_compile}")
fi

[ -d "${nfs_dir}" ] || fatal "${nfs_dir} does not exist!"
[ -d "${tftp_dir}" ] || fatal "${tftp_dir} does not exist!"

function do_config {
    force=${1:-notforce}
    if [ ! -e .config ] || [ "${force}" == "force" ];
    then
        if [ ${#fragments[@]} -gt 0 ];
        then
            "${kdir}"/scripts/kconfig/merge_config.sh -m "arch/${arch}/configs/${defconfig}" "$(printf "${configs_dir}/%s " "${fragments[@]}")"
            make "${kargs[@]}" olddefconfig
        else
            make "${kargs[@]}" "${defconfig}"
        fi
    fi
}

function do_build {
    make "${kargs[@]}" Image dtbs modules
    for module_dir in "${modules_dir[@]}";
    do

        [ -d "${module_dir}" ] || fatal "${module_dir} does not exist!"
        echo "Compiling $module_dir..."
        make "${kargs[@]}" M="${module_dir}" clean modules
    done

    "${kdir}"/scripts/clang-tools/gen_compile_commands.py . "${modules_dir[@]}"
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

    echo "Copying ${platform}  dtbs, Image to ${tftp_dir}"

    find \
        "arch/${arch}/boot/dts" \
        -iname "${platform}*.dtb" \
        -exec bash -c 'F=${1##*/}; cp $1 $2/${F/-overlay.dtb/.dtbo}' - '{}' "${tftp_dir}" \;

    cp "arch/${arch}/boot/Image" "$tftp_dir/"

    if [ -d "${sysroot_dir}" ]; then
        sudo make "${kargs[@]}"  headers_install
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
        "install")
            echo Installing...
            do_install
            ;;
        "all")
            do_config
            do_build
            do_install
            ;;
        *)
            echo "Running $cmd..."
            make "${kargs[@]}" "$cmd"
            ;;
    esac
done

