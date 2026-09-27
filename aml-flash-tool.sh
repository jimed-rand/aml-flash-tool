#!/bin/bash

set -e -o pipefail

target_img=""
parts="all"
wipe=1
reset="y"
soc=""
uboot_file=""
efuse_file=""
password=""
destroy=0
action="flash"
uart_port=""
uart_baud="115200"
mmc_dev=1
update_return=""
debug=0
simu=0
tui=0
TOOL_PATH="$(dirname "$(readlink -fm "$0")")"
SYSTEM="linux-x86"
EXE=""
tmp_dir=""

show_help() {
    echo "Usage: $0 [options] [path/to/aml_upgrade_package.img]"
    echo "Supported SoC Families:"
    echo "  gxl   : S905X, S905D, S905W, S905L, S805X (p212, p281, p271, B860H, HG680P, etc.)"
    echo "  gxbb  : S905, S905H (p200, p201, Odroid C2, etc.)"
    echo "  gxm   : S912 (q200, q201, Khadas VIM2, etc.)"
    echo "  g12a  : S905X2, S905Y2, S905D2 (Radxa Zero, Khadas VIM3L, SEI510, etc.)"
    echo "  g12b  : S922X, A311D (Khadas VIM3, Odroid N2/N2+, Radxa Zero 2, etc.)"
    echo "  sm1   : S905X3, S905D3, S905Y3 (SEI610, X96 Max+, etc.)"
    echo "  axg   : A113D, A113X (s400, s410, etc.)"
    echo "  txlx  : T962, T962E, T962X"
    echo "  m8    : S802, S805, S812 (Meson8, Meson8b)"
    echo "Options:"
    echo "  --tui, -i                     Launch interactive text user interface"
    echo "  --board=<name>                Target board/device (e.g. p212, b860h, hg680p, radxa-zero)"
    echo "  --soc=<family>                Target SoC family (gxl, gxbb, gxm, g12a, g12b, sm1, axg, txlx, m8)"
    echo "  --img=path/to/image.img        Upgrade image package"
    echo "  --parts=<all|bootloader|...>   Partitions to flash (default: all)"
    echo "  --wipe                         Wipe data and cache partitions (default: 1)"
    echo "  --no-wipe                      Do not wipe data and cache partitions"
    echo "  --reset=<y|n>                  Reset board after burning (default: y)"
    echo "  --uboot-file=path/to/uboot     Override bootloader file"
    echo "  --efuse-file=path/to/efuse     Program eFuse file"
    echo "  --password=path/to/password    Password file for locked USB mode"
    echo "  --destroy                      Erase bootloader and reset board"
    echo "  --erase-bootloader             Erase bootloader on connected device"
    echo "  --reflash-bootloader           Erase and re-flash bootloader on connected device"
    echo "  --mount-emmc, --ums            Access internal eMMC as USB Mass Storage"
    echo "  --mmc-dev=<0|1>                Target MMC device for storage mode (default: 1 for eMMC)"
    echo "  --read-uart[=dev], --uart      Read UART serial console over USB"
    echo "  --baud=<rate>                  UART baud rate (default: 115200)"
    echo "  --debug                        Enable debug messages"
    echo "  --help, -h                     Display this help message"
}

check_file() {
    if [[ "$simu" != "1" ]]; then
        if [[ ! -f "$1" ]]; then
            echo "$1 not found"
            cleanup
            exit 1
        fi
    fi
}

cleanup() {
    print_debug "Cleanup"
    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
        rm -rf "$tmp_dir"
    fi
}

cleanup_trap() {
    cleanup
    exit 1
}

print_debug() {
    if [[ $debug -eq 1 ]]; then
        echo "$1"
    fi
}

detect_system() {
    local host_os
    local host_machine
    host_os=$(uname -s)
    host_machine=$(uname -m)

    if [[ "$host_os" == "Linux" ]]; then
        if [[ "$host_machine" =~ x86_64|i[3-6]86 ]]; then
            SYSTEM="linux-x86"
            EXE=""
        else
            SYSTEM="linux-arm"
            EXE=""
        fi
    else
        SYSTEM="windows"
        EXE=".exe"
    fi
}

run_update_return() {
    local cmd
    local need_spaces
    local arg
    local cmd_exit=0

    cmd="$TOOL_PATH/tools/$SYSTEM/update$EXE 2>/dev/null"
    need_spaces=0
    if [[ "$1" == "bulkcmd" || "$1" == "tplcmd" ]]; then
        need_spaces=1
    fi
    cmd+=" $1"
    shift 1

    for arg in "$@"; do
        if [[ "$arg" =~ [[:space:]] ]]; then
            cmd+=" \"     $arg\""
        else
            if [[ $need_spaces -eq 1 ]]; then
                cmd+=" \"     $arg\""
            else
                cmd+=" $arg"
            fi
        fi
    done

    update_return=""
    print_debug "Command -> $cmd"
    if [[ "$simu" != "1" ]]; then
        update_return=$(eval "$cmd") || cmd_exit=$?
    fi
    print_debug "- Results ---------------------------------------------------"
    print_debug "$update_return"
    print_debug "Exit code: $cmd_exit"
    print_debug "-------------------------------------------------------------"
    return $cmd_exit
}

run_update() {
    local ret=0
    if ! run_update_return "$@"; then
        ret=1
    fi
    if echo "$update_return" | grep -iq "ERR" || echo "$update_return" | grep -iq "failed:"; then
        ret=1
    fi
    return $ret
}

run_update_assert() {
    if ! run_update "$@"; then
        echo "[KO]"
        cleanup
        exit 1
    fi
}

is_in_rom_mode() {
    run_update_return bulkcmd "echo 12345"
    if echo "$update_return" | grep -iq "AmlUsbRom"; then
        return 0
    fi
    return 1
}

check_device_status() {
    detect_system
    local status_output
    local exit_code=0
    status_output=$("$TOOL_PATH/tools/$SYSTEM/update$EXE" identify 7 2>&1) || exit_code=$?
    echo ""
    echo "================ Device Status ================"
    if echo "$status_output" | grep -iq "firmware" || lsusb 2>/dev/null | grep -iq "1b8e:c003"; then
        echo "Status: Connected (Amlogic device detected in USB/MaskROM mode)"
        if lsusb 2>/dev/null | grep -iq "1b8e:c003"; then
            echo "USB Device: $(lsusb 2>/dev/null | grep -i "1b8e:c003" | head -n 1)"
        fi
        echo "Mode: MaskROM / USB update mode"
    else
        echo "Status: Not detected"
        echo "Make sure the board is connected via USB OTG in MaskROM or update mode."
    fi
    echo "==============================================="
    echo ""
}

