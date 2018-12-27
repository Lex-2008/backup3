#!/bin/sh
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
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

NL="
"

case "$2" in
	( "%" )
		total_space=$(df -B1 --output=size "$BACKUP_MAIN" | sed '1d')
		FREE_SPACE_NEEDED=$(echo "$total_space*$1/100" | bc /dev/stdin)
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
	free_space_available="$(df -B1 --output=avail "$BACKUP_MAIN")"
	free_space_available="${free_space_available#*$NL}"
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
		freq,
		freq*(strftime('%s', 'now')-strftime('%s', deleted)) AS age
	FROM history
	WHERE freq != 0
	ORDER BY age DESC;" | (
		echo ".timeout 10000"
		echo "BEGIN TRANSACTION;"
		IFS='|'
		while check_space; do
			read rowid dirname filename created deleted freq age
			test "$dirname" = "" && dirname="."
			rm -f "$BACKUP_MAIN/$dirname/$filename/$created"
			echo "DELETE FROM history WHERE rowid=$rowid;"
		done
		echo "END TRANSACTION;"
	) | $SQLITE
