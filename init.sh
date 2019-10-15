#!/bin/sh
#
# Script to init DB.


test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs

SQLITE="sqlite3 $BACKUP_DB"

mkdir -p $BACKUP_CURRENT $BACKUP_MAIN $BACKUP_RSYNC_LOGS

$SQLITE "CREATE TABLE history(
	inode INTEGER,
	dirname TEXT,
	filename TEXT,
	created TEXT,
	deleted TEXT,
	freq INTEGER);
CREATE INDEX inodes_compare ON history(inode) WHERE freq = 0;
CREATE INDEX history_update ON history(dirname, filename);
CREATE INDEX timeline ON history(freq, deleted) WHERE freq != 0;
PRAGMA journal_mode=WAL;
"