read_uart() {
    local port="$1"
    local baud="${2:-115200}"
    local available_ports=()

    if [[ -z "$port" ]]; then
        mapfile -t available_ports < <(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
        if [[ ${#available_ports[@]} -eq 0 ]]; then
            echo "No USB UART devices found (/dev/ttyUSB* or /dev/ttyACM*)."
            echo "Ensure your USB serial adapter is connected."
            return 1
        elif [[ ${#available_ports[@]} -eq 1 ]]; then
            port="${available_ports[0]}"
        else
            echo "Multiple USB UART devices found:"
            local idx=1
            for p in "${available_ports[@]}"; do
                echo "  [$idx] $p"
                ((idx++))
            done
            local choice
            read -r -p "Select device [1-${#available_ports[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#available_ports[@]} )); then
                port="${available_ports[$((choice - 1))]}"
            else
                echo "Invalid selection."
                return 1
            fi
        fi
    fi

    if [[ ! -e "$port" ]]; then
        echo "Serial port $port does not exist."
        return 1
    fi

    echo ""
    echo "================ USB UART Monitor ================"
    echo "Port     : $port"
    echo "Baud Rate: $baud"
    echo "Press Ctrl+C to exit."
    echo "=================================================="
    echo ""

    if command -v picocom >/dev/null 2>&1; then
        picocom -q -b "$baud" "$port"
    elif command -v minicom >/dev/null 2>&1; then
        minicom -D "$port" -b "$baud"
    elif command -v tio >/dev/null 2>&1; then
        tio -b "$baud" "$port"
    elif command -v screen >/dev/null 2>&1; then
        screen "$port" "$baud"
    else
        stty -F "$port" "$baud" raw -echo -echoe -echok 2>/dev/null || true
        cat "$port"
    fi
}

mount_emmc_storage() {
    local dev_target="${1:-1}"
    mmc_dev="$dev_target"
    action="mount_emmc"
    parts="none"
    execute_flash
}

erase_bootloader_action() {
    action="erase_bootloader"
    parts="none"
    execute_flash
}

reflash_bootloader_action() {
    action="reflash_bootloader"
    parts="bootloader"
    execute_flash
}

tui_select_image() {
    local input_path
    echo ""
    echo "Enter path to Amlogic upgrade package (.img):"
    read -e -r -p "> " input_path
    if [[ -n "$input_path" ]]; then
        input_path="${input_path/#\~/$HOME}"
        if [[ -f "$input_path" ]]; then
            target_img="$input_path"
            echo "Selected image: $target_img"
        else
            echo "File not found: $input_path"
        fi
    fi
}

tui_select_soc() {
    local choice
    local custom_val
    while true; do
        echo ""
        echo "Select SoC Family or Board:"
        echo "  [1] Auto-detect from image"
        echo "  [2] GXL   (S905X, S905D, S905W, S905L, S805X, P212, B860H, HG680P)"
        echo "  [3] GXBB  (S905, S905H, P200, P201, Odroid C2)"
        echo "  [4] GXM   (S912, Q200, Q201, Khadas VIM2)"
        echo "  [5] G12A  (S905X2, S905Y2, S905D2, Radxa Zero, VIM3L, SEI510)"
        echo "  [6] G12B  (S922X, A311D, Khadas VIM3, Odroid N2/N2+, Radxa Zero 2)"
        echo "  [7] SM1   (S905X3, S905D3, S905Y3, SEI610, X96 Max+)"
        echo "  [8] AXG   (A113D, A113X, S400, S410)"
        echo "  [9] TXLX  (T962, T962E, T962X)"
        echo "  [10] M8   (S802, S805, S812, Meson8, Meson8b)"
        echo "  [11] Custom Board/SoC string"
        echo "  [12] Back"
        read -r -p "Enter choice [1-12]: " choice
        case "$choice" in
            1) soc=""; break ;;
            2) soc="gxl"; break ;;
            3) soc="gxbb"; break ;;
            4) soc="gxm"; break ;;
            5) soc="g12a"; break ;;
            6) soc="g12b"; break ;;
            7) soc="sm1"; break ;;
            8) soc="axg"; break ;;
            9) soc="txlx"; break ;;
            10) soc="m8"; break ;;
            11)
                read -r -p "Enter board/SoC name: " custom_val
                soc="$custom_val"
                break
                ;;
            12) break ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

tui_select_parts() {
    local choice
    local custom_part
    while true; do
        echo ""
        echo "Select Partitions to Flash:"
        echo "  [1] All partitions (default)"
        echo "  [2] Bootloader only"
        echo "  [3] Device Tree (dtb) only"
        echo "  [4] Recovery only"
        echo "  [5] System only"
        echo "  [6] Boot only"
        echo "  [7] None (Load U-Boot into RAM only)"
        echo "  [8] Custom partition name"
        echo "  [9] Back"
        read -r -p "Enter choice [1-9]: " choice
        case "$choice" in
            1) parts="all"; break ;;
            2) parts="bootloader"; break ;;
            3) parts="dtb"; break ;;
            4) parts="recovery"; break ;;
            5) parts="system"; break ;;
            6) parts="boot"; break ;;
            7) parts="none"; break ;;
            8)
                read -r -p "Enter partition name: " custom_part
                parts="$custom_part"
                break
                ;;
            9) break ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

tui_advanced_options() {
    local choice
    local input_val
    while true; do
        local destroy_str="No"
        local debug_str="Disabled"
        if [[ $destroy -eq 1 ]]; then destroy_str="Yes"; fi
        if [[ $debug -eq 1 ]]; then debug_str="Enabled"; fi

        echo ""
        echo "================ Advanced Options ================"
        echo "  [1] Custom Bootloader File : [${uboot_file:-None}]"
        echo "  [2] Custom eFuse File      : [${efuse_file:-None}]"
        echo "  [3] Password File          : [${password:-None}]"
        echo "  [4] Toggle Destroy Mode    : [$destroy_str]"
        echo "  [5] Toggle Debug Mode      : [$debug_str]"
        echo "  [6] Back"
        echo "=================================================="
        read -r -p "Enter choice [1-6]: " choice
        case "$choice" in
            1)
                read -e -r -p "Enter bootloader path (leave empty to clear): " input_val
                input_val="${input_val/#\~/$HOME}"
                uboot_file="$input_val"
                ;;
            2)
                read -e -r -p "Enter efuse file path (leave empty to clear): " input_val
                input_val="${input_val/#\~/$HOME}"
                efuse_file="$input_val"
                ;;
            3)
                read -e -r -p "Enter password file path (leave empty to clear): " input_val
                input_val="${input_val/#\~/$HOME}"
                password="$input_val"
                ;;
            4)
                if [[ $destroy -eq 1 ]]; then destroy=0; else destroy=1; fi
                ;;
            5)
                if [[ $debug -eq 1 ]]; then debug=0; else debug=1; fi
                ;;
            6) break ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

