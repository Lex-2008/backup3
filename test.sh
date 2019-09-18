#!/bin/busybox ash

rm -rf test
mkdir test
export BACKUP_ROOT="$PWD/test"
./init.sh

filename=" tricky _-'\"\$(touch GOTCHA)ы "
# filename="simple"

verify() {
	./backup.sh
	tree --inodes test
	sqlite3 test/backup.db 'select * from history;'
	echo "looks good?"
	read
}

# test 1: just create the file
touch "test/current/$filename"

verify

# test 2: edit it
touch "test/current/new"
mv "test/current/new" "test/current/$filename"

verify

# test 3: delete it
rm "test/current/$filename"

verify
