#!/bin/busybox ash
#
# Script to create par2 archives or duplicates of monthly backups to protect
# them from bit rot.
#
# Call it once a month like this:
# 
# $ par2create.sh [OPTIONS]
# (without arguments) to create par2 archives (or duplicates) of all files in
# all monthly backups
#
# $ par2create.sh [OPTIONS] 1
# to create par2 archives (or duplicates) of all files in last 1 monthly backups
#
# $ par2create.sh [OPTIONS] 3 2
# to create par2 archives (or duplicates) of all files in backups which are
# older than 2 but newer than 3 months old
#
# Options are:
#   -q to be less verbose regarding existing files (do not print dots)
#   -qq to be less verbose regarding created files (report only issues)
#   -r to process files in random order

. "$(dirname "$0")/common.sh"

if test "$1" = "-q"; then
	quiet_existing=1
	shift
fi

if test "$1" = "-qq"; then
	quiet_existing=1
	quiet_new=1
	shift
fi

if test "$1" = "-r"; then
	sort_by="random()"
	shift
else
	sort_by="dirname"
fi

cond2="AND created<strftime('%Y-%m', 'now')"
if test ! -z "$1"; then
	cond1="AND created>=strftime('%Y-%m', 'now', '-$1 months')"
fi
if test ! -z "$2"; then
	cond2="AND created<strftime('%Y-%m', 'now', '-$2 months')"
fi

sql=" SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE type='f'
	  AND freq<2 $cond1 $cond2
	ORDER BY $sort_by;"

# helper function to get file name when it was renamed
getfn() {
	filename="$1"
	fileend="${filename##*$BACKUP_TIME_SEP}"
	if test "$fileend" != "$BACKUP_TIME_SEP$BACKUP_TIME_NOW"; then
		# ERROR: file doesn't end with ~now
		# it's an error because this function was called when requested
		# file didn't exist. And the only way it could happen under
		# normal circumstances is when file was renamed from ~now to ~date
		# while this script is running
		return
	fi
	filepart="${filename%$BACKUP_TIME_SEP*}"
	filename="$(ls -1 "$filepart"* )"
	if test -f "$filename"; then
		# single existing file matches filepart*
		# hence it's a file we were looking for
		echo "$filename"
		return
	fi
	count="$(echo "$filename" | wc -l)"
	if test $count -gt 1; then
		# ERROR: more than one file matches
		# it's an error since backup was checked before
		return
	fi
	# getting filename by expanding * didn't work,
	# trying 'ls | grep' method
	partbase="$(basename "$filepart")$BACKUP_TIME_SEP"
	dirname="$(dirname "$filepart")"
	basename="$(ls -1 "$dirname" | fgrep "$partbase")"
	if test -z "$basename"; then
		# ERROR: nothing was found
		return
	fi
	filename="$dirname/$basename"
	if test -f "$filename"; then
		# single existing file was found
		# hence it's a file we were looking for
		echo "$filename"
		return
	fi
	# otherwise, ERROR
}

finish_time="$(`which date` -d "$BACKUP_PAR2_TIMEOUT" +%s)"
export LC_ALL=POSIX
echo "$sql" | $SQLITE | while IFS="$NL" read -r f; do
		if test "$(date +%s)" -gt "$finish_time"; then
			# timeout reached, abort
			echo
			echo "TIMEOUT"
			break
		fi
		filename="$BACKUP_MAIN/$f"
		filepart="${filename%$BACKUP_TIME_SEP*}"
		if test "$filename" -ef "$filepart.bak"; then
			# *.bak file is hardlinked to original => remove
			echo -n x
			rm -f "$filepart.bak"
		fi
		if test -f "$filepart.par2" -o -f "$filepart.bak"; then
			# backup already exists, moving on
			test -z "$quiet_existing" && echo -n .
			continue
		fi
		if test ! -f "$filename"; then
			# Maybe file was renamed while this script was running.
			# Trying to get new filename
			filename="$(getfn "$filename")"
			if test -z "$filename"; then
				echo
				echo "ERROR: [$filepart]"
				continue
			fi
		fi
		filesize="$(stat -c%s "$filename")"
		if test "$filesize" -lt $BACKUP_PAR2_SIZELIMIT; then
			# small file - just copy it
			test -z "$quiet_new" && echo -n C
			cp "$filename" "$filepart.bak"
		else
			# big file - par2create
			test -z "$quiet_new" && echo -n P
			par2create -qq -n1 "$filepart.par2" "$filename" >/dev/null &
			par_pid=$!
			if test "$BACKUP_PAR2_CPULIMIT" = "0"; then
				wait $par_pid
			else
				cpulimit -p $par_pid -l $BACKUP_PAR2_CPULIMIT >/dev/null 2>&1
			fi
		fi
	done

