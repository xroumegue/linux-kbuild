# SPDX-License-Identifier: GPL-3.0

function fatal {
    echo "ERROR: $1"
    exit
}

sudomize()
{
    destdir=$1
    shift

    if [ "$(stat --printf=%u "$destdir")" !=  "$(id -u)" ];
    then
        sudo "$@"
    else
        exec "$@"
    fi
}

