#!/bin/bash
#
#%stage: block
#%depends: partition
#%param_S: "Don't include all IDE and SCSI drivers."
#
handle_scsi() {
    local dev=$1
    local devpath tgtnum hostnum procname

    devpath=$(cd -P /sys/block/$dev/device; echo $PWD)
    tgtnum=${devpath##*/}
    hostnum=${tgtnum%%:*}
    if [ ${tgtnum%%-*} = "vbd" ] ; then
	echo "xenblk"
	exit 0
    fi
    if [ ! -d /sys/class/scsi_host/host$hostnum ] ; then
	echo "scsi host$hostnum not found"
	exit 1;
    fi
    procname=$(cat /sys/class/scsi_host/host$hostnum/proc_name)
    # some drivers do not include proc_name so we need a fallback
    if [ "$procname" = "<NULL>" ] ; then
        procname="$(readlink /sys/class/scsi_host/host${hostnum}/device/../driver)"
        procname="${procname##*/}"
    fi
    echo $procname
}

get_devmodule() {
	# Translate subdirectories
	local blkdev=$(echo $1 | sed 's./.!.g')

	if [ ! -d /sys/block/$blkdev ] ; then
	    error 1 "Device $blkdev not found in sysfs"
	fi

	case "$blkdev" in
	    sd*)
		handle_scsi $blkdev
		echo sd_mod
		;;
	    hd*)
		devpath=$(cd -P "/sys/block/$blkdev/device"; echo $PWD)
		devname=${devpath##*/}
		if [ ${devname%%-*} = "vbd" ] ; then
		    echo "xenblk"
		else
		    devpath=$(cd -P "$devpath/../.."; echo $PWD)
		    if [ -f "$devpath/modalias" ] ; then
			cat $devpath/modalias
		    fi
		    echo ide-disk
		fi
		;;
	    cciss*)
		echo cciss
		;;
	    i2o*)
		echo i2o_block i2o_config
		;;
	    xvd*)
		echo xenblk
		;;
	    rd*)
		echo DAC960
		;;
	    ida*)
		echo cpqarray
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
		cat $devpath/modalias
		;;
	esac
	return 0
}

update_blockmodules() {
    local newmodule="$1"
    
    echo -n "$block_modules"
    
    for bm in $block_modules; do
	if [ "$newmodule" = "$bm" ]; then
	    return
	fi
    done
    
    echo -n "$newmodule "
}

if [ "$create_monster_initrd" -o ! "$param_S" ]; then
    for i in $(find $root_dir/lib/modules/$kernel_version/kernel/drivers/{ata,ide,scsi,s390/block,s390/scsi} -name "*.ko"); do
	i=${i%*.ko}
	block_modules="$block_modules ${i##*/}"
    done
else
	for bd in $blockdev; do
	    case $bd in # only include devices
	      /dev*) 
		update_blockdev $bd
		curmodule="$(get_devmodule ${bd##/dev/})"
		[ $? -eq 0 ] || return 1
		for curmodule_i in $curmodule; do
		    verbose "[BLOCK] $bd -> $curmodule_i"
		done
		if [ -z "$curmodule" ]; then
		    echo "[BLOCK] WARNING: could not find block module for $bd"
		fi
		for blockmodule in $curmodule; do
		    block_modules=$(update_blockmodules "$blockmodule")
		done
		;;
	      *) 
		verbose "[BLOCK] ignoring $bd"
	    esac
	done
fi

save_var block_modules
