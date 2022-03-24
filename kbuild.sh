#! /usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0

set -e

ROOT_DIR=$(dirname "$(realpath "$0")")

# shellcheck source="${ROOT_DIR}/helpers.sh"
# shellcheck disable=SC1091
. "${ROOT_DIR}/helpers.sh"

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
            The platform name, used for selecting the dtb to copy to TFTP_DIR
        --cross-compile, -c
            Set the cross compile environment variable. Use LLVM if not set.
EOF
}

OPTS_SHORT=vhN:T:M:K:S:f:C:c:p:
OPTS_LONG=verbose,help,nfs-dir:,tftp-dir:,modules-dir:,kernel-dir:,sysroot-dir:,fragments-config:,configs-dir:,cross-compile:,platform:

options=$(getopt -o ${OPTS_SHORT} -l ${OPTS_LONG} -- "$@" )

# shellcheck disable=SC2181
[ $? -eq 0 ] || {
    echo "Incorrect options provided"
    exit 1
}

eval set -- "$options"

while true; do
    case "$1" in
        --verbose | -v)
            V=1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --nfs-dir | -N)
            shift
            NFS_DIR=$1
            ;;
        --sysroot-dir | -S)
            shift
            SYSROOT_DIR=$1
            ;;
        --tftp-dir | -T)
            shift
            TFTP_DIR=$1
            ;;
        --modules-dir | -M)
            shift
            IFS=',' read -r -a MODULES_DIR <<< "$1"
            unset IFS
            ;;
        --kernel-dir | -K)
            shift
            KDIR=$1
            ;;
        --configs-dir | -C)
            shift
            CONFIGS_DIR=$1
            ;;
        --fragments-config | -f)
            shift
            IFS=',' read -r -a FRAGMENTS <<< "$1"
            unset IFS
            ;;
        --platform | -p)
            shift
            PLATFORM=$1
            ;;
        --cross-compile | -c)
            shift
            CROSS_COMPILE=$1
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

declare -a COMMANDS
COMMANDS+=("${@:-all}")

DEFCONFIG=${DEFCONFIG:-defconfig}
NPROC=$(nproc)
ARCH=${ARCH:-arm64}
KDIR=${KDIR:-$(pwd)}
CONFIGS_DIR=${CONFIGS_DIR:-arch/${ARCH}/configs}
V="${V:-0}"

declare -a KARGS
KARGS+=(-C "${KDIR}")
KARGS+=(-j"${NPROC}")
KARGS+=(ARCH="${ARCH}")
KARGS+=(V="${V}")
KARGS+=(INSTALL_MOD_PATH="${NFS_DIR}")
if [ -d "${SYSROOT_DIR}" ]; then
    KARGS+=(INSTALL_HDR_PATH="${SYSROOT_DIR}/usr/src/kernels")
fi

if [ -z "${CROSS_COMPILE}" ];
then
    KARGS+=(LLVM=1)
else
    KARGS+=(CROSS_COMPILE="${CROSS_COMPILE}")
fi

[ -d "${NFS_DIR}" ] || fatal "${NFS_DIR} does not exist!"
[ -d "${TFTP_DIR}" ] || fatal "${TFTP_DIR} does not exist!"


function do_config {
    FORCE=${1:-notforce}
    if [ ! -e .config ] || [ "${FORCE}" == "force" ];
    then
        if [ ${#FRAGMENTS[@]} -gt 0 ];
        then
            "${KDIR}"/scripts/kconfig/merge_config.sh -m "arch/${ARCH}/configs/${DEFCONFIG}" "$(printf "${CONFIGS_DIR}/%s " "${FRAGMENTS[@]}")"
            make "${KARGS[@]}" olddefconfig
        else
            make "${KARGS[@]}" "${DEFCONFIG}"
        fi
    fi
}

function do_build {
    make "${KARGS[@]}" Image dtbs modules
    for MODULE_DIR in "${MODULES_DIR[@]}";
    do

        [ -d "${MODULE_DIR}" ] || fatal "${MODULE_DIR} does not exist!"
        echo "Compiling $MODULE_DIR..."
        make "${KARGS[@]}" M="${MODULE_DIR}" clean modules
    done

    "${KDIR}"/scripts/clang-tools/gen_compile_commands.py . "${MODULES_DIR[@]}"
}

function do_install {
    SUDO=sudo
    echo "Installing modules..."
    ${SUDO} make "${KARGS[@]}" modules_install
    for MODULE_DIR in "${MODULES_DIR[@]}";
    do
        [ -d "${MODULE_DIR}" ] || fatal "${MODULE_DIR} does not exist!"
        echo "Installing $MODULE_DIR..."
        ${SUDO} make "${KARGS[@]}" M="${MODULE_DIR}" modules_install
    done

    echo "Copying ${PLATFORM}  dtbs, Image to ${TFTP_DIR}"

    DTBS=$(find "arch/${ARCH}" -iname "${PLATFORM}*.dtb")

    cp "${DTBS}" "arch/${ARCH}/boot/Image" "$TFTP_DIR/"

    if [ -d "${SYSROOT_DIR}" ]; then
        sudo make "${KARGS[@]}"  headers_install
    fi
}

for CMD in "${COMMANDS[@]}";
do
    case "$CMD" in
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
            echo "$CMD not supported"
            ;;
    esac
done