tui_uart_menu() {
    local choice
    local custom_baud
    local selected_baud="115200"
    local selected_port=""
    local available_ports=()

    mapfile -t available_ports < <(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)

    if [[ ${#available_ports[@]} -eq 0 ]]; then
        echo ""
        echo "No USB UART devices found (/dev/ttyUSB* or /dev/ttyACM*)."
        read -r -p "Enter custom serial device path (or leave empty to cancel): " selected_port
        if [[ -z "$selected_port" ]]; then
            return 0
        fi
    elif [[ ${#available_ports[@]} -eq 1 ]]; then
        selected_port="${available_ports[0]}"
    else
        echo ""
        echo "Detected USB UART devices:"
        local idx=1
        for p in "${available_ports[@]}"; do
            echo "  [$idx] $p"
            ((idx++))
        done
        read -r -p "Select port [1-${#available_ports[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#available_ports[@]} )); then
            selected_port="${available_ports[$((choice - 1))]}"
        else
            echo "Invalid selection."
            return 0
        fi
    fi

    echo ""
    echo "Select Baud Rate:"
    echo "  [1] 115200 (Standard Amlogic UART)"
    echo "  [2] 921600 (High-speed / G12A / G12B / SM1)"
    echo "  [3] 57600"
    echo "  [4] 1500000"
    echo "  [5] Custom baud rate"
    read -r -p "Enter choice [1-5, default 1]: " choice
    case "$choice" in
        2) selected_baud="921600" ;;
        3) selected_baud="57600" ;;
        4) selected_baud="1500000" ;;
        5)
            read -r -p "Enter custom baud rate: " custom_baud
            if [[ -n "$custom_baud" ]]; then
                selected_baud="$custom_baud"
            fi
            ;;
        *) selected_baud="115200" ;;
    esac

    read_uart "$selected_port" "$selected_baud"
    read -r -p "Press Enter to continue..."
}

tui_mount_emmc() {
    local choice
    local dev_num=1
    echo ""
    echo "================ eMMC Storage (UMS) ================"
    echo "  [1] eMMC (MMC 1 - Internal Storage)"
    echo "  [2] SD Card (MMC 0 - External Slot)"
    echo "  [3] Back"
    echo "===================================================="
    read -r -p "Enter choice [1-3, default 1]: " choice
    case "$choice" in
        1) dev_num=1 ;;
        2) dev_num=0 ;;
        3) return 0 ;;
        *) dev_num=1 ;;
    esac

    mmc_dev="$dev_num"
    action="mount_emmc"
    if [[ -z "$target_img" && -z "$uboot_file" ]]; then
        echo ""
        echo "Note: If device is in MaskROM mode, an image or uboot file is needed to load U-Boot."
        echo "If device is already running U-Boot, it will enter UMS immediately."
        read -e -r -p "Enter image path (or leave empty if already in U-Boot): " input_path
        if [[ -n "$input_path" ]]; then
            input_path="${input_path/#\~/$HOME}"
            if [[ -f "$input_path" ]]; then
                target_img="$input_path"
            fi
        fi
    fi

    mount_emmc_storage "$mmc_dev"
    read -r -p "Press Enter to continue..."
}

tui_bootloader_menu() {
    local choice
    local input_path
    while true; do
        echo ""
        echo "================ Bootloader Management ================"
        echo "  [1] Erase Bootloader"
        echo "  [2] Re-flash Bootloader (Erase + Write Bootloader)"
        echo "  [3] Set Partitions to Bootloader Only"
        echo "  [4] Back"
        echo "======================================================="
        read -r -p "Enter choice [1-4]: " choice
        case "$choice" in
            1)
                action="erase_bootloader"
                erase_bootloader_action
                read -r -p "Press Enter to continue..."
                break
                ;;
            2)
                action="reflash_bootloader"
                if [[ -z "$target_img" && -z "$uboot_file" ]]; then
                    echo ""
                    read -e -r -p "Enter path to image (.img) or bootloader (.bin): " input_path
                    if [[ -n "$input_path" ]]; then
                        input_path="${input_path/#\~/$HOME}"
                        if [[ -f "$input_path" ]]; then
                            if [[ "$input_path" =~ \.img$ ]]; then
                                target_img="$input_path"
                            else
                                uboot_file="$input_path"
                            fi
                        fi
                    fi
                fi
                reflash_bootloader_action
                read -r -p "Press Enter to continue..."
                break
                ;;
            3)
                parts="bootloader"
                echo "Partitions set to 'bootloader'. Choose 'Start Flashing' to flash."
                read -r -p "Press Enter to continue..."
                break
                ;;
            4) break ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

