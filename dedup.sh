#!/bin/busybox ash
#
# Script to merge duplicate entries.

test -z "$BACKUP_BIN" && BACKUP_BIN="${0%/*}"
. "$BACKUP_BIN/common.sh"
acquire_lock

echo make table

echo "BEGIN TRANSACTION; CREATE TABLE dedup AS SELECT
       rowid AS h_rowid,
       inode, dirname, filename,
       created               AS one_created,
       deleted               AS one_deleted,
       min(created) OVER win AS min_created,
       max(deleted) OVER win AS max_deleted,
       count(*) OVER win     AS c,
       EXISTS ( SELECT *
              FROM   history AS h
              WHERE  dirname = h.dirname
              AND    filename=h.filename
              AND    inode != h.inode) AS bad
FROM   history
WHERE  type='f'
WINDOW win AS (PARTITION BY inode, dirname, filename);
-- We don't want to save db just yet,
-- because next command deletes many rows.
-- That's why this is a part of transaction
DELETE FROM dedup WHERE c<2 OR bad>0 OR (one_created = min_created AND one_deleted = max_deleted);
END TRANSACTION;" | $SQLITE

echo hardlink: one_created~one_deleted '=>' min_created~min_deleted

sql="SELECT dirname || filename || '/' || one_created || '$BACKUP_TIME_SEP' || one_deleted,
	    dirname || filename || '/' || min_created || '$BACKUP_TIME_SEP' || max_deleted
	FROM dedup
	GROUP BY dirname, filename, min_created, max_deleted;"
echo "$sql" | $SQLITE | while IFS="$NL" read -r f; do
		old_f="${f%%|*}"
		new_f="${f##*|}"
		ln "$BACKUP_MAIN/$old_f" "$BACKUP_MAIN/$new_f"
		# echo "$BACKUP_MAIN/$old_f" '=>' "$BACKUP_MAIN/$new_f"
	done

echo delete all files

sql="SELECT dirname || filename || '/' || one_created || '$BACKUP_TIME_SEP' || one_deleted FROM dedup;"
cd "$BACKUP_MAIN"
echo "$sql" | $SQLITE | /usr/bin/xargs -d '\n' rm -f

echo delete all rows

echo "DELETE FROM history WHERE rowid IN (SELECT h_rowid FROM dedup);" | $SQLITE

echo add new rows

echo "INSERT INTO history (inode, type, dirname, filename, created, deleted)
	SELECT inode, 'f', dirname, filename, min_created, max_deleted
	FROM dedup
	GROUP BY dirname, filename, min_created, max_deleted;" | $SQLITE

echo clean up

echo "DROP TABLE dedup; VACUUM;" | $SQLITE
