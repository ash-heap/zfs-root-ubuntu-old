#!/bin/bash


RESULTS="$(mktemp)"
# function finish {
#     # clear
#     rm "$RESULTS"
# }
# trap finish EXIT






DEBUG=1

BACKTITLE="Installing Ubuntu 18.04 on ZFS root pool..."



# drives=($(ls /dev/sd* | grep '/dev/sd\w$' | awk '!/^ / && NF {print $1; print $1}'))
# drives=($(lsblk --paths --noheadings --output NAME,SIZE -r | grep -vP '/dev/sd\w\d'))
# drives=($(lsblk --paths --noheadings --output NAME,SIZE -r | grep -vP '/dev/sd\w\d' | awk '{printf "\"%s\"  \"%s\"\n",$1,$2}'))
# whiptail --title "Select root pool drive." --menu "Drive will be completly erased." 16 78 5 "${drives[@]}"
# echo "${drives[@]}"
#


function exit_no_changes {
    dialog \
        --title "Installation Canceled" \
        --backtitle "$BACKTITLE"  \
        --msgbox "No changes made to disk." 6 40
    exit 0;
}


function list_drives() {
    lsblk --noheadings --output NAME | grep -vP 'sd\w\d'
}


function sdx_to_id() {
    find /dev/disk/by-id -name '*' \
        -exec echo -n {}" " \; -exec readlink -f {} \; | \
        awk -v sdx="$1" \
        '($2 ~ sdx"$") && ($1 !~ "^/dev/disk/by-id/wwn"){print $1}'
    }


function list_interfaces() {
    ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2}'
}


function drive_size() {
    lsblk "/dev/$1" --noheadings --output SIZE | head -n 1
}


function create_root_pool {
    local drives=()
    for sdx in $(list_drives); do
        id=$(sdx_to_id "$sdx")
        drives+=("$id")
        drives+=("$(printf "%3s  %6s  %s" "$sdx" "$(drive_size "$sdx")" "$id")")
        drives+=(OFF)
    done
    msg="Select drives to use for the root pool.  "
    msg+="Only single drive and mirrored configurations are supported at " \
    msg+="this time.  ALL DATA on chosen drives will be LOST."
    dialog \
        --title "Select Root Drives" \
        --backtitle "$BACKTITLE" \
        --ok-button "Format Drives" \
         --notags --separate-output \
        --checklist "$msg" \
        $((8+${#root_drives[@]})) 90 ${#root_drives[@]} "${drives[@]}" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        exit_no_changes
    fi
    mapfile -t root_drives < "$RESULTS"
    if [ "${#root_drives[@]}" -eq 0 ]; then
        msg="No drives where selected.  "
        msg+="Would you like to cancel the installation?"
        dialog \
            --title "No Drives Selected" \
            --backtitle "$BACKTITLE"  \
            --yesno "$msg" 7 60
        EXIT=$?
        if [ "$EXIT" -eq 1 ]; then
            create_root_pool
            return 0
        else
            exit_no_changes
        fi
    elif [ "${#root_drives[@]}" -eq 1 ]; then
        msg="All data will be lost on drive:\\n\\n"
        msg+="    ${root_drives[0]}\\n\\n"
        msg+="Single drive layouts do not have any redundancy against drive " \
        msg+="failures.\\n\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --yesno "$msg" 12 70;
        then
            prepare_drive "${root_drives[0]}"
            cmd zpool create -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" "${root_drives[0]}-part1"
        else
            exit_no_changes
        fi
    else
        msg="All data will be lost on drives:\\n\\n"
        for i in "${root_drives[@]}"; do
            msg+="    $i\\n"
        done
        msg+="\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --yesno "$msg" $((8+${#root_drives[@]})) 70;
        then
            local partitions=()
            for drive in "${root_drives[@]}"; do
                prepare_drive "$drive"
                partitions+=("$drive""-part1")
            done
            cmd zpool create -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" mirror "${partitions[@]}"
        else
            exit_no_changes
        fi
    fi
}


RPOOL="rpool"



function set_root_pool() {
    msg="While \"rpool\" is standard among automated installation's you may
    whish to use the hostname instead.\\n\\n"
    msg+="Specify the name of the ROOT ZFS pool:"
    dialog \
        --title "ROOT Pool Name" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        exit_no_changes
    fi
    RPOOL="$(<"$RESULTS")"
    echo "$RPOOL"
    while [[ ("$RPOOL" == "") || ("$RPOOL" =~ [^a-zA-Z0-9]) ]]; do
        msg="Pool names must consists only of alphanumeric strings " \
        msg+="without spaces.\\n\\nSpecify the name of the ROOT ZFS pool:"
        dialog \
            --title "ROOT Pool Name" \
            --backtitle "$BACKTITLE"  \
            --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
        EXIT=$?
        if [ "$EXIT" -ne 0 ]; then
            exit_no_changes
        fi
        RPOOL=$(<"$RESULTS")
    done
}

function prepare_drive() {
    cmd apt-add-repository universe
    cmd apt update
    cmd apt install --yes debootstrap gdisk zfs-initramfs mdadm
    cmd mdadm --zero-superblock --force "$1"
    cmd sgdisk --zap-all "$1"
    cmd sgdisk     -n3:1M:+512M -t3:EF00 "$1"
    cmd sgdisk     -n1:0:0      -t1:BF01 "$1"
}


function cmd {
    # Log command.
    if [ "$DEBUG" -ne 0 ]; then
        echo "$@" >>zfs_root.log
    # Run command.
    else
        $(echo "$@")
    fi
}

# Verify root.
# if [[ $EUID -ne 0 ]]; then
#     # echo "$0 must be run as root."
#     dialog \
#         --title "Root Required" \
#         --backtitle "$BACKTITLE" \
#         --msgbox "$0 must be run as root." 7 60
#     # exit 1
# fi

function main() {
    set_root_pool
    create_root_pool
}

main
# mapfile -t root_drives < <(whiptail \
#     --title "Select Root Drives" \
#     --backtitle "$BACKTITLE" \
#     --ok-button "Format Drives" \
#     --checklist "$msg" \
#     16 90 8 "${drives[@]}" --notags --separate-output  3>&1 1>&2 2>&3)
# echo $?
#
# echo "${#root_drives[@]}"
# $DEBUG "$root_drives"
# echo "${root_drives[@]}"




