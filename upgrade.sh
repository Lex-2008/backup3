#!/bin/busybox ash

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now

SQLITE="sqlite3 $BACKUP_DB"

$SQLITE "SELECT dirname,
		filename,
		created,
		deleted
	FROM history
	WHERE freq != 0;" | sed 's_\(.*\)|\(.*\)|\(.*\)|\(.*\)_'"
		mv '$BACKUP_MAIN/\\1/\\2/\\3' '$BACKUP_MAIN/\\1/\\2/\\3$BACKUP_TIME_SEP\\4'
		_;" | sh

$SQLITE "SELECT dirname,
		filename,
		created
	FROM history
	WHERE freq = 0;" | sed 's_\(.*\)|\(.*\)|\(.*\)_'"
		mv '$BACKUP_MAIN/\\1/\\2/\\3' '$BACKUP_MAIN/\\1/\\2/\\3$BACKUP_TIME_SEP$BACKUP_TIME_NOW'
		_;" | sh

