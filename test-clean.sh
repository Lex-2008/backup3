#!/bin/bash

if [ "$EUID" -ne 0 ]; then
	echo "Please run as root"
	exit
fi

umount test/img
rm -rf test
mkdir test

dd if=/dev/zero of=test/img count=0 bs=1M seek=10 2>/dev/null
yes | mkfs.ext4 -q test/img >/dev/null
mkdir test/fs
mount test/img test/fs

export BACKUP_ROOT="$PWD/test/fs"
export BACKUP_TIME_FORMAT="%F %T"
export BACKUP_CONFIG="/dev/null"
./init.sh

size=500k
counta=4
countx=1
countz=1
countb=4
county=2
countc=4

verify() {
	df -h test/fs
	sqlite3 test/fs/backup.db 'select * from history ORDER BY filename;'
	./backup.sh
	# tree --inodes $BACKUP_ROOT
	df -h test/fs
	sqlite3 test/fs/backup.db 'select * from history ORDER BY filename;'
	echo "looks good?"
	read
}

mkfiles() { #name count
	for i in $(seq $2); do
		dd if=/dev/zero of=test/fs/current/$1$i bs=$size count=1 2>/dev/null
	done
}

rmfiles() { #name count
	for i in $(seq $2); do
		rm test/fs/current/$1$i
	done
}

mkfiles a $counta
mkfiles x $countx
mkfiles z $countx

./backup.sh
sleep 1

rmfiles x $countx
rmfiles z $countx
mkfiles b $countb
mkfiles y $county

./backup.sh
sleep 1

rmfiles y $county
mkfiles c $countc

sqlite3 test/fs/backup.db "update history set created='2019-01-01 00:00:00' where filename like 'z%';"
verify

umount test/img
