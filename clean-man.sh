#!/bin/busybox ash
#
# Script to clean up space manually.
#
# The only argument is a part of SQL statement starting with "WHERE",
# the whole SQL statement being 'SELECT ... FROM history WHERE ...',
# or 'DELETE FROM history WHERE ...'. Note that argument itself must
# begin with word "WHERE"

test -z "$BACKUP_BIN" && BACKUP_BIN="${0%/*}"
. "$BACKUP_BIN/common.sh"
acquire_lock

test -z "$1" && exit 1
expr "$1" : "WHERE " >/dev/null || exit 2

sql="SELECT dirname || filename || '/' || created,
		rowid
	FROM history
	$1;"

echo "$sql" | $SQLITE | (
	echo '.timeout 10000'
	echo 'BEGIN TRANSACTION;'
	while IFS="$NL" read -r f; do
		filename="${f%%|*}"
		rowid="${f##*|}"
		# Note: below command will fail for directories for two reasons:
		# 1. because '$filename' has a creation date in it, and this is
		# never a case for directories
		# 2. because 'rm' command doesn't have '-r' argument, so it
		# won't delete any directories, even if they matched.
		# echo rm -f "$BACKUP_MAIN/$filename"* >&2
		rm -f "$BACKUP_MAIN/$filename"* 2>/dev/null
		echo "DELETE FROM history WHERE rowid='$rowid';"
	done
	echo 'END TRANSACTION;'
	echo 'PRAGMA optimize;'
) > "$BACKUP_TMP".sql

<"$BACKUP_TMP".sql $SQLITE

rm "$BACKUP_TMP".sql
