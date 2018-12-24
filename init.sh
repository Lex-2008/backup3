#!/bin/sh
#
# Script to init DB.


test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_CURRENT/backup.db

SQLITE="sqlite3 $BACKUP_DB"

mkdir -p $BACKUP_CURRENT $BACKUP_MAIN

$SQLITE "CREATE TABLE history(
	dirname TEXT NOT NULL,
	filename TEXT NOT NULL,
	created TEXT NOT NULL,
	deleted TEXT,
	freq INTEGER NOT NULL);
CREATE INDEX history_update
ON history(
	dirname,
	filename)
WHERE freq = 0;"
