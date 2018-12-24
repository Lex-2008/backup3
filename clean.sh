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
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

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
	free_space_available=$(df -B1 --output=avail "$BACKUP_MAIN" | sed '1d')
	test $free_space_available -lt $FREE_SPACE_NEEDED
}

while check_space; do
	$SQLITE "SELECT rowid,
			dirname,
			filename,
			created,
			MIN(deleted),
			freq,
			freq*(strftime('%s', 'now')-deleted) AS age
		FROM history
		WHERE freq != 0
		GROUP BY freq
		ORDER BY age DESC
		LIMIT 1;" | while IFS='|' read rowid dirname filename created deleted freq age; do
		test "$dirname" = "" && dirname="."
		fullname="$dirname/$filename"
		newname="$fullname#$created"
		rm -f "$BACKUP_MAIN"/"$newname"
		$SQLITE "DELETE FROM history WHERE rowid=$rowid;"
	done
done