run_tui() {
    local choice
    while true; do
        local wipe_str="Yes"
        local reset_str="Yes"
        if [[ $wipe -eq 0 ]]; then wipe_str="No"; fi
        if [[ "$reset" == "n" || "$reset" == "N" ]]; then reset_str="No"; fi
        local soc_display="${soc:-Auto-detect}"
        local img_display="${target_img:-<Not selected>}"

        echo ""
        echo "==============================================="
        echo "           Amlogic Flash Tool - TUI"
        echo "==============================================="
        echo " [1]  Image Package         : $img_display"
        echo " [2]  Target SoC / Board    : $soc_display"
        echo " [3]  Partitions to Flash   : $parts"
        echo " [4]  Wipe Data and Cache   : $wipe_str"
        echo " [5]  Reset Board After     : $reset_str"
        echo " [6]  Advanced Options      : (Bootloader, eFuse, Password, Destroy, Debug)"
        echo " [7]  Check Device Status"
        echo " [8]  Mount eMMC Storage (UMS)"
        echo " [9]  Read UART from USB"
        echo " [10] Erase / Re-flash Bootloader"
        echo " [11] Start Flashing"
        echo " [12] Exit"
        echo "==============================================="
        read -r -p "Enter choice [1-12]: " choice
        case "$choice" in
            1) tui_select_image ;;
            2) tui_select_soc ;;
            3) tui_select_parts ;;
            4)
                if [[ $wipe -eq 1 ]]; then wipe=0; else wipe=1; fi
                ;;
            5)
                if [[ "$reset" == "y" || "$reset" == "Y" ]]; then reset="n"; else reset="y"; fi
                ;;
            6) tui_advanced_options ;;
            7)
                check_device_status
                read -r -p "Press Enter to continue..."
                ;;
            8)
                tui_mount_emmc
                ;;
            9)
                tui_uart_menu
                ;;
            10)
                tui_bootloader_menu
                ;;
            11)
                if [[ $destroy -eq 0 && -z "$target_img" ]]; then
                    echo "Please select an image package before flashing."
                    read -r -p "Press Enter to continue..."
                else
                    action="flash"
                    execute_flash
                    break
                fi
                ;;
            12)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter a number between 1 and 12."
                ;;
        esac
    done
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        if [ -t 0 ]; then
            tui=1
            return 0
        else
            show_help
            exit 1
        fi
    fi

    local opt
    local optval
    local soc_val
    local board_val

    for opt do
        optval="${opt#*=}"
        case "${opt%=*}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --tui|-i|--interactive|--menu)
            tui=1
            ;;
        --img)
            target_img="$optval"
            check_file "$target_img"
            ;;
        --soc)
            soc_val=$(echo "$optval" | tr '[:upper:]' '[:lower:]')
            case "$soc_val" in
            s905x|s905d|s905w|s905l|s805x|gxl)
                soc="gxl"
                ;;
            s905|gxbb)
                soc="gxbb"
                ;;
            s912|gxm)
                soc="gxm"
                ;;
            s905x2|s905y2|s905d2|g12a)
                soc="g12a"
                ;;
            s922x|a311d|g12b)
                soc="g12b"
                ;;
            s905x3|s905d3|s905y3|sm1)
                soc="sm1"
                ;;
            a113*|axg)
                soc="axg"
                ;;
            t962*|txlx)
                soc="txlx"
                ;;
            s805|s802|s812|m8|meson8|meson8b)
                soc="m8"
                ;;
            *)
                soc="$optval"
                ;;
            esac
            ;;
        --board)
            board_val=$(echo "$optval" | tr '[:upper:]' '[:lower:]')
            case "$board_val" in
            p212|b860h*|hg680*|hg860*|lepotato|vim1|a95x|tx3|x96|p281|x96-mini|tx3-mini|p271)
                soc="gxl"
                ;;
            p200|p201|odroid-c2)
                soc="gxbb"
                ;;
            q200|q201|vim2|gt1*)
                soc="gxm"
                ;;
            radxa-zero|vim3l|sei510|u200)
                soc="g12a"
                ;;
            vim3|odroid-n2*|radxa-zero2|gt-king*)
                soc="g12b"
                ;;
            sei610|x96-max*|tx3-bz)
                soc="sm1"
                ;;
            s400|s410)
                soc="axg"
                ;;
            *)
                soc="$optval"
                ;;
            esac
            ;;
        --parts)
            parts="$optval"
            ;;
        --wipe)
            wipe=1
            ;;
        --no-wipe)
            wipe=0
            ;;
        --reset)
            reset="$optval"
            ;;
        --uboot-file)
            uboot_file="$optval"
            check_file "$uboot_file"
            ;;
        --efuse-file)
            efuse_file="$optval"
            check_file "$efuse_file"
            ;;
        --password)
            password="$optval"
            check_file "$password"
            ;;
        --destroy)
            destroy=1
            ;;
        --erase-bootloader)
            action="erase_bootloader"
            ;;
        --reflash-bootloader|--erase-reflash-bootloader)
            action="reflash_bootloader"
            ;;
        --mount-emmc|--emmc-storage|--ums)
            action="mount_emmc"
            ;;
        --mmc-dev)
            mmc_dev="$optval"
            ;;
        --read-uart*|--uart*)
            action="read_uart"
            if [[ "$opt" =~ = ]]; then
                uart_port="$optval"
            fi
            ;;
        --baud)
            uart_baud="$optval"
            ;;
        --debug)
            debug=1
            ;;
        *)
            if [[ "$opt" != -* ]]; then
                target_img="$opt"
                check_file "$target_img"
            fi
            ;;
        esac
    done
}

