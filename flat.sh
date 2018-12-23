#!/bin/sh

ROOT=$PWD/t

test -z "$SRC"            && SRC=$ROOT/a/
test -z "$DST"            # this is fine
test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$ROOT/b
test -z "$BACKUP_TMP"     && BACKUP_TMP=$ROOT/c
test -z "$BACKUP"         && BACKUP=$ROOT/d
test -z "$BACKUP_SHOW"    && BACKUP_SHOW=$ROOT/e
test -z "$BACKUP_LOG"     && BACKUP_LOG=$ROOT/rsync.log
test -z "$BACKUP_DEV"     && BACKUP_DEV=/dev/sda1
test -z "$SQLITE_DB"      && SQLITE_DB=backup.db

SQLITE="sqlite3 $SQLITE_DB"

rm -rf "$BACKUP_SHOW"

$SQLITE "PRAGMA case_sensitive_like = ON;
	SELECT dirname, filename, created FROM history
	WHERE
	dirname LIKE '$dir%'
	AND  created <= '$NOW'
	AND (freq = 0 OR deleted > '$NOW')" | while IFS='|' read dirname filename created; do
	mkdir -p "$BACKUP_SHOW"/"$dirname"
	fullname="$dirname/$filename"
	if test -n "$created"; then
		newname="$fullname#$created"
		ln "$BACKUP"/"$newname" "$BACKUP_SHOW"/"$fullname"
	else
		newname="$fullname"
		ln "$BACKUP_CURRENT"/"$newname" "$BACKUP_SHOW"/"$fullname"
	fi
	deleted=""
done
