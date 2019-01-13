#!/bin/busybox ash
test -z "$BACKUP_ROOT"    && exit 2
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
SQLITE="sqlite3 $BACKUP_DB"
# exit if there is backup in progress
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200


$SQLITE "CREATE INDEX IF NOT EXISTS check_tmp ON history(dirname, filename, created);"

/usr/bin/find "$BACKUP_MAIN" \( -type f -o -type l \) -printf "%i %P\n" | sort -k2 | sed "s/'/''/g;"'s_^\([0-9]*\) *\(\(.*\)/\)\?\([^/]*\)/\([^/]*\)$_\1|\3|\4|\5_' | while IFS='|' read new_inode new_dirname new_filename new_created; do
	# check that they have similar inodes
	if test "$old_inode $old_dirname $old_filename" = "$new_inode $new_dirname $new_filename"; then
		# SQL query to check that dates match: old.deleted = new.created
		echo "SELECT dirname, filename, created, deleted
			FROM history
			WHERE dirname='$old_dirname'
			AND filename='$old_filename'
			AND created='$old_created'
			AND deleted='$new_created';"
	fi
	old_inode="$new_inode"
	old_dirname="$new_dirname"
	old_filename="$new_filename"
	old_created="$new_created"
done | $SQLITE | sed "s/'/''/g;" | (
	echo "BEGIN TRANSACTION;"
	while IFS='|' read dirname filename old_created new_created; do
		# Remove old file
		# echo rm -f "$dirname/$filename/$new_created" >&2
		rm -f "$dirname/$filename/$new_created"
		# SQL query to update database
		echo "UPDATE history
				SET deleted=(SELECT deleted
					FROM history
					WHERE dirname='$dirname'
					AND filename='$filename'
					AND created='$new_created'
					LIMIT 1)
				WHERE dirname='$dirname'
				AND filename='$filename'
				AND created='$old_created';
			DELETE FROM history
				WHERE dirname='$dirname'
				AND filename='$filename'
				AND created='$new_created';
			UPDATE history
				SET freq = CASE
					WHEN deleted > '3000' THEN 0
					WHEN substr(created, 1, 7) != substr(deleted, 1, 7) THEN 1
					WHEN strftime('%Y %W', created) != strftime('%Y %W', deleted) THEN 5
					WHEN substr(created, 1, 10) != substr(deleted, 1, 10) THEN 30
					WHEN substr(created, 1, 13) != substr(deleted, 1, 13) THEN 720
					ELSE 8640
				END
				WHERE dirname='$dirname'
				AND filename='$filename'
				AND created='$old_created';"
	done
	echo "END TRANSACTION;"
) | $SQLITE

$SQLITE "DROP INDEX IF EXISTS check_tmp;VACUUM;"
