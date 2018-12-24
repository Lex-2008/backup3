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

