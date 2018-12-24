#!/bin/sh
#
# Script to show contents of archive for a given date.
#
# Call it like this:
# $ flat.sh "2018-12-24 00:24:00" stuff /tmp/dir
# to hard-link files from "stuff" directory in backup to /tmp/dir

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db

SHOW_DATE="$1"
SHOW_DIR="$2"
SHOW_IN="$3"

SQLITE="sqlite3 $BACKUP_DB"

rm -rf "$BACKUP_SHOW"

$SQLITE "PRAGMA case_sensitive_like = ON;
	SELECT dirname, filename, created
	FROM history
	WHERE
		dirname LIKE '$SHOW_DIR%'
		AND  created <= '$SHOW_DATE'
		AND (freq = 0 OR deleted > '$SHOW_DATE');" | while IFS='|' read dirname filename created; do
	# TODO: remove $SHOW_DIR from "$dirname"
	mkdir -p "$SHOW_IN"/"$dirname"
	fullname="$dirname/$filename"
	if test -n "$created"; then
		newname="$fullname#$created"
		ln "$BACKUP_MAIN"/"$newname" "$SHOW_IN"/"$fullname"
	else
		newname="$fullname"
		ln "$BACKUP_CURRENT"/"$newname" "$SHOW_IN"/"$fullname"
	fi
	deleted=""
done
