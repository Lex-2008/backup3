#!/bin/sh
#
# Script to convert from "old" (rsync --link-dest) style to current one.
#
# "old style" expected to be like {hourly,daily,monthly,etc}/$(date +"%F_%T")
#
# First, create list of dirs to process:
# $ migrate.sh --files /backups/homes/*/* >files.txt
#
# Then, call it like this to process the generated list:
# $ migrate.sh files.txt homes | tee log.log


if test "$1" = "--files"; then
	shift
	ls -d "$@" | sed -r 's_(.*)/(.*)_\1 \2_' | sort -k 2 | uniq -f 1 | sed 's_(.*) (.*)_\1/\2_'
	exit
fi

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current

BACKUP_DB_BAK=no
export BACKUP_DB_BAK

files="$1"
DST="$2"

while read dir; do
	test -f "$files.stop"
	echo "no $files.stop file, moving on!"
	time="${dir%/}"
	time="${time##*/}"
	export BACKUP_TIME="$(date -d "$(echo "$time" | sed -r 's/_/ /;s/(.*)-(.*)-(.*)/\1:\2:\3/')" +"%F %H:%M")"
	echo "processing [$BACKUP_TIME] from [$dir]..."
	mv "$dir" "$BACKUP_CURRENT/$DST"
	bash ~/backup3/backup.sh
	mv "$BACKUP_CURRENT/$DST" "$dir"
done <"$files"
echo remember to move last directory back to "$BACKUP_CURRENT/$DST"
