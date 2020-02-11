#!/bin/false
# This file should be sourced by backup.sh
#
# Script to clean up space.

case "$BACKUP_CLEAN_VAR" in
	( "%" )
		total_space=$(df -PB1 "$BACKUP_MAIN" | awk 'FNR==2{print $2}')
		FREE_SPACE_NEEDED=$(dc $total_space 100 / $BACKUP_CLEAN_VAL \* 0 or p)
		;;
	( "G" )
		FREE_SPACE_NEEDED=${BACKUP_CLEAN_VAL}024024024
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

check_space || return 0 # no cleanup needed

if test "$BACKUP_CLEAN_BY_FREQ" = "1"; then
	# Uses 'timeline' index to get rows with freq!=0, then builds a temporary index for age.
	# We can't have this index permanently, since it depends on _current_ time
	# '+1' is here for files deleted "right now" - otherwise, for them
	# (strftime('now') - strftime(deleted)) equals 0 and they are immune to cleaning
	sql="SELECT dirname || filename || '/' || created,
			freq*(strftime('%s', 'now', 'localtime')+1-strftime('%s', deleted)) AS age,
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
		check_space || break
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
) > "$BACKUP_TMP".sql

<"$BACKUP_TMP".sql $SQLITE

rm "$BACKUP_TMP".sql
