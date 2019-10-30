#!/bin/busybox ash

rm -rf test
mkdir -p test/src
export BACKUP_ROOT="$PWD/test"
export BACKUP_FROM="$PWD/test/src"
export BACKUP_TIME_FORMAT="%F %T"
./init.sh

filename=" tricky _-'\"\$(touch GOTCHA)ы "

verify() {
	tree --inodes test
	sqlite3 -column -header test/backup.db 'select * from history;'
	echo "looks good?"
	read
}


# test 1: just create the file
touch "test/src/$filename"
./backup1.sh r "$filename"
verify

# test 2: delete it
./backup1.sh u "$filename"
verify

# test 3: create it again
./backup1.sh r "$filename"
verify
