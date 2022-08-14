#!/bin/sh
#
# Script to create a (NEW) backup from git repo.
#
# Create separate local.sh and export BACKUP_CONFIG pointing to it.
# Then, start this script like this:
#
# git2backup.sh [--init] project /path/to/git/repo
#
# Optional --init wipes BACKUP_MAIN dir!

test -z "$BACKUP_CONFIG" && exit 1

test -z "$BACKUP_BIN" && BACKUP_BIN="${0%/*}"
. "$BACKUP_BIN/common.sh"

if [ "$1" = "--init" ]; then
	rm -rf "$BACKUP_MAIN" "$BACKUP_CURRENT"
	"$BACKUP_BIN/init.sh"
	shift
fi

DST="$1"
SRC="$2"

git -C "$SRC" checkout master
git -C "$SRC" pull
git -C "$SRC" log --reverse --pretty='format:%H %ci' >"$BACKUP_TMP/hashes"

while read -r hash date time tz; do
	export BACKUP_TIME="$date $time"
	# Check that BACKUP_TIME differs from prev one.
	# If they're the same - ignore second commit.
	# It's like if changes are squashed into next one -
	# While it's not entirely correct, it's "goodenough" for demo.
	test "$BACKUP_TIME" = "$old_BACKUP_TIME" && continue
	old_BACKUP_TIME="$BACKUP_TIME"
	echo "processing [$BACKUP_TIME]..."
	git -C "$SRC" checkout -q "$hash"
	rsync -a --exclude=.git "$SRC/" "$BACKUP_CURRENT/$DST"
	"$BACKUP_BIN/backup.sh"
done <"$BACKUP_TMP/hashes"

