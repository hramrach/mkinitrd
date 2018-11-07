#!/bin/bash
#
#%stage: filesystem
#%depends: resume
#
#%programs: /sbin/fsck $rootfsck
#%if: ! "$root_already_mounted"
#%dontshow
#
##### mounting of the root device
##
## When all the device drivers and other systems have been successfully
## activated and in case the root filesystem has not been mounted yet,
## this will do it and fsck it if neccessary.
##
## Command line parameters
## -----------------------
##
## ro           mount the root device read-only
## 

discover_root() {
    local root devn
    case "$rootdev" in
        *:/*) root= ;;
        /dev/nfs) root= ;;
        /dev/*) root=${rootdev#/dev/} ;;
    esac
    if [ -z "$root" ]; then
        return 0
    fi
    if check_for_device $rootdev root ; then
        # Get major:minor number of the device node
        devn=$(devnumber $rootdev)
    fi
    if [ ! "$devn" ]; then
        if [ ! "$1" ]; then
            # try the stored fallback device
            echo \
"Could not find $rootdev.
Want me to fall back to $fallback_rootdev? (Y/n) "
            read y
            if [ "$y" = n ]; then
                return 1
            fi
            rootdev="$fallback_rootdev"
            if ! discover_root x ; then
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

read_only=${cmd_ro}

# And now for the real thing
if ! discover_root ; then
    echo "not found -- exiting to /bin/sh"
    cd /
    PATH=$PATH PS1='$ ' /bin/sh -i
fi

sysdev=$(/sbin/udevadm info -q path -n $rootdev)
# Fallback if rootdev is not controlled by udev
if [ $? -ne 0 ] && [ -b "$rootdev" ] ; then
    devn=$(devnumber $rootdev)
    maj=$(devmajor $devn)
    min=$(devminor $devn)
    if [ -e /sys/dev/block/$maj:$min ] ; then
        sysdev=$(cd -P /sys/dev/block/$maj:$min ; echo $PWD)
    fi
    unset devn
    unset maj
    unset min
fi
if [ -z "$rootfstype" -a -x /sbin/udevadm -a -n "$sysdev" ]; then
    eval $(/sbin/udevadm info -q env -p $sysdev | sed -n '/ID_FS_TYPE/p')
    rootfstype=$ID_FS_TYPE
    [ -n "$rootfstype" ] && [ "$rootfstype" = "unknown" ] && rootfstype=
    ID_FS_TYPE=
fi

# check filesystem if possible
if [ -z "$rootfstype" ]; then
    echo "invalid root filesystem -- exiting to /bin/sh"
    cd /
    PATH=$PATH PS1='$ ' /bin/sh -i
    # skip filesystem check of shared read-only root filesystems
elif [ -n "$cmd_readonlyroot" -a -z "$cmd_noreadonlyroot" ] ; then
    echo "Skipping fsck of shared read-only root filesystem."
    read_only=1
elif [ 0$rootfs_passno -lt 1 -o -n "$cmd_fastboot" ] ; then
    # filesystem has fs_passno (last field in /etc/fstab) == 0, therefore
    # it shouldn't be fscked
    ROOTFS_FSCK=0
    export ROOTFS_FSCK
    ROOTFS_FSTYPE=$rootfstype
    export ROOTFS_FSTYPE
# don't run fsck in the kdump kernel
elif [ -x "$rootfsck" ] && ! [ -s /proc/vmcore ] ; then
    # fsck is unhappy without it
    echo "$rootdev / $rootfstype defaults 1 1" > /etc/fstab
    # Display progress bar if possible 
    fsckopts="-V -a"
    [ "$forcefsck" ] && fsckopts="$fsckopts -f"
    [ "`/sbin/showconsole`" = "/dev/tty1" ] && fsckopts="$fsckopts -C"
    # Check external journal for reiserfs
    [ "$rootfstype" = "reiserfs" -a -n "$journaldev" ] && fsckopts="-j $journaldev $fsckopts"
    fsck -t $rootfstype $fsckopts $rootdev
    # Return the fsck status
    ROOTFS_FSCK=$?
    export ROOTFS_FSCK
    ROOTFS_FSTYPE=$rootfstype
    export ROOTFS_FSTYPE
    if [ $ROOTFS_FSCK -gt 1 -a $ROOTFS_FSCK -lt 4 ]; then
        # reboot needed
        echo "fsck succeeded, but reboot is required."
        echo "Rebooting system."
        /bin/reboot -d -f
    elif [ $ROOTFS_FSCK -gt 3 ] ; then
        echo "fsck failed. Mounting root device read-only."
        read_only=1
    else
        if [ "$read_only" ]; then
            echo "fsck succeeded. Mounting root device read-only."
        else
            echo "fsck succeeded. Mounting root device read-write."
        fi
    fi
fi

opt="-o rw"
[ "$read_only" ] && opt="-o ro"

# mount the actual root device on /root
echo "Mounting root $rootdev"
# check external journal
[ "$rootfstype" = "xfs" -a -n "$journaldev" ] && opt="${opt},logdev=$journaldev"
[ "$rootfstype" = "reiserfs" -a -n "$journaldev" ] && opt="${opt},jdev=$journaldev"

# use options from /etc/fstab but allow that to be overwritten by the
# "rootflags" command line
if [ -n "$rootflags" ] ; then
    opt="${opt},$rootflags"
else
    if [ -n "$rootfsopts" ] ; then
        opt="${opt},$rootfsopts"
    fi
fi

retry_mount()
{
    local timeout=$udev_timeout
    local retval=0

    echo -n "Waiting for $rootdev to become available: "
    while [ $timeout -gt 0 ]; do
        if [ $timeout -gt 1 ]; then
            mount $opt $rootdev /root 2>/dev/null
        else
            # print errors from the last attempt
            mount $opt $rootdev /root
        fi
        retval=$?
        if [ $retval -eq 0 ]; then
            echo " ok"
            break
        fi
        sleep 1
        echo -n "."
        timeout=$(( $timeout - 1 ))
    done
    return $retval
}

[ -n "$rootfstype" ] && opt="${opt} -t $rootfstype"
echo mount $opt $rootdev /root
mount $opt $rootdev /root
mount_result=$?
if [ $mount_result -ne 0 -a "$rootfstype" = "nfs" ]; then
    # When using nfs, there is no device node to wait for (cf. discover_root()
    # above). But when using -f ifup, the network comes up asynchronously.
    retry_mount
    mount_result=$?
fi
if [ $mount_result -ne 0 ] ; then
    echo "could not mount root filesystem -- exiting to /bin/sh"
    cd /
    PATH=$PATH PS1='$ ' /bin/sh -i
fi

unset discover_root retry_mount
