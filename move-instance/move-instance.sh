#!/usr/bin/env bash

# Author: Ryan Tierney
# Date 2022-07-13
# Purpose: Move an instance to another node with the primary goal of migrating from xen to KVM
# Description: This script can move an instance to any node you choose, does not need to be within the same cluster.

# Requirements:
# Install the pv command `sudo apt install pv` on the ganeti master of the source node ( used for a progress bar )
# Ensure you have root ssh-keys setup as follows:
# - Ganeti master of the source node -> source node of where the instance is to be moved from,
# - Ganeti master of the source node -> Destination node of where the instance is to be moved to,
# - Ganeti master of the source node -> Ganeti master of the destination node
# Run this script on the Source node Ganeti master as root.

set -eo pipefail


# Display how to use this script
function usage() {
    if [ -n "$1" ]; then
        echo -e "${RED}👉 $1${CLEAR}\n";
    fi
    echo "Usage: $0 [-i instance] [-d destination node]"
    echo "  -i, --instance           The instance / Virtual machine you would like to move"
    echo "  -d, --destination-node   The node you would like to move the instance to"
    echo ""
    echo "Example: $0 --instance dns01.lan --destination-node kvm02.lan"
    exit 1
}


function get_options {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i|--instance) INSTANCE="$2"; shift ;;
            -d|--destination-node) DESTINATION_NODE="$2"; shift ;;
            *) echo "Unknown parameter passed: $1"; exit 1 ;;
        esac
        shift
    done

    # Check everything is set
    if [ -z "$INSTANCE" ]; then usage "Instance is not set"; fi;
    if [ -z "$DESTINATION_NODE" ]; then usage "Destination node is not set"; fi;
}


function declare_globals {
    declare -ga cleanup_cmds
    instance_info_file=$(mktemp)
    cleanup_cmds+=("rm -f $instance_info_file")
    pre_flight_checks # also declares DESTINATION_MASTER

    # Global Variables
    EXPORT_DIR="/mnt"
    SOURCE_NODE=$(grep '\- primary' "$instance_info_file" | awk '{print $3}')
    SOURCE_MASTER=$(hostname -f)
    KERNEL_PATH=$(grep 'kernel_path' "$instance_info_file" | awk '{print $2}')
    INITRD_PATH=$(grep 'initrd_path' "$instance_info_file" | awk '{print $2}')
    VCPUS=$(grep 'vcpus' "$instance_info_file" | awk '{print $2}')
    MEMORY=$(grep 'maxmem' "$instance_info_file" | awk '{print $2}')
    DISK_SIZE=$(grep 'disk/0' "$instance_info_file" | awk '{print $5}')
    LOGICAL_VOLUME=$(grep 'on primary' "$instance_info_file" | awk '{print $3}')
    VOLUME_GROUP=$(echo "$LOGICAL_VOLUME" | cut -d/ -f1,2,3)
    DESTINATION_LV="${INSTANCE}.disk0"
    EXTRA_NETWORKS=""

    # Set net_queues to spread NIC interrupts across multiple cores ( max is 8 )
    if [ "$VCPUS" -gt 8 ]; then
        NET_QUEUES=8
    else
        NET_QUEUES="$VCPUS"
    fi

    # Check for more interfaces ( up to 8, increase if needed )
    for i in {1..8}; do
        if nic=$(grep -A 8 "nic/${i}:" "$instance_info_file"); then
            local link=$(echo "$nic" | grep "link:" | awk '{print $2}')
            EXTRA_NETWORKS+="--net ${i}:link=${link} "
        fi
    done
}


