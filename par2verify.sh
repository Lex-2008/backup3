#!/bin/busybox ash
#
# Script to check par2 archives or duplicates of monthly backups
#
# Call it once a month like this:
# 
# $ par2verify.sh
# (without arguments) to check all files in all monthly backups
#
# $ par2verify.sh 1
# to check all files in last 1 monthly backups
#
# $ par2verify.sh 3 2
# to check all files in backups which are older than 2 but newer than 3 months old

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_PAR2_CPULIMIT" && BACKUP_PAR2_CPULIMIT=0 # limit CPU usage by par2 process

SQLITE="sqlite3 $BACKUP_DB"

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
	WHERE freq<2 $cond1 $cond2
	ORDER BY dirname;"

if test "$BACKUP_PAR2_CPULIMIT" = "0"; then
	cpulimit_cmd=""
else
	cpulimit_cmd="cpulimit -q -b -p \$par_pid -l $BACKUP_PAR2_CPULIMIT"
fi

cmd="	while test \$# -ge 1; do
		filepart=\"$BACKUP_MAIN/\${1%%|*}\"
		fileend=\"\${1##*|}\"
		filename=\"\$filepart\$fileend\"
		if test -f \"\$filepart.bak\"; then
			if diff -q \"\$filepart.bak\" \"\$filename\"; then
				echo -n c
			else
				echo
				echo FILES DIFFER: \"\$filepart.bak\" \"\$filename\"
			fi
		elif test -f \"\$filepart.par2\"; then
			par2verify -qq \"\$filepart.par2\" &
			par_pid=\$!
			$cpulimit_cmd
			if wait \$par_pid; then
				echo -n p
			else
				echo
				echo PAR2 FAILED: \"\$filepart.par2\" \"\$filename\"
				# rm -f \"\$filepart.par2\" \"\$filepart.vol\"*
			fi
		else
			echo
			echo NOT PROTECTED: \"\$filename\"
		fi
		shift
	done
	"

export LC_ALL=POSIX
$SQLITE "$sql" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x
