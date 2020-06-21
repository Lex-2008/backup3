#!/bin/busybox ash

rm -rf test
mkdir test
export BACKUP_ROOT="$PWD/test"
export BACKUP_TIME_FORMAT="%F %T"
export BACKUP_CONFIG="/dev/null"
./init.sh

filename="simple"

verify() {
	./backup.sh
	tree --inodes test
	sqlite3 test/backup.db 'select * from history;'
	echo "looks good?"
	read
}

# step 1: create the file
touch "test/current/$filename"

./backup.sh
sleep 1

# step 2: turn file into dir
rm "test/current/$filename"
mkdir "test/current/$filename"

verify

# step 3: turn dir into file
rm -r "test/current/$filename"
touch "test/current/$filename"

verify