function cleanup {
    # Cleanup function to be ran at the end or on error / interrupt ( CTRL+C )
    echo "#### Cleaning up"
    for ((i = ${#cleanup_cmds[@]}-1; i >= 0; i--)); do
        echo "Running: ${cleanup_cmds[$i]}"
        eval "${cleanup_cmds[$i]}"
    done
}
trap cleanup ERR SIGINT EXIT


function pre_flight_checks {
    # Confirm we're running on the source_node ganeti master
    if ! gnt-instance info "$INSTANCE" > "$instance_info_file"; then
        echo "Please run this script on the Ganeti master of $INSTANCE";
        exit 1;
    fi
    # Confirm we can ssh the destination node
    if ! ssh "$DESTINATION_NODE" 'exit 0'; then
        echo "Unable to ssh $DESTINATION_NODE"
        exit 1;
    fi
    # Confirm we can ssh to the destination node Ganeti master
    DESTINATION_MASTER=$(ssh "$DESTINATION_NODE" 'gnt-cluster getmaster')
    if ! ssh "$DESTINATION_MASTER" 'exit 0'; then
        echo "Unable to ssh $DESTINATION_MASTER"
        exit 1;
    fi
}


function confirmation_check {
    # Display to the user and send a confirmation prompt
    echo -e "#### Confirm the following looks correct:\n"
    echo "instance: $INSTANCE"
    echo "vcpus: ${VCPUS}"
    echo "net_queues: ${NET_QUEUES}"
    echo "Memory: ${MEMORY}"
    echo "Disk Size: ${DISK_SIZE}"
    echo "Extra networks: ${EXTRA_NETWORKS}"
    echo "Volume Group: ${VOLUME_GROUP}"
    echo "logical volume: ${LOGICAL_VOLUME}"
    echo "kernel_path=${KERNEL_PATH}"
    echo "initrd_path=${INITRD_PATH}"
    echo "Source Ganeti master: $SOURCE_MASTER"
    echo "Source node: $SOURCE_NODE"
    echo "Destination Ganeti master: $DESTINATION_MASTER"
    echo -e "Destination node: ${DESTINATION_NODE}\n"
    read -p 'Continue moving instance (y/n)? ' -n 1 -r CONTINUE_CHOICE
}


function migrate {
    echo -e "\nContinuing\n\n"

    #### Get the Destination node ready, create an lv, mkfs, mount it.
    echo -e "#### Preparing logical volume on ${DESTINATION_NODE} to receive data\n"
    ssh "$DESTINATION_NODE" "lvcreate xenvg --size $DISK_SIZE --name ${DESTINATION_LV} --wipesignatures y --yes --zero y"
    TARGET=$(ssh "$DESTINATION_NODE" "mktemp -d --tmpdir=${EXPORT_DIR}")
    cleanup_cmds+=("ssh $DESTINATION_NODE \"rmdir $TARGET\"")

    echo "Setting up xfs filesystem on remote logical volume"
    ssh "$DESTINATION_NODE" "mkfs.xfs -f ${VOLUME_GROUP}/${DESTINATION_LV}"
    ssh "$DESTINATION_NODE" "mount -t xfs ${VOLUME_GROUP}/$DESTINATION_LV $TARGET"
    cleanup_cmds+=("ssh $DESTINATION_NODE \"if grep -qo $TARGET /proc/mounts; then umount ${TARGET}; fi\"")
    echo -e "Remote disk ready to receive data at: ${DESTINATION_NODE}:${TARGET}\n"

    #### Get the original virtual machine ready
    # Shutdown and rename original instance so we can add a new one with the same name
    echo -e "\n#### Adding 127.0.0.73 ${INSTANCE}_original to /etc/hosts\n"
    echo "127.0.0.73 ${INSTANCE}_original" >> /etc/hosts
    cleanup_cmds+=("sed -i '/127\.0\.0\.73/d' /etc/hosts")
    echo -e "#### Shutting down instance: ${INSTANCE} $(date +%Y-%m-%dT%H:%M:%S)\n"
    gnt-instance shutdown "$INSTANCE"
    echo -e "\n#### Renaming instance: $INSTANCE ${INSTANCE}_original\n"
    gnt-instance rename --no-ip-check "$INSTANCE" "${INSTANCE}_original"

    #### Get the source logical volume ready to be copied over
    # Make a temp directory on the source node and mount the source logical volume to it
    echo -e "\n#### Preparing logical volume on $SOURCE_NODE to be copied\n"
    SOURCE=$(ssh "$SOURCE_NODE" "mktemp -d --tmpdir=${EXPORT_DIR}")
    cleanup_cmds+=("ssh $SOURCE_NODE \"rmdir $SOURCE\"")
    ssh "$SOURCE_NODE" "mount -o ro -t xfs $LOGICAL_VOLUME $SOURCE"
    cleanup_cmds+=("ssh $SOURCE_NODE \"if grep -qo $SOURCE /proc/mounts; then umount ${SOURCE}; fi\"")
    echo -e "Mounted $LOGICAL_VOLUME on ${SOURCE_NODE}:${SOURCE}\n"

    #### Copy data across
    # Copy the filesystem over to the destination node logical volume we setup earlier
    echo -e "\n#### Copying filesystem from ${INSTANCE} to ${DESTINATION_NODE}:${VOLUME_GROUP}/${DESTINATION_LV}\n"
    local fs_size=$(ssh "$SOURCE_NODE" "df -B1 $SOURCE | awk '{print \$3}' | tail -n1")
    ssh "$SOURCE_NODE" "tar -cPf - --one-file-system -C $SOURCE ." | pv -pers "$fs_size" | ssh "$DESTINATION_NODE" "tar -xPf - -C $TARGET"

    # Update the blkid in ${TARGET}/etc/fstab due to creating a new fs with mkfs.xfs ^
    local original_root_uuid=$(ssh "$DESTINATION_NODE" "grep -P '\/\s+' \"${TARGET}/etc/fstab\" | egrep -v '^#' | awk '{print \$1}'")
    local new_root_uuid=$(ssh "$DESTINATION_NODE" "blkid | sed 's/\-\-/\-/g' | grep \"$DESTINATION_LV\" | cut -d' ' -f2")
    ssh "$DESTINATION_NODE" "sed -i s/${original_root_uuid}/${new_root_uuid}/ ${TARGET}/etc/fstab"

    # Unmount disks so we can add an instance
    echo "Unmounting $SOURCE and $TARGET"
    ssh "$DESTINATION_NODE" "umount $TARGET"
    ssh "$SOURCE_NODE" "umount $SOURCE"

    #### Add instance on the destination node adopting the new lv
    echo -e "\n#### Adding instance $INSTANCE on $DESTINATION_NODE\n"
    ssh "$DESTINATION_MASTER" bash <<EOF
        gnt-instance add -t plain \
        --disk 0:adopt="$DESTINATION_LV" \
        $EXTRA_NETWORKS \
        -B memory="$MEMORY",vcpus="$VCPUS" \
        -H kvm:initrd_path="${INITRD_PATH}",kernel_path="${KERNEL_PATH}",virtio_net_queues="${NET_QUEUES}" \
        -o image+bullseye \
        -n "$DESTINATION_NODE" \
        "$INSTANCE"
EOF

   #### Remove the original instance / Logical volume
    echo -e "$INSTANCE is starting up, Confirm you can access it\n"
    read -p "Would you like to remove ${INSTANCE}_original and its Logical Volume? (yes/no) " REMOVE_CHOICE
    REMOVE_CHOICE=$(echo "$REMOVE_CHOICE" | tr '[:upper:]' '[:lower:]')
    if [[ "$REMOVE_CHOICE" == 'yes' ]]; then
        echo -e "\n#### Removing instance ${INSTANCE}_original from $SOURCE_NODE\n"
        ssh "$SOURCE_MASTER" "gnt-instance remove -f ${INSTANCE}_original"
    else
        echo "Not removing ${INSTANCE}_original from $SOURCE_MASTER"
        echo "To remove manually run the following on $SOURCE_MASTER"
        echo "gnt-instance remove -f ${INSTANCE}_original"
    fi
}


function main {
    get_options "$@"
    declare_globals
    confirmation_check
    if [[ "$CONTINUE_CHOICE" =~ ^[Yy]$ ]]; then
        migrate
    else
        echo -e "\nNo Changes made, Exiting."
    fi
}


main "$@"
