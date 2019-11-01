#!/bin/busybox ash
#
# Script to create par2 archives or duplicates of monthly backups to protect
# them from bit rot.
#
# Call it once a month like this:
# 
# $ par2create.sh
# (without arguments) to create par2 archives (or duplicates) of all files in
# all monthly backups
#
# $ par2create.sh 1
# to create par2 archives (or duplicates) of all files in last 1 monthly backups
#
# $ par2create.sh 3 2
# to create par2 archives (or duplicates) of all files in backups which are
# older than 2 but newer than 3 months old

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_PAR2_SIZELIMIT" && BACKUP_PAR2_SIZELIMIT=300000 # minimum file size to create *.par2 archive, smaller files are copied to *.bak ones as-is
test -z "$BACKUP_PAR2_CPULIMIT" && BACKUP_PAR2_CPULIMIT=0 # limit CPU usage by par2 process

SQLITE="sqlite3 $BACKUP_DB"

cond2="AND created<strftime('%Y-%m', 'now')"
if test ! -z "$1"; then
	cond1="AND created>=strftime('%Y-%m', 'now', '-$1 months')"
fi
if test ! -z "$2"; then
	cond2="AND created<strftime('%Y-%m', 'now', '-$2 months')"
fi

sql=" SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
	FROM history
	WHERE freq<2 $cond1 $cond2
	ORDER BY dirname;"

if test "$BACKUP_PAR2_CPULIMIT" = "0"; then
	cpulimit_cmd="wait \$par_pid"
else
	cpulimit_cmd="cpulimit -q -p \$par_pid -l $BACKUP_PAR2_CPULIMIT"
fi

cmd="getfn() {
	# helper function to get file name when it was renamed
	filename=\"\$1\"
	fileend=\"\${filename##*$BACKUP_TIME_SEP}\"
	if test \"\$fileend\" != \"$BACKUP_TIME_SEP$BACKUP_TIME_NOW\"; then
		# ERROR: file doesn't end with ~now
		# it's an error because this function was called when requested
		# file didn't exist. And the only way it could happen under
		# normal circumstances is when file was renamed from ~now to ~date
		# while this script is running
		return
	fi
	filepart=\"\${filename%$BACKUP_TIME_SEP*}\"
	filename=\"\$(ls -1 \"\$filepart\"* )\"
	if test -f \"\$filename\"; then
		# single existing file matches filepart*
		# hence it's a file we were looking for
		echo \"\$filename\"
		return
	fi
	count=\"\$(echo \"\$filename\" | wc -l)\"
	if test \$count -gt 1; then
		# ERROR: more than one file matches
		# it's an error since backup was checked before
		return
	fi
	# getting filename by expanding * didn't work,
	# trying 'ls | grep' method
	partbase=\"\$(basename \"\$filepart\")$BACKUP_TIME_SEP\"
	dirname=\"\$(dirname \"\$filepart\")\" 
	basename=\"\$(ls -1 \"\$dirname\" | fgrep \"\$partbase\")\"
	if test -z \"\$basename\"; then
		# ERROR: nothing was found
		return
	fi
	filename=\"\$dirname/\$basename\"
	if test -f \"\$filename\"; then
		# single existing file was found
		# hence it's a file we were looking for
		echo \"\$filename\"
		return
	fi
	# otherwise, ERROR
}

	while test \$# -ge 1; do
		filename=\"$BACKUP_MAIN/\$1\"
		filepart=\"\${filename%$BACKUP_TIME_SEP*}\"
		if test -f \"\$filepart.par2\" -o -f \"\$filepart.bak\"; then
			# backup already exists, moving on
			echo -n .
			shift
			continue
		fi
		if test ! -f \"\$filename\"; then
			# Maybe file was renamed while this script was running.
			# Trying to get new filename
			filename=\"\$(getfn \"\$filename\")\"
			if test -z \"\$filename\"; then
				echo
				echo \"ERROR: [\$filepart]\"
				shift
				continue
			fi
		fi
		filesize=\"\$(stat -c%s \"\$filename\")\"
		if test \"\$filesize\" -lt $BACKUP_PAR2_SIZELIMIT; then
			# small file - just copy it
			echo -n C
			cp \"\$filename\" \"\$filepart.bak\"
		else
			# big file - par2create
			echo -n P
			par2create -qq -n1 \"\$filepart.par2\" \"\$filename\" >/dev/null &
			par_pid=\$!
			$cpulimit_cmd

		fi
		shift
	done
	"

export LC_ALL=POSIX
$SQLITE "$sql" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x
