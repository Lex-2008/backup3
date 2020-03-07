#!/bin/busybox ash
#
# Script to check par2 archives or duplicates of monthly backups
#
# Call it once a month like this:
# 
# $ par2verify.sh [OPTIONS]
# (without arguments) to check all files in all monthly backups
#
# $ par2verify.sh [OPTIONS] 1
# to check all files in last 1 monthly backups
#
# $ par2verify.sh [OPTIONS] 3 2
# to check all files in backups which are older than 2 but newer than 3 months old
#
# Options are:
#   -q to be less verbose regarding missing files
#   -qq to be less verbose regarding OK files (report only issues)
#   -r to process files in random order

. "$(dirname "$0")/common.sh"

if test "$1" = "-q"; then
	quiet_missing=1
	shift
fi

if test "$1" = "-qq"; then
	quiet_ok=1
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

sql=" SELECT dirname || filename || '/' || created,
	'$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE type='f'
	  AND freq<2 $cond1 $cond2
	ORDER BY $sort_by;"

finish_time="$(`which date` -d "$BACKUP_PAR2_TIMEOUT" +%s)"
export LC_ALL=POSIX
echo "$sql" | $SQLITE | while IFS="$NL" read -r f; do
		if test "$(date +%s)" -gt "$finish_time"; then
			# timeout reached, abort
			echo
			echo "TIMEOUT"
			break
		fi
		filepart="$BACKUP_MAIN/${f%%|*}"
		fileend="${f##*|}"
		filename="$filepart$fileend"
		if test "$filename" -ef "$filepart.bak"; then
			# *.bak file is hardlinked to original => remove
			echo -n x
			rm -f "$filepart.bak"
		fi
		if test -f "$filepart.bak"; then
			# *.bak file found, check it
			if diff -q "$filepart.bak" "$filename"; then
				test -z "$quiet_ok" && echo -n c
			else
				echo
				echo FILES DIFFER: "$filepart.bak" "$filename"
			fi
			continue
		elif ! test -f "$filepart.par2"; then
			# neither *.bak, nor *.par2 file found
			if test -z "$quiet_missing"; then
				echo
				echo NOT PROTECTED: "$filename"
			else
				echo -n _
			fi
			continue
		fi
		# check *.par2 file
		par2verify -q "$filepart.par2" >"$BACKUP_PAR2_LOG" 2>&1 &
		par_pid=$!
		if test "$BACKUP_PAR2_CPULIMIT" != "0"; then
			cpulimit -b -p $par_pid -l $BACKUP_PAR2_CPULIMIT >/dev/null 2>&1
		fi
		if wait $par_pid; then
			test -z "$quiet_ok" && echo -n p
			continue
		fi
		# check if file was renamed
		target_filename="$(sed -r '/^Target:/!d;s/^Target: "(.*)" - missing.$/\1/' "$BACKUP_PAR2_LOG")"
		if test -z "$target_filename"; then
			echo
			echo PAR2 FAILED: "$filepart.par2" - no target_filename
			cat "$BACKUP_PAR2_LOG"
			continue
		fi
		# rename file and repeat par2verify run
		dirname="${filename%/*}"
		target_filename="$dirname/$target_filename"
		mv "$filename" "$target_filename"
		par2verify -qq "$filepart.par2" &
		par_pid=$!
		if test "$BACKUP_PAR2_CPULIMIT" != "0"; then
			cpulimit -b -p $par_pid -l $BACKUP_PAR2_CPULIMIT >/dev/null 2>&1
		fi
		if wait $par_pid; then
			test -z "$quiet_ok" && echo -n R
			# note that we can't continue here, because
			# we should rename file back to original
		else
			echo
			echo PAR2 FAILED: "$filepart.par2"
			# rm -f "$filepart.par2" "$filepart.vol"*
		fi
		# rename file back to original
		mv "$target_filename" "$filename"
	done

