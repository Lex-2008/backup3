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

. "$(dirname "$0")/common.sh"

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

# check if there is another copy of this script running
lock_available()
{
	test ! -f "$BACKUP_FLOCK" && return 0
	pid="$(cat "$BACKUP_FLOCK")"
	test ! -d "/proc/$pid" && { rm "$BACKUP_FLOCK"; return 0; }
	test ! -f "/proc/$pid/fd/200" && { echo "process $pid does not have FD 200"; rm "$BACKUP_FLOCK"; return 0; }
	test ! "$(stat -c %N /proc/$pid/fd/200)" == "/proc/$pid/fd/200 -> $BACKUP_FLOCK" && { echo "process $pid has FD 200 not pointing to $BACKUP_FLOCK"; rm "$BACKUP_FLOCK"; return 0; }
	return 1
}
while ! lock_available; do sleep 1; done
# acquire lock
exec 200>"$BACKUP_FLOCK"
echo "$$">&200

if test "$CLEAN_BY_FREQ" = "1"; then
	# Uses 'timeline' index to get rows with freq!=0, then builds a temporary index for age.
	# We can't have this index permanently, since it depends on _current_ time
	sql="SELECT dirname || filename || '/' || created,
			freq*(strftime('%s', 'now')-strftime('%s', deleted)) AS age,
			rowid
		FROM history
		WHERE freq != 0
		ORDER BY age DESC;"
else
	# Uses 'timeline' index both for WHERE and for ORDER BY
	sql="SELECT dirname || filename || '/' || created,
			rowid
		FROM history
		WHERE freq != 0
		ORDER BY deleted ASC;"
fi

echo "$sql" | $SQLITE | (
	echo '.timeout 10000'
	echo 'BEGIN TRANSACTION;'
	while IFS="$NL" read f; do
		test "$(df -PB1 "$BACKUP_MAIN" | awk 'FNR==2{print $4}')" -lt $FREE_SPACE_NEEDED || break
		filename="${f%%|*}"
		rowid="${f##*|}"
		# Note: below command will fail for directories for two reasons:
		# 1. because '$filename' has a creation date in it, and this is
		# never a case for directories
		# 2. because 'rm' command doesn't have '-r' argument, so it
		# won't delete any directories, even if they matched.
		rm -f "$BACKUP_MAIN/$filename"* 2>/dev/null
		echo "DELETE FROM history WHERE rowid='$rowid';"
	done
	echo 'END TRANSACTION;'
	echo 'PRAGMA optimize;'
) | $SQLITE
