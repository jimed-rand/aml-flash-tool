#!/bin/bash

set -e -o pipefail

BASE=$(dirname "$(readlink -fm "$0")")
AMLOGIC_TOOL="$BASE/aml-flash-tool.sh"
RULES_DIR="$BASE/tools/_install_"
INSTALL_DIR="/usr/local/bin"

DISTRIB=""
DISTRIB_RELEASE=""

if [ -f /etc/lsb-release ]; then
    DISTRIB=$(grep "DISTRIB_ID" /etc/lsb-release | cut -d "=" -f 2)
    DISTRIB_RELEASE=$(grep "DISTRIB_RELEASE" /etc/lsb-release | cut -d "=" -f 2)
fi

prepare_host() {
    local hostdeps="libusb-dev git parted lib32z1 lib32stdc++6 libusb-0.1-4 libusb-1.0-0-dev libusb-1.0-0 ccache libncurses5 pv base-files linux-base"
    local deps=()
    local installed
    installed=$(dpkg-query -W -f '${db:Status-Abbrev}|${binary:Package}\n' '*' 2>/dev/null | grep '^ii' | awk -F '|' '{print $2}' | cut -d ':' -f 1)

    if [[ "$DISTRIB" == "Ubuntu" ]] && [[ "$DISTRIB_RELEASE" == "18.10" || "$DISTRIB_RELEASE" =~ ^(20|21|22|23|24) ]]; then
        hostdeps="$hostdeps lib32ncurses6"
    else
        hostdeps="$hostdeps lib32ncurses5"
    fi

    for packet in $hostdeps; do
        if ! grep -q -x -e "$packet" <<< "$installed"; then
            deps+=("$packet")
        fi
    done

    if [[ ${#deps[@]} -gt 0 ]]; then
        echo "Installing dependencies"
        echo "Requires root privileges, please enter your password!"
        sudo apt update
        sudo apt -y --no-install-recommends install "${deps[@]}"
        sudo update-ccache-symlinks
    fi
}

RULE=""
IGNORE_CHECK=""

echo ""
echo "==============================================="
echo ""
echo "Host PC: $DISTRIB $DISTRIB_RELEASE"
echo ""
echo "==============================================="
echo ""

prepare_host

error_msg() {
    echo "Error: $1"
}

warning_msg() {
    echo "Warning: $1"
}

if [ "$DISTRIB" != "Ubuntu" ] || ! [[ "$DISTRIB_RELEASE" =~ ^(12|14|16|18|19|20|21|22|23|24) ]]; then
    warning_msg "This flash tool just support Ubuntu LTS now, other distributions haven't been verified!"
    read -r -p "Continue anyway? [No/yes] " answer
    if [[ "$answer" != "yes" && "$answer" != "Yes" ]]; then
        exit 1
    else
        IGNORE_CHECK="yes"
        warning_msg "You choose to not check the system environment, the installation may fail!"
    fi
fi

echo "Installing USB rules..."

if [[ "$DISTRIB_RELEASE" =~ ^12 ]]; then
    RULE="$RULES_DIR/70-persistent-usb-ubuntu12.rules"
    sudo cp "$RULE" /etc/udev/rules.d
    CURRENT_USER=$(whoami)
    sudo sed -i "s/OWNER=\"amlogic\"/OWNER=\"$CURRENT_USER\"/g" "/etc/udev/rules.d/$(basename "$RULE")"
elif [[ "$IGNORE_CHECK" == "yes" || "$DISTRIB_RELEASE" =~ ^(14|16|18|19|20|21|22|23|24) ]]; then
    RULE="$RULES_DIR/70-persistent-usb-ubuntu14.rules"
    sudo cp "$RULE" /etc/udev/rules.d
else
    error_msg "Ubuntu $DISTRIB_RELEASE has not been verified! Please copy USB rules yourself"
    exit 1
fi

sudo udevadm control --reload-rules

echo "Installing flash-tool..."
mkdir -p "$INSTALL_DIR"
sudo ln -fs "$AMLOGIC_TOOL" "$INSTALL_DIR/$(basename "$AMLOGIC_TOOL")"

echo "Done!"
