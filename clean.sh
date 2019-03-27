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

# uses 'timeline' index to get rows with freq!=0, then builds a new index for
# age
$SQLITE "SELECT rowid,
		dirname,
		filename,
		created,
		deleted,
		freq*(strftime('%s', 'now')-strftime('%s', deleted)) AS age
	FROM history
	WHERE freq != 0
	ORDER BY age DESC;" | sed '
	1i echo ".timeout 10000"
	1i echo "BEGIN TRANSACTION;"
	s_\(.*\)|\(.*\)|\(.*\)|\(.*\)|\(.*\)|\(.*\)_'"
		rm -f '$BACKUP_MAIN/\\2/\\3/\\4$BACKUP_TIME_SEP\\5'
		echo 'DELETE FROM history WHERE rowid=\\1;'
		test \"\$(df -PB1 '$BACKUP_MAIN' | awk 'FNR==2{print \$4}')\" -lt $FREE_SPACE_NEEDED || exit 0
	_;"'
	$a echo "END TRANSACTION;"
	' | sh | $SQLITE

