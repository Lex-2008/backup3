#!/bin/busybox ash
#
# Script to clean up space.
#
# Call it like this:
# $ clean.sh 10 G
# to ensure that you have at least 10GB of disk space free.
# Or like this:
# $ clean.sh 10 %
# to ensure that you have at least 10% of disk space free.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"

SQLITE="sqlite3 $BACKUP_DB"

NL="
"

case "$2" in
	( "%" )
		total_space=$(df -PB1 "$BACKUP_MAIN" | awk 'FNR==2{print $2}')
		FREE_SPACE_NEEDED=$(dc $total_space 100 / $1 \* 0 or p)
		;;
	( "G" )
		FREE_SPACE_NEEDED=${1}024024024
		;;
	( * )
		exit 2
esac

# return status of 0 (true) means "need to clear space"
check_space()
{
	free_space_available=$(df -PB1 "$BACKUP_MAIN" | awk 'FNR==2{print $4}')
	test "$free_space_available" -lt "$FREE_SPACE_NEEDED"
}

check_space || exit 0 # no cleanup needed

# Uses 'timeline' index to get rows with freq!=0, then builds a temporary index for age.
# We can't have this index permanently, since it depends on _current_ time
sql="SELECT dirname || '/' || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted,
		freq*(strftime('%s', 'now')-strftime('%s', deleted)) AS age,
		rowid
	FROM history
	WHERE freq != 0
	ORDER BY age DESC;"

cmd="	echo '.timeout 10000'
	echo 'BEGIN TRANSACTION;'
	while test \$# -ge 1; do
		test \"\$(df -PB1 '$BACKUP_MAIN' | awk 'FNR==2{print \$4}')\" -lt $FREE_SPACE_NEEDED || break
		filename=\"\${1%%|*}\"
		rowid=\"\${1##*|}\"
		rm -f \"$BACKUP_MAIN/\$filename\"
		echo \"DELETE FROM history WHERE rowid='\$rowid';\"
		shift
	done
	echo 'END TRANSACTION;'
	echo 'PRAGMA optimize;'"

$SQLITE "$sql" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE
