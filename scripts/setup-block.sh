#!/bin/bash
#
#%stage: block
#%depends: partition
#%param_S: "Don't include all libata drivers."
#

# Brief
#       Resolves the kernel modules needed for a SCSI device
#
# Parameters:
#       device [in]:  the device
#       result [out]: the string where the devices are stored
#
# Return value:
#       The function always returns 0.
#
# Example:
#       local result
#       handle_scsi /dev/sda result
#       echo $result # gives something like 'sata_piix', for example
#
# Side effects:
#       May set block_uses_libata, so don't call that in a subshell if you
#       want to use that global variable as result.
#
handle_scsi()
{
    local dev=$1
    local devpath tgtnum hostnum procname
    local modules

    devpath=$(cd -P /sys/block/$dev/device; echo $PWD)
    tgtnum=${devpath##*/}
    hostnum=${tgtnum%%:*}
    if [ ${tgtnum%%-*} = "vbd" ] ; then
        modules="xenblk"
    else
        if [ ! -d /sys/class/scsi_host/host$hostnum ] ; then
            echo "scsi host$hostnum not found"
            exit 1
        fi
        procname=$(cat /sys/class/scsi_host/host$hostnum/proc_name)
        # some drivers do not include proc_name so we need a fallback
        if [ "$procname" = "<NULL>" ] ; then
            procname="$(readlink /sys/class/scsi_host/host${hostnum}/device/../driver)"
            procname="${procname##*/}"
        fi

        # let's see if that driver is on libata
        if [ -L "/sys/module/libata/holders/$procname" ]; then
            block_uses_libata=1
        fi

        modules=$procname
    fi

    eval "$2=\$modules"
    return 0
}

# Brief
#       Resolves the kernel modules needed for a device
#
# Parameters:
#       device [in]:  the device
#       result [out]: the string where the devices are stored
#
# Return value:
#       The function always returns 0.
#
# Side effects:
#       May set block_uses_libata, so don't call that in a subshell if you
#       want to use that global variable as result.
#
get_devmodule()
{
    local result=

    # Translate subdirectories
    local blkdev=$(echo $1 | sed 's./.!.g')

    if [ ! -d /sys/block/$blkdev ] ; then
        error 1 "Device $blkdev not found in sysfs"
    fi

    case "$blkdev" in
        sd*)
            handle_scsi $blkdev result
            result="$result sd_mod"
            ;;
        hd*)
            devpath=$(cd -P "/sys/block/$blkdev/device"; echo $PWD)
            devname=${devpath##*/}
            if [ ${devname%%-*} = "vbd" ] ; then
                result=xenblk
            else
                devpath=$(cd -P "$devpath/../.."; echo $PWD)
                if [ -f "$devpath/modalias" ] ; then
                    result=$(< $devpath/modalias)
                fi
                result="$result ide-disk"
            fi
            ;;
        cciss*)
            result=cciss
            ;;
        i2o*)
            result="i2o_block i2o_config"
            ;;
        xvd*)
            result=xenblk
            ;;
        rd*)
            result=DAC960
            ;;
        ida*)
            result=cpqarray
            ;;
        *)
            if [ ! -d /sys/block/$blkdev/device ] ; then
                echo "Device $blkdev not handled" >&2
                return 1
            fi
            devpath=$(cd -P "/sys/block/$blkdev/device"; echo $PWD)
            if [ ! -f "$devpath/modalias" ] ; then
                echo "No modalias for device $blkdev" >&2
                return 1
            fi
            result=$(< $devpath/modalias)
            ;;
    esac

    eval "$2=\$result"
    return 0
}

update_blockmodules()
{
    local newmodule="$1"

    echo -n "$block_modules"

    for bm in $block_modules; do
        if [ "$newmodule" = "$bm" ]; then
            return
        fi
    done

    echo -n "$newmodule "
}

if [ "$create_monster_initrd" ]; then
    for d in $root_dir/lib/modules/$kernel_version/kernel/drivers/{ata,ide,scsi,s390/block,s390/scsi}; do
        if [ -d "$d" ]; then
            for i in $(find "$d" -name "*.ko"); do
                i=${i%*.ko}
                block_modules="$block_modules ${i##*/}"
            done
        fi
    done
else
    all_libata_modules_included=0

    # copy over all drivers needed to boot up the system
    for bd in $blockdev; do
        case $bd in # only include devices
          /dev*)
            update_blockdev $bd
            get_devmodule ${bd##/dev/} curmodule
            [ $? -eq 0 ] || return 1
            for curmodule_i in $curmodule; do
                verbose "[BLOCK] $bd -> $curmodule_i"
            done
            if [ -z "$curmodule" ]; then
                echo "[BLOCK] WARNING: could not find block module for $bd"
            fi

            # if we need libata, just copy all libata drivers
            if [ "$block_uses_libata" -a ! "$param_S" ]; then

                # but do that only once
                if [ "$all_libata_modules_included" -eq 0 ] ; then
                    for i in $(find $root_dir/lib/modules/$kernel_version/kernel/drivers/ata -name "*.ko"); do
                        i=${i%*.ko}
                        block_modules="$block_modules ${i##*/}"
                    done
                    block_modules="$block_modules sd_mod"
                    all_libata_modules_included=1
                fi
            else
                for blockmodule in $curmodule; do
                    block_modules=$(update_blockmodules "$blockmodule")
                done
            fi

            ;;
          *)
            verbose "[BLOCK] ignoring $bd"
        esac
    done

fi

save_var block_modules