execute_flash() {
    detect_system
    print_debug "SYSTEM = $SYSTEM"
    print_debug "EXE = $EXE"

    if [[ $destroy -eq 0 && "$action" == "flash" ]]; then
        if [[ -z "$target_img" ]]; then
            echo "Missing img argument"
            show_help
            exit 1
        fi
        if [[ -z "$parts" ]]; then
            parts="all"
        fi
    fi

    if [[ "$action" == "reflash_bootloader" ]]; then
        if [[ -z "$target_img" && -z "$uboot_file" ]]; then
            echo "Missing image package or bootloader file for re-flashing bootloader."
            echo "Use --img=path/to/image.img or --uboot-file=path/to/uboot.bin"
            cleanup
            exit 1
        fi
    fi

    if [[ -z "$target_img" && -z "$uboot_file" ]]; then
        if [[ "$action" == "mount_emmc" || "$action" == "erase_bootloader" ]]; then
            if is_in_rom_mode; then
                echo "Board is in MaskROM / USB update mode."
                echo "An image package (--img) or bootloader file (--uboot-file) is required to initialize RAM U-Boot."
                cleanup
                exit 1
            fi
        fi
    fi

    trap cleanup_trap SIGHUP SIGINT SIGTERM

    if [[ "$SYSTEM" == "windows" ]]; then
        tmp_dir="C:/tmp/aml-flash-tool$(date +%H%M%S)"
        mkdir -p "$tmp_dir"
    else
        tmp_dir=$(mktemp -d /tmp/aml-flash-tool-XXXX)
    fi

    local platform_conf_name=""
    local ddr_filename=""
    local uboot_filename=""
    local uboot_comp_filename=""
    local dtb_meson_filename=""
    local dtb_meson1_filename=""
    local dtb_meson1_enc_filename=""
    local ddr_enc_filename=""
    local uboot_enc_filename=""
    local keys_filename=""
    local platform=""
    local bin_params=""
    local ddr_load=""
    local ddr_run=""
    local uboot_down=""
    local uboot_decomp=""
    local uboot_enc_down=""
    local uboot_enc_run=""
    local uboot_load=""
    local uboot_run=""
    local bl2_params=""
    local nb_partitions=0
    local partitions_file=()
    local partitions_name=()
    local partitions_type=()
    local detected_platform=""

    if [[ -n "$target_img" ]]; then
        echo -n "Unpacking image "
        local return_value
        return_value=$("$TOOL_PATH/tools/$SYSTEM/aml_image_v2_packer$EXE" -d "$target_img" "$tmp_dir")
        print_debug "$return_value"
        if ! echo "$return_value" | grep -q "Image unpack OK!"; then
            echo "[KO]"
            cleanup
            exit 1
        fi
        echo "[OK]"

        platform_conf_name=$(awk '/sub_type="platform"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "platform_conf_name = $platform_conf_name"
        ddr_filename=$(awk '/sub_type="DDR"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "ddr_filename = $ddr_filename"
        uboot_filename=$(awk '/sub_type="UBOOT"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "uboot_filename = $uboot_filename"
        uboot_comp_filename=$(awk '/sub_type="UBOOT_COMP"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "uboot_comp_filename = $uboot_comp_filename"
        dtb_meson_filename=$(awk '/sub_type="meson"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "dtb_meson_filename = $dtb_meson_filename"
        dtb_meson1_filename=$(awk '/sub_type="meson1"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "dtb_meson1_filename = $dtb_meson1_filename"
        dtb_meson1_enc_filename=$(awk '/sub_type="meson1_ENC"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "dtb_meson1_enc_filename = $dtb_meson1_enc_filename"
        ddr_enc_filename=$(awk '/sub_type="DDR_ENC"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "ddr_enc_filename = $ddr_enc_filename"
        uboot_enc_filename=$(awk '/sub_type="UBOOT_ENC"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "uboot_enc_filename = $uboot_enc_filename"
        keys_filename=$(awk '/sub_type="keys"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        print_debug "keys_filename = $keys_filename"

        if [[ -n "$platform_conf_name" && -f "$tmp_dir/$platform_conf_name" ]]; then
            platform=$(awk '/Platform:/{gsub("Platform:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "platform = $platform"
            bin_params=$(awk '/BinPara:/{gsub("BinPara:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "bin_params = $bin_params"
            ddr_load=$(awk '/DDRLoad:/{gsub("DDRLoad:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "ddr_load = $ddr_load"
            ddr_run=$(awk '/DDRRun:/{gsub("DDRRun:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "ddr_run = $ddr_run"
            uboot_down=$(awk '/Uboot_down:/{gsub("Uboot_down:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_down = $uboot_down"
            uboot_decomp=$(awk '/Uboot_decomp:/{gsub("Uboot_decomp:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_decomp = $uboot_decomp"
            uboot_enc_down=$(awk '/Uboot_enc_down:/{gsub("Uboot_enc_down:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_enc_down = $uboot_enc_down"
            uboot_enc_run=$(awk '/Uboot_enc_run:/{gsub("Uboot_enc_run:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_enc_run = $uboot_enc_run"
            uboot_load=$(awk '/UbootLoad:/{gsub("UbootLoad:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_load = $uboot_load"
            uboot_run=$(awk '/UbootRun:/{gsub("UbootRun:","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "uboot_run = $uboot_run"
            bl2_params=$(awk '/bl2ParaAddr=/{gsub("bl2ParaAddr=","",$1); print $1}' "$tmp_dir/$platform_conf_name")
            print_debug "bl2_params = $bl2_params"
        fi

        mapfile -t partitions_file < <(awk '/main_type="PARTITION"/{gsub("file=","",$1); gsub(/"/,"",$1); print $1}' "$tmp_dir/image.cfg")
        mapfile -t partitions_name < <(awk '/main_type="PARTITION"/{gsub("sub_type=","",$3); gsub(/"/,"",$3); print $3}' "$tmp_dir/image.cfg")
        mapfile -t partitions_type < <(awk '/main_type="PARTITION"/{gsub("file_type=","",$4); gsub(/"/,"",$4); print $4}' "$tmp_dir/image.cfg")
        nb_partitions=${#partitions_name[@]}
        print_debug "nb_partitions = $nb_partitions"

        if [[ -z "$soc" ]]; then
            detected_platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]')
            if [[ "$detected_platform" =~ gxl|p212|p281|p271 ]]; then
                soc="gxl"
            elif [[ "$detected_platform" =~ gxbb|p200|p201 ]]; then
                soc="gxbb"
            elif [[ "$detected_platform" =~ gxm|q200|q201 ]]; then
                soc="gxm"
            elif [[ "$detected_platform" =~ g12b|s922x|a311d ]]; then
                soc="g12b"
            elif [[ "$detected_platform" =~ sm1|s905x3 ]]; then
                soc="sm1"
            elif [[ "$detected_platform" =~ g12a|g12|u200 ]]; then
                soc="g12a"
            elif [[ "$detected_platform" =~ axg ]]; then
                soc="axg"
            elif [[ "$detected_platform" =~ txlx ]]; then
                soc="txlx"
            elif [[ "$detected_platform" =~ m8|meson8 ]]; then
                soc="m8"
            fi
        fi
    fi

    if [[ -z "$soc" ]]; then
        soc="gxl"
    fi

    if [[ ! "$soc" =~ ^(m8|gxl|gxbb|gxm|axg|txlx|g12a|g12b|sm1)$ ]]; then
        echo "Unknown SoC: $soc"
        cleanup
        exit 1
    fi

    if [[ "$action" == "erase_bootloader" && -z "$target_img" && -z "$uboot_file" ]]; then
        if ! is_in_rom_mode; then
            echo -n "Erasing bootloader "
            run_update bulkcmd "bootloader_is_old"
            run_update_assert bulkcmd "erase_bootloader"
            run_update bulkcmd "store erase boot"
            run_update bulkcmd "amlmmc erase bootloader"
            run_update bulkcmd "mmc dev 1 1"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 2"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 0"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "save"
            echo "[OK]"
            if [[ "$reset" =~ ^[yY]$ ]]; then
                echo -n "Resetting board "
                run_update bulkcmd "reset"
                echo "[OK]"
            fi
            cleanup
            exit 0
        fi
    fi

    if [[ "$action" == "mount_emmc" && -z "$target_img" && -z "$uboot_file" ]]; then
        if ! is_in_rom_mode; then
            echo -n "Initializing MMC device $mmc_dev "
            run_update_assert bulkcmd "mmc dev $mmc_dev"
            echo "[OK]"
            echo ""
            echo "================ USB Mass Storage (UMS) ================"
            echo "MMC device $mmc_dev is now exposed as a USB disk."
            echo "You can view or mount its partitions from the host PC."
            echo "Example host commands:"
            echo "  lsblk"
            echo "  sudo mount /dev/sdX1 /mnt"
            echo "Press Ctrl+C to terminate storage mode."
            echo "========================================================"
            echo ""
            run_update bulkcmd "ums 0 mmc $mmc_dev"
            cleanup
            exit 0
        fi
    fi

    run_update_return identify 7
    if [[ "$simu" != "1" ]]; then
        if ! echo "$update_return" | grep -iq firmware && ! lsusb 2>/dev/null | grep -iq "1b8e:c003"; then
            echo "Amlogic device not found"
            cleanup
            exit 1
        fi
    fi

    local need_password=0
    run_update_return identify 7
    if echo "$update_return" | grep -iq "Password check NG"; then
        need_password=1
    fi
    if [[ $need_password -eq 1 ]]; then
        if [[ -z "$password" ]]; then
            echo "The board is locked with a password, please provide a password using --password option!"
            cleanup
            exit 1
        fi
        echo -n "Unlocking usb interface "
        run_update_assert password "$password"
        run_update_return identify 7
        if echo "$update_return" | grep -iq "Password check OK"; then
            echo "[OK]"
        else
            echo "[KO]"
            echo "It seems you provided an incorrect password!"
            cleanup
            exit 1
        fi
    fi

    local i
    if [[ "$parts" == "all" || "$parts" == "bootloader" || -z "$parts" || "$parts" == "none" ]]; then
        if ! is_in_rom_mode; then
            echo -n "Rebooting the board "
            run_update bulkcmd "bootloader_is_old"
            run_update_assert bulkcmd "erase_bootloader"
            if [[ $destroy -eq 1 ]]; then
                run_update bulkcmd "store erase boot"
                run_update bulkcmd "amlmmc erase 1"
                run_update bulkcmd "nand erase 0 4096"
            fi
            run_update bulkcmd "reset"
            if [[ $destroy -eq 1 ]]; then
                echo "[OK]"
                cleanup
                exit 0
            fi
            for ((i = 1; i <= 8; i++)); do
                echo -n "."
                sleep 1
            done
            echo "[OK]"
        else
            if [[ $destroy -eq 1 ]]; then
                echo "Seems board is already in usb mode, nothing to do more..."
                cleanup
                exit 0
            fi
        fi
    fi

    if [[ $destroy -eq 1 ]]; then
        cleanup
        exit 0
    fi

    need_password=0
    run_update_return identify 7
    if echo "$update_return" | grep -iq "Password check NG"; then
        need_password=1
    fi
    if [[ $need_password -eq 1 ]]; then
        if [[ -z "$password" ]]; then
            echo "The board is locked with a password, please provide a password using --password option!"
            cleanup
            exit 1
        fi
        echo -n "Unlocking usb interface "
        run_update_assert password "$password"
        run_update_return identify 7
        if echo "$update_return" | grep -iq "Password check OK"; then
            echo "[OK]"
        else
            echo "[KO]"
            echo "It seems you provided an incorrect password!"
            cleanup
            exit 1
        fi
    fi

    local secured=0
    local value=0
    local reg_val=""

    if [[ "$soc" == "gxl" || "$soc" == "gxbb" || "$soc" == "gxm" ]]; then
        run_update_return rreg 4 0xc8100228
        reg_val=$(echo "$update_return" | grep -i c8100228 | awk -F: '{gsub(/ /,"",$2);print $2}')
        if [[ -n "$reg_val" ]]; then
            value=$(( 0x$reg_val & 0x10 ))
        fi
    elif [[ "$soc" == "axg" || "$soc" == "txlx" || "$soc" == "g12a" || "$soc" == "g12b" || "$soc" == "sm1" ]]; then
        run_update_return rreg 4 0xff800228
        reg_val=$(echo "$update_return" | grep -i ff800228 | awk -F: '{gsub(/ /,"",$2);print $2}')
        if [[ -n "$reg_val" ]]; then
            value=$(( 0x$reg_val & 0x10 ))
        fi
    elif [[ "$soc" == "m8" ]]; then
        run_update_return rreg 4 0xd9018048
        reg_val=$(echo "$update_return" | grep -i d9018048 | awk -F: '{gsub(/ /,"",$2);print $2}')
        if [[ -n "$reg_val" ]]; then
            value=$(( 0x$reg_val & 0x80 ))
        fi
    fi

    if [[ $value -ne 0 ]]; then
        secured=1
        echo "Board is in secure mode"
    fi

    local bootloader_file=""
    local dtb_file=""
    local ddr=""
    local fip=""
    local bl2=""
    local tpl=""

    if [[ "$parts" == "all" || "$parts" == "bootloader" || "$parts" == "none" ]]; then
        if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx)$ ]]; then
            ddr="$TOOL_PATH/tools/datas/usbbl2runpara_ddrinit.bin"
            fip="$TOOL_PATH/tools/datas/usbbl2runpara_runfipimg.bin"
            check_file "$ddr"
            check_file "$fip"
        elif [[ "$soc" == "m8" ]]; then
            fip="$TOOL_PATH/tools/datas/decompressPara_4M.dump"
            check_file "$fip"
        fi

        if [[ -z "$bootloader_file" ]]; then
            if [[ -n "$uboot_file" && -f "$uboot_file" ]]; then
                bootloader_file="$uboot_file"
            else
                for ((i = 0; i < nb_partitions; i++)); do
                    if [[ "${partitions_name[$i]}" == "bootloader" ]]; then
                        bootloader_file="$tmp_dir/${partitions_file[$i]}"
                        break
                    fi
                done
            fi
        fi

        if [[ -z "$dtb_file" ]]; then
            if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx|g12a|g12b|sm1)$ ]]; then
                for ((i = 0; i < nb_partitions; i++)); do
                    if [[ "${partitions_name[$i]}" == "_aml_dtb" ]]; then
                        dtb_file="$tmp_dir/${partitions_file[$i]}"
                        break
                    fi
                done
            elif [[ "$soc" == "m8" ]]; then
                dtb_file="$tmp_dir/$dtb_meson_filename"
            fi
        fi

        if [[ -z "$dtb_file" ]]; then
            if [[ -n "$dtb_meson_filename" && -f "$tmp_dir/$dtb_meson_filename" ]]; then
                dtb_file="$tmp_dir/$dtb_meson_filename"
            elif [[ -n "$dtb_meson1_filename" && -f "$tmp_dir/$dtb_meson1_filename" ]]; then
                dtb_file="$tmp_dir/$dtb_meson1_filename"
            fi
        fi

        print_debug "bootloader_file = $bootloader_file"
        print_debug "dtb_file = $dtb_file"

        if [[ -n "$bootloader_file" ]]; then
            check_file "$bootloader_file"
        fi
        if [[ -n "$dtb_file" ]]; then
            check_file "$dtb_file"
        fi

        if [[ -z "$uboot_file" ]]; then
            if [[ $secured -eq 0 ]]; then
                bl2="$tmp_dir/$ddr_filename"
                if [[ -z "$uboot_comp_filename" ]]; then
                    tpl="$tmp_dir/$uboot_filename"
                else
                    tpl="$tmp_dir/$uboot_comp_filename"
                fi
            else
                bl2="$tmp_dir/$ddr_enc_filename"
                tpl="$tmp_dir/$uboot_enc_filename"
                if [[ -z "$ddr_enc_filename" || -z "$uboot_enc_filename" ]]; then
                    echo "Your board is secured but the image you want to flash does not contain any signed bootloader!"
                    echo "Please check, flashing cannot continue..."
                    cleanup
                    exit 1
                fi
            fi
        else
            print_debug "uboot_file = $uboot_file"
            if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx)$ ]]; then
                bl2="$tmp_dir/uboot_file_bl2.bin"
                tpl="$tmp_dir/uboot_file_tpl.bin"
                dd if="$uboot_file" of="$bl2" bs=49152 count=1 &>/dev/null
                dd if="$uboot_file" of="$tpl" bs=49152 skip=1 &>/dev/null
            else
                bl2="$tmp_dir/$ddr_filename"
                tpl="$uboot_file"
            fi
        fi

        if [[ -n "$bl2" ]]; then
            check_file "$bl2"
        fi
        if [[ -n "$tpl" ]]; then
            check_file "$tpl"
        fi

        local usb_protocol=""
        echo -n "Initializing ddr "
        if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx)$ ]]; then
            run_update_assert cwr "$bl2" "$ddr_load"
            run_update_assert write "$ddr" "$bl2_params"
            run_update_assert run "$ddr_run"
            for ((i = 1; i <= 8; i++)); do
                echo -n "."
                sleep 1
            done
            run_update_return identify 7
            if ! echo "$update_return" | grep -iq firmware && ! lsusb 2>/dev/null | grep -iq "1b8e:c003"; then
                echo "[KO]"
                cleanup
                exit 1
            fi
            usb_protocol=$(echo "$update_return" | awk -F- '{print $4}')
            if [[ "$usb_protocol" == "8" ]]; then
                run_update_assert run "$bl2_params"
            fi
        elif [[ "$soc" =~ ^(g12a|g12b|sm1)$ ]]; then
            run_update_assert write "$tpl" "$ddr_load" 0x10000
            run_update_assert run "$ddr_load"
            for ((i = 1; i <= 8; i++)); do
                echo -n "."
                sleep 1
            done
        elif [[ "$soc" == "m8" ]]; then
            for ((i = 1; i <= 6; i++)); do
                echo -n "."
                sleep 1
            done
            run_update_assert cwr "$bl2" "$ddr_load"
            run_update_assert run "$ddr_run"
            for ((i = 1; i <= 8; i++)); do
                echo -n "."
                sleep 1
            done
        fi
        echo "[OK]"

        echo -n "Running u-boot "
        if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx)$ ]]; then
            run_update_assert write "$bl2" "$ddr_load"
            run_update_assert write "$fip" "$bl2_params"
            run_update_assert write "$tpl" "$uboot_load"
            if [[ "$usb_protocol" == "8" ]]; then
                run_update_assert run "$bl2_params"
            else
                run_update_assert run "$uboot_run"
            fi
        elif [[ "$soc" =~ ^(g12a|g12b|sm1)$ ]]; then
            run_update_assert bl2_boot "$tpl"
        elif [[ "$soc" == "m8" ]]; then
            run_update_assert write "$fip" "$bin_params"
            if [[ $secured -eq 0 ]]; then
                run_update_assert write "$tpl" 0x00400000
                run_update_assert run "$uboot_decomp"
                for ((i = 1; i <= 13; i++)); do
                    echo -n "."
                    sleep 1
                done
                local value_hex
                value_hex=$(printf "%X\n" "$((bin_params + 0x18))")
                run_update_return rreg 4 "0x$value_hex"
                local jump_addr
                jump_addr="0x$(echo "$update_return" | awk -F: '{gsub(/ /,"",$2);print $2}')"
                print_debug "Jumping to $jump_addr"
                run_update_assert run "$jump_addr"
            else
                run_update_assert write "$tpl" "$uboot_enc_down"
                run_update_assert run "$uboot_enc_run"
                for ((i = 1; i <= 8; i++)); do
                    echo -n "."
                    sleep 1
                done
            fi
        fi
        for ((i = 1; i <= 8; i++)); do
            echo -n "."
            sleep 1
        done
        echo "[OK]"

        run_update bulkcmd "echo 12345"

        if [[ "$action" == "mount_emmc" ]]; then
            echo -n "Initializing MMC device $mmc_dev "
            run_update_assert bulkcmd "mmc dev $mmc_dev"
            echo "[OK]"
            echo ""
            echo "================ USB Mass Storage (UMS) ================"
            echo "MMC device $mmc_dev is now exposed as a USB disk."
            echo "You can view or mount its partitions from the host PC."
            echo "Example host commands:"
            echo "  lsblk"
            echo "  sudo mount /dev/sdX1 /mnt"
            echo "Press Ctrl+C to terminate storage mode."
            echo "========================================================"
            echo ""
            run_update bulkcmd "ums 0 mmc $mmc_dev"
            cleanup
            exit 0
        fi

        if [[ "$action" == "erase_bootloader" ]]; then
            echo -n "Erasing bootloader "
            run_update bulkcmd "bootloader_is_old"
            run_update_assert bulkcmd "erase_bootloader"
            run_update bulkcmd "store erase boot"
            run_update bulkcmd "amlmmc erase bootloader"
            run_update bulkcmd "mmc dev 1 1"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 2"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 0"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "save"
            echo "[OK]"
            if [[ "$reset" =~ ^[yY]$ ]]; then
                echo -n "Resetting board "
                run_update bulkcmd "reset"
                echo "[OK]"
            fi
            cleanup
            exit 0
        fi

        if [[ "$action" == "reflash_bootloader" ]]; then
            echo -n "Erasing existing bootloader "
            run_update bulkcmd "bootloader_is_old"
            run_update_assert bulkcmd "erase_bootloader"
            run_update bulkcmd "store erase boot"
            run_update bulkcmd "amlmmc erase bootloader"
            run_update bulkcmd "mmc dev 1 1"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 2"
            run_update bulkcmd "mmc erase 0 0x2000"
            run_update bulkcmd "mmc dev 1 0"
            run_update bulkcmd "mmc erase 0 0x2000"
            echo "[OK]"

            if [[ -n "$dtb_file" && -f "$dtb_file" ]]; then
                run_update_assert mwrite "$dtb_file" mem dtb normal
            fi

            if [[ -z "$bootloader_file" || ! -f "$bootloader_file" ]]; then
                if [[ -n "$uboot_file" && -f "$uboot_file" ]]; then
                    bootloader_file="$uboot_file"
                fi
            fi

            if [[ -z "$bootloader_file" || ! -f "$bootloader_file" ]]; then
                echo "Bootloader file not found!"
                cleanup
                exit 1
            fi

            echo -n "Writing new bootloader "
            run_update_assert partition bootloader "$bootloader_file"
            echo "[OK]"

            run_update bulkcmd "setenv upgrade_step 1"
            run_update bulkcmd "save"

            if [[ "$reset" =~ ^[yY]$ ]]; then
                echo -n "Resetting board "
                run_update bulkcmd "burn_complete 1"
                echo "[OK]"
            fi
            cleanup
            exit 0
        fi

        if [[ "$soc" =~ ^(gxl|gxbb|gxm|axg|txlx|g12a|g12b|sm1)$ ]]; then
            if [[ $secured -eq 1 ]]; then
                if [[ -n "$dtb_meson1_enc_filename" && -f "$tmp_dir/$dtb_meson1_enc_filename" ]]; then
                    run_update_assert mwrite "$tmp_dir/$dtb_meson1_enc_filename" mem dtb normal
                fi
            else
                if [[ -n "$dtb_meson1_filename" && -f "$tmp_dir/$dtb_meson1_filename" ]]; then
                    run_update_assert mwrite "$tmp_dir/$dtb_meson1_filename" mem dtb normal
                elif [[ -n "$dtb_meson_filename" && -f "$tmp_dir/$dtb_meson_filename" ]]; then
                    run_update_assert mwrite "$tmp_dir/$dtb_meson_filename" mem dtb normal
                elif [[ -n "$dtb_file" && -f "$dtb_file" ]]; then
                    run_update_assert mwrite "$dtb_file" mem dtb normal
                fi
            fi
            if [[ "$parts" != "none" ]]; then
                echo -n "Create partitions "
                if [[ $wipe -eq 1 ]]; then
                    run_update_assert bulkcmd "disk_initial 1"
                else
                    run_update_assert bulkcmd "disk_initial 0"
                fi
                echo "[OK]"

                if [[ -n "$dtb_file" && -f "$dtb_file" ]]; then
                    echo -n "Writing device tree "
                    run_update_assert partition _aml_dtb "$dtb_file"
                    echo "[OK]"
                fi

                if [[ -n "$bootloader_file" && -f "$bootloader_file" ]]; then
                    echo -n "Writing bootloader "
                    run_update_assert partition bootloader "$bootloader_file"
                    echo "[OK]"
                fi
            fi
        else
            if [[ "$parts" != "none" ]]; then
                echo -n "Creating partitions "
                if [[ $wipe -eq 1 ]]; then
                    run_update bulkcmd "disk_initial 3"
                    run_update_assert bulkcmd "disk_initial 2"
                else
                    run_update_assert bulkcmd "disk_initial 0"
                fi
                echo "[OK]"

                echo -n "Writing bootloader "
                run_update_assert partition bootloader "$bootloader_file"
                echo "[OK]"

                echo -n "Writing device tree "
                run_update_assert mwrite "$dtb_file" mem dtb normal
                echo "[OK]"
            fi
        fi

        if [[ "$parts" != "none" ]]; then
            run_update bulkcmd "setenv upgrade_step 1"
            run_update bulkcmd "save"
        fi
        if [[ "$soc" == "m8" ]]; then
            run_update bulkcmd "save_setting"
        fi
    fi

    if [[ $wipe -eq 1 ]]; then
        run_update bulkcmd "setenv firstboot 1"
        run_update bulkcmd "save"
        run_update bulkcmd "rpmb_reset"
    fi
    if [[ "$soc" != "m8" ]]; then
        if [[ $wipe -eq 1 ]]; then
            echo -n "Wiping  data partition "
            run_update bulkcmd "amlmmc erase data"
            run_update bulkcmd "nand erase.part data"
            echo "[OK]"

            echo -n "Wiping  cache partition "
            run_update bulkcmd "amlmmc erase cache"
            run_update bulkcmd "nand erase.part cache"
            echo "[OK]"
        fi
    fi

    local part_name=""
    local part_file=""
    local part_type=""
    local target_file=""
    local target_type=""

    for ((i = 0; i < nb_partitions; i++)); do
        part_name="${partitions_name[$i]}"
        part_file="${partitions_file[$i]}"
        part_type="${partitions_type[$i]}"
        if [[ "$parts" == "all" || "$parts" == "$part_name" || ( "$parts" == "dtb" && "$part_name" == "_aml_dtb" ) ]]; then
            if [[ "$part_name" == "bootloader" || ( "$part_name" == "_aml_dtb" && "$parts" != "dtb" ) ]]; then
                continue
            fi
            target_file=""
            target_type=""
            if [[ "$part_name" == "_aml_dtb" ]]; then
                target_file="$dtb_file"
                target_type="dtb"
            fi
            if [[ -z "$target_file" ]]; then
                target_file="$tmp_dir/$part_file"
            fi
            if [[ -z "$target_type" ]]; then
                target_type="$part_type"
            fi
            check_file "$target_file"
            if [[ "$parts" == "dtb" ]]; then
                echo -n "Writing dtb partition "
            else
                echo -n "Writing $part_name partition "
            fi
            run_update_assert partition "$part_name" "$target_file" "$target_type"
            echo "[OK]"
        fi
    done

    if [[ -n "$efuse_file" ]]; then
        check_file "$efuse_file"
        echo -n "Programming efuses "
        run_update_assert write "$efuse_file" 0x03000000
        if [[ "$soc" == "m8" ]]; then
            run_update_assert bulkcmd "efuse secure_boot_set 0x03000000"
        else
            run_update_assert bulkcmd "efuse amlogic_set 0x03000000"
        fi
        echo "[OK]"
    fi

    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
        rm -rf "$tmp_dir"
    fi

    if [[ "$parts" != "none" ]]; then
        if [[ -z "$reset" ]]; then
            while true; do
                read -r -p "Do you want to reset the board? y/n [n]? " reset
                if [[ "$reset" =~ ^[yYnN]$ ]]; then
                    break
                fi
            done
        fi
        if [[ "$reset" =~ ^[yY]$ ]]; then
            echo -n "Resetting board "
            run_update bulkcmd "burn_complete 1"
            echo "[OK]"
        fi
    else
        echo "Uboot is now loaded into your board!"
        echo "You can use $TOOL_PATH/tools/$SYSTEM/update$EXE bulkcmd \"any uboot command\" to control uboot"
        echo "Examples:"
        echo "   - Select eMMC device:"
        echo "   update bulkcmd \"mmc dev 1\""
        echo "   - Read first block of eMMC at address 0x03000000"
        echo "   update bulkcmd \"mmc read 0x03000000 0 1\""
        echo "   - Save 512 bytes from address to 0x03000000 to host pc in file emmc.bin"
        echo "   update mread mem 0x03000000 normal 512 emmc.bin"
        echo "   - Write a file from host PC to address 0x03000000"
        echo "   update mwrite file.bin mem 0x03000000 normal"
        echo "   - Write to eMMC first block from address 0x03000000"
        echo "   update bulkcmd \"mmc write 0x03000000 0 1\""
        echo "   - Booting a kernel"
        echo "   update bulkcmd \"disk_initial 0\""
        echo "   update bulkcmd \"env default -a\""
        echo "   update bulkcmd \"run storeargs\""
        echo "   update bulkcmd \"run bootcmd\""
    fi
}

parse_args "$@"

if [[ $tui -eq 1 ]]; then
    run_tui
elif [[ "$action" == "read_uart" ]]; then
    read_uart "$uart_port" "$uart_baud"
elif [[ "$action" == "mount_emmc" ]]; then
    mount_emmc_storage "$mmc_dev"
elif [[ "$action" == "erase_bootloader" ]]; then
    erase_bootloader_action
elif [[ "$action" == "reflash_bootloader" ]]; then
    reflash_bootloader_action
else
    execute_flash
fi
