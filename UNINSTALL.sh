#!/bin/bash

set -e -o pipefail

DISTRIB=""
DISTRIB_RELEASE=""

if [ -f /etc/lsb-release ]; then
    DISTRIB=$(grep "DISTRIB_ID" /etc/lsb-release | cut -d "=" -f 2)
    DISTRIB_RELEASE=$(grep "DISTRIB_RELEASE" /etc/lsb-release | cut -d "=" -f 2)
fi

AMLOGIC_TOOL_NAME="aml-flash-tool.sh"
INSTALL_DIR="/usr/local/bin"
RULE="/etc/udev/rules.d/70-persistent-usb-ubuntu14.rules"

echo ""
echo "==============================================="
echo ""
echo "Host PC: $DISTRIB $DISTRIB_RELEASE"
echo ""
echo "==============================================="
echo ""

echo "Removing USB rules..."

if [[ "$DISTRIB_RELEASE" =~ "12" ]]; then
    RULE="/etc/udev/rules.d/70-persistent-usb-ubuntu12.rules"
fi

if [ -f "$RULE" ]; then
    sudo rm -f "$RULE"
    sudo udevadm control --reload-rules
fi

echo "Removing flash-tool..."
if [ -e "$INSTALL_DIR/$AMLOGIC_TOOL_NAME" ]; then
    sudo rm -f "$INSTALL_DIR/$AMLOGIC_TOOL_NAME"
fi

echo "Done!"

