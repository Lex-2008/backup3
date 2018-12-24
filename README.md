backup3
=======

My third attempt at making backups (hence the name) - using bash and SQLite.

Setup
-----

### Requirements

* sqlite3
* bc
* df

Simple usage
------------

	# Required config
	export BACKUP_ROOT=/var/backups # dir to hold all backups-related data
	export BACKUP_CURRENT=$BACKUP_ROOT/current # rsync your stuff here

	# rsync operations, maybe several
	rsync -a --delete /home $BACKUP_CURRENT/homes

	# run main backup operation
	backup.sh

	# delete old versions until at least 10% of disk space is free
	clean.sh 10 %

