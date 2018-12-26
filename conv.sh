#!/bin/sh
#
# Script to convert from "old" (rsync --link-dest) style to current one.
#
# "old style" expected to be like {hourly,daily,monthly,etc}/$(date +"%F_%T")
#
# Call it like this:
# $ conv.sh /backups/homes homes

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current

SRC="$1"
DST="$2"

test -e "$BACKUP_CURRENT/$DST" && exit 3

(cd "$SRC"; ls -d */*/) | sed 's_/_ _' | sort -k 2 | uniq -f 1 | sed 's_ _/_' | while read dir; do
	mv "$SRC/$dir" "$BACKUP_CURRENT/$DST"
	time="${dir#*/}"
	time="${time%/}"
	export BACKUP_TIME="$(echo "$time" | sed 's/_/ /')"
	echo "processing [$BACKUP_TIME] from [$SRC/$dir]..."
	bash ~/backup3/backup.sh
	mv "$BACKUP_CURRENT/$DST" "$SRC/$dir"
done

