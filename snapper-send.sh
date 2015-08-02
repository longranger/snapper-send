#!/bin/bash
[ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock -en "$0" "$0" "$@" || :

nPingMSlimit=3
sDescription="snapper-send-current"
sDescriptionOld="snapper-send-old"

# Snapper config must be set with the following:

#set -o nounset
#set -o errexit
#set -o pipefail

# bash shortcut for `basename $0`
sProg=${0##*/}

usage() {
    cat <<EOF
Usage: 

$sProg [-t|--target hostname] [-s|--snapshot ssNum] [-e|--email email@address.com] [--init] snapper_config /dest/path

Arguments:
	snapper_config Must match a snapper config in /root/snapper/configs
	/dest/path     Backup destination root

Options:
	-t|--target    Target hostname (if transferring via ssh)
	-s|--snapshot  Existing snapshot (number) to send. Without this
	               argument, a new snapshot is created to send.
	-e|--email     Email address to send any errors to
	   --init      Complete backup. This creates the first snapper-send
	               snapshot on source and sends it to target.

EOF
	exit 0
}

trim() {
	# Accept input from argument or STDIN
	# So you can do both:
	# $ echo '  #FOO#   ' | trim
	# or
	# $ trim '   #FOO#   '
	local STRING=$( [ -n "$1" ] && echo $* || cat ; )
  
	echo "$STRING" | sed -e 's/^\s*//' -e 's/\s*$//'
}

die () {
	sMsg=${1:-}
	# don't loop on ERR
	trap '' ERR

	sErr="$sProg failed from $HOSTNAME to $sTargetHost"
	echo -e "\n$sErr\n$sMsg\n" >&2
	echo $sMsg > /tmp/${sProg}.err.msg

	if [[ -n "$sEmailAddress" ]]; then
		/usr/bin/mail -s "$sErr" "$sEmailAddress" < /tmp/${sProg}.err.msg
	fi

	# This is a fancy shell core dumper
	if echo $sMsg | grep -q 'Error line .* with status'; then
		line=`echo $sMsg | sed 's/.*Error line \(.*\) with status.*/\1/'`
		echo " DIE: Code dump:" >&2
		nl -ba $0 | grep -3 "\b$line\b" >&2
	fi

	exit 1
}


# Trap errors for logging before we die (so that they can be picked up
# by the log checker)
trap 'die "Error line $LINENO with status $?"' ERR

##
# Initialize and gather input
##
bInit=""
sEmailAddress=""
TEMP=$(getopt --longoptions help,usage,init,target:,snapshot:,email: -o h,t:,s:,e: -- "$@") || usage
sTargetHost=localhost
nNewSnapshot=""
sSCPtarget=""
sSSH=""
bExistingSS=false

# getopt quotes arguments with ' We use eval to get rid of that
eval set -- $TEMP

while :
do
	case "$1" in
		-h|--help|--usage)
			usage
			shift
			;;

		--target|-t)
			shift
			sTargetHost=$1
			sSCPtarget="$sTargetHost:"
			sSSH="ssh $sTargetHost"
			shift
			;;

		--snapshot|-s)
			shift
			bExistingSS=true
			nNewSnapshot=$1
			shift
			;;

		--email|-e)
			shift
			sEmailAddress=$1
			shift
			;;

		--init)
			bInit=1
			shift
			;;

		--)
			shift
			break
			;;

		*) 
			echo "Internal error from getopt!"
			exit 1
			;;
	esac
done

[[ $# != 2 ]] && usage
sConfig=$1
grep SUBVOLUME /etc/snapper/configs/$sConfig > /dev/null || \
	die "snapper config \"$sConfig\" does not exist or is missing its subvolume path"
sPathCfg=$(sudo snapper -c $sConfig get-config | grep SUBVOLUME | cut -d '|' -f 2 | trim)
sPathDestRoot=$2/.snapshots


##
# Sanity checks
##

# Check number of existing snapshots with the matching description
nCntNumberSnapshots=$(snapper -c $sConfig ls | grep "$sDescription" | wc -l)
if [[ -n "$bInit" ]]; then
	test $nCntNumberSnapshots -eq 0 || \
		die "Can not init as $nCntNumberSnapshots number snapshots already exist on $HOSTNAME"
else
	# Must be exactly 1 existing number snapshot
	test $nCntNumberSnapshots -eq 1 || \
		die "Need exactly 1 number snapshots on $HOSTNAME, have $nCntNumberSnapshots"
	nOldSnapshot=$(snapper -c $sConfig ls | grep "$sDescription" | cut -d '|' -f 2 | trim)
	echo old snapper-send Snapshot = $nOldSnapshot
fi

# Check if target is close enough to sync to
# Not sure how to check throughut, but ping < a few average should be lan
ping -c1 $sTargetHost &>/dev/null || \
	die "Unable to reach destination $sTargetHost"
nPingMS=$(ping -qc9 -i 0.2 $sTargetHost | grep rtt | cut -d '/' -f 5 | cut -d '.' -f 1)
test $nPingMS -lt $nPingMSlimit || \
	die "Destination $sTargetHost does not seem to be on LAN"

# Ensure /dest/path exists (on target)
$sSSH test -d "$sPathDestRoot/" || \
	die "$sPathDestRoot not a directory (on $sTargetHost). Likely should be a subvolume. Create it first. (this is normal for init...)"


##
# Really doing this
##
if [[ -n "$nNewSnapshot" ]]; then
	# This snapshot number was passed in.
	# Check it exists, and is newer than the old snapshot
	if [ $nOldSnapshot -ge $nNewSnapshot ]; then
		die "New Snapshot ($nNewSnapshot) must be newer than Old Snapshot ($nOldSnapshot)"
	fi
	snapper -c $sConfig status $nOldSnapshot..$nNewSnapshot >/dev/null || dir "New Snapshot ($nNewSnapshot) does not exist"
else
	# Create local number snapshot via snapper, saving snapshot number
	nNewSnapshot=$(snapper -c $sConfig create -p -c number -d "$sDescription")
fi

echo New snapper-send Snapshot = $nNewSnapshot

# Create the actual snapshot directory
sPathDest=$sPathDestRoot/$nNewSnapshot
$sSSH mkdir $sPathDest

#TODO - confirm if this works correctly with non-root subvolumes (trailing slash)
sPathNew=$sPathCfg/.snapshots/$nNewSnapshot/snapshot
fNewInfo=$sPathCfg/.snapshots/$nNewSnapshot/info.xml

# Copy over the info.xml from the new snapshot
scp $fNewInfo $sSCPtarget"$sPathDest/"

if [[ -n "$bInit" ]]; then
	btrfs send $sPathNew | $sSSH btrfs receive "$sPathDest/" || \
		die "btrfs send failed from $sPathNew to $sSSH:$sPathDest"
else
	sPathOld=$sPathCfg/.snapshots/$nOldSnapshot/snapshot
	btrfs send -p $sPathOld $sPathNew | $sSSH btrfs receive "$sPathDest/" || \
		die "btrfs send failed from $sPathNew - $sPathOld to $sSSH:$sPathDest"

	# On successful send, rename the old snapshot
	snapper -c $sConfig modify -d "$sDescriptionOld" $nOldSnapshot

	#TODO - if copying an existing snapshot, change it's description.
	if [[ $bExistingSS ]]; then
		snapper -c $sConfig  modify -d "$sDescription" $nNewSnapshot
	fi
fi
