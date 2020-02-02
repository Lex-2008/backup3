#!/bin/busybox ash
#
# Script to init DB.

. "$(dirname "$0")/common.sh"
acquire_lock

mkdir -p $BACKUP_CURRENT $BACKUP_MAIN $BACKUP_RSYNC_LOGS

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
	freq INTEGER);
" | $SQLITE

test "$1" = "--noindex" || echo "
CREATE UNIQUE INDEX history_update ON history(dirname, filename) WHERE freq = 0;
CREATE INDEX timeline ON history(freq, deleted) WHERE freq != 0;
" | $SQLITE

# release the lock
rm "$BACKUP_FLOCK"
