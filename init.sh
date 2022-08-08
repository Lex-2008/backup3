#!/bin/busybox ash
#
# Script to init DB.

. "${0%/*}/common.sh"

mkdir -p "$BACKUP_CURRENT" "$BACKUP_MAIN" "$BACKUP_TMP" "$BACKUP_RSYNC_LOGS" "$BACKUP_RSYNC_STATS" "$PARTIAL_DIR"

test "$1" = "--notable" || echo "
DROP TABLE IF EXISTS history;
PRAGMA journal_mode=WAL;
CREATE TABLE history(
	inode INTEGER,
	type TEXT,
	dirname TEXT,
	filename TEXT,
	created TEXT,
	deleted TEXT,
	freq INTEGER AS (
		CASE
			WHEN deleted = '$BACKUP_TIME_NOW'
			     THEN 0 -- not deleted yet
			WHEN strftime('%Y-%m', created, '-1 second') !=
			     strftime('%Y-%m', deleted, '-1 second')
			     THEN 1 -- different month
			WHEN strftime('%Y %W', created, '-1 second') !=
			     strftime('%Y %W', deleted, '-1 second')
			     THEN 5 -- different week
			WHEN strftime('%Y-%m-%d', created, '-1 second') !=
			     strftime('%Y-%m-%d', deleted, '-1 second')
			     THEN 30 -- different day
			WHEN strftime('%Y-%m-%d %H', created, '-1 second') !=
			     strftime('%Y-%m-%d %H', deleted, '-1 second')
			     THEN 720 -- different hour
			WHEN strftime('%s', created, '-1 second')/$BACKUP_MAX_FREQ_SEC !=
			     strftime('%s', deleted, '-1 second')/$BACKUP_MAX_FREQ_SEC
			     THEN $BACKUP_MAX_FREQ -- crosses BACKUP_MAX_FREQ boundary (usually 5 minutes)
			ELSE 2592000 / (strftime('%s', deleted) - strftime('%s', created))
			     -- 2592000 is number of seconds per month
		END
	) STORED
);
DROP TABLE IF EXISTS bad_new_files;
CREATE TABLE bad_new_files(
  inode INT,
  type TEXT,
  dirname TEXT,
  filename TEXT,
  created TEXT,
  deleted TEXT
);
" | $SQLITE

test "$1" = "--noindex" || echo "
CREATE UNIQUE INDEX history_update ON history(dirname, filename) WHERE freq = 0;
CREATE INDEX timeline ON history(freq, deleted) WHERE freq != 0;
" | $SQLITE
