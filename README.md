backup3
=======

My ~~third~~ _actually, forth_ attempt at making backups - using bash and SQLite.

Setup
-----

Find a writeable dir to keep your backups in (say, `/var/backups`) and run:

	BACKUP_ROOT=/var/backups init.sh

It will create necessary dirs and sqlite database to hold information.

### Requirements

* sqlite3
* flock
* bc
* df

Simple usage
------------

To backup your `/home` directory every now and then, save this file into your
crontab:

	# Required config
	export BACKUP_ROOT=/var/backups # dir to hold all backups-related data

	# rsync operations, maybe several
	rsync -a --delete /home "$BACKUP_ROOT/current"

	# Run main backup operation
	backup.sh

Advanced usage
--------------

But what if you want to backup, say, your browser data every 5 minutes, and rest
of your `$HOME` directory - only once an hour? Then use a file like this:

	#!/bin/bash

	export BACKUP_ROOT=/var/backups

	# Operations to run on every backup
	run_always()
	{
		# Backup browser profile
		run_rsync /home/lex/.config/google-chrome/Default/ browser
	}

	# Operations to run every hour
	run_hourly()
	{
		# Backup whole home directory
		run_rsync /home/lex home
	}

	# Run backup operations
	. backup.sh

Note that in last line we _source_ instead of running this script - this way we
can ensure that `backup.sh` script will see declared functions. Also note
hashbang in first line - `backup.sh` must be executed by bash.

Clean-up
--------

To ensure that 10% of disk space remains free, add these lines to the end of
above file:

	# delete old versions until at least 10% of disk space is free
	clean.sh 10 %

Restore from backup
-------------------

You can either dig manually in data dir, or use `flat.sh` to show contents of
archive for a given date.

Check that database is correct
------------------------------

It may happen that data in database is out of sync with actual files. To check
for that, run `check.sh`. To fix it by deleting existing DB records for missing
files and existing files for missing DB records, run `check.sh --delete`.

Rollback backup to previous version
-----------------------------------

In default configuration, backup database is backed up every time, too. To
restore it, pick one that you like and move it in place of current one
(`$BACKUP_ROOT/current/backup.db` by default). After that, run
`check.sh --delete` to synchronize DB with FS.
