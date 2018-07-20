#!/bin/bash
#==============================================================================
#
#	FILE: mysql-backup.sh
#
#	USAGE: ./mysql_backup.sh [--cron] [--forceupload]
#
#	DESCRIPTION: Script for automated mysql backups and optional S3 uploads
#
#	AUTHOR: Damian Kleisinger
#
#	AWS CLI must be installed and configured
#	DOCS: https://docs.aws.amazon.com/cli/latest/userguide/installing.html
#	
#	SETUP CRON:
#	Daily db backup @ 7:30 am
#	min	hr	mday	month	wday	command
#	30	7	*		*		*		/home/user/mysql-backup.sh
#
#	RESTORE FROM BACKUP
#	$ gunzip < [backupfile.sql.gz] | mysql -u [uname] -p[pass] [dbname]
#
#==============================================================================
# FIXED VARIABLES
#==============================================================================

EPARAM=$@ # All Execution Parameters

# Current date and time parameters
TIMESTAMP=$(date +%F) # YYYY-MM-DD
TIMEPRINT=$(date +%F" "%T) # YYYY-MM-DD HH:MM:SS
CURRENTDAY=$(date +"%u") # Day of week
DAYNAME=$(date +"%A") # Full weekday name

#==============================================================================
# CUSTOM SETTINGS
#==============================================================================

# Directory to put the backup files
BACKUP_DIR=/home/user/db_backups

# Log File location
# To save in /var/log, first you must create the file and grant acces
# "sudo touch /var/log/mysql_s3_backup.log && sudo chown $USER /var/log/mysql_s3_backup.log"
LOG_FILE=/var/log/mysql_s3_backup.log

# TMP file
TMPBL=/tmp/tmplistbk.$$

# MYSQL Parameters
MYSQL_UNAME=mysql-user
MYSQL_PWORD=mysql-pass

# Don't backup matching DBs (REGEX)
# Example: starts with mysql (^mysql) or ends with _schema (_schema$)
IGNORE_DB="(^mysql|_schema$)"

# Include mysql and mysqldump binaries for cron bash user
PATH=$PATH:/usr/local/mysql/bin

# Number of days to keep backups
KEEP_BACKUPS_FOR=7 			# days

# S3 Bucket
S3_BUCKET=bucket/key

# Day to upload
UPLOAD_DAY=(1 7)			# Could be more than one, inside () separated by space

#==============================================================================
# FUNCTIONS
#==============================================================================

function check_parameters(){
	for i in $EPARAM
	do
		case "$i" in
			'--cron'|'-c')
			CRON=true
			;;
			'--forceupload'|'-f')
			FORCES3=true
			;;
			*)
			printf "%s$i Its not a valid option"'\n'
			exit
			;;
		esac
	done 
}

function delete_old_backups() {
	echo_pluslog "Deleting $BACKUP_DIR/*.sql.gz older than $KEEP_BACKUPS_FOR days"
	find $BACKUP_DIR -type f -name "*.sql.gz" -mtime +$KEEP_BACKUPS_FOR -exec rm {} \;
}

function mysql_login() {
	local mysql_login="-u $MYSQL_UNAME" 
	if [ -n "$MYSQL_PWORD" ]; then
		local mysql_login+=" -p$MYSQL_PWORD" 
	fi
	echo $mysql_login
}

function database_list() {
#MYSQL command to list all dbs minus the $IGNORE_DB
	local show_databases_sql="SHOW DATABASES WHERE \`Database\` NOT REGEXP '$IGNORE_DB'"
	echo $(mysql $(mysql_login) -e "$show_databases_sql"|awk -F " " '{if (NR!=1) print $1}')

}

function echo_pluslog(){
	if [ "$CRON" == true ]; then
		printf "$1"'\n' >> $LOG_FILE
	else
		printf "$1"'\n' >> $LOG_FILE
		printf "$1"'\n'
	fi
	}

function backup_database(){
	backup_file="$BACKUP_DIR/$TIMESTAMP.$database.sql.gz"
	echo_pluslog "$database\t\t\t=>\t$backup_file\t... $count of $total databases"
	$(mysqldump $(mysql_login) $database | gzip -9 > $backup_file)
    	local mysqlexit=$?
	echo "$backup_file" >> $TMPBL
	if [[ $mysqlexit = "0" ]]; then
		echo_pluslog "$database backup completed successfully"
	else
		echo_pluslog "error $mysqlexit couldnt backup $database db"
	fi
}

function backup_databases(){
	local databases=$(database_list)
	local total=$(echo $databases | wc -w | xargs)
	local output=""
	local count=1
	for database in $databases; do
		backup_database
		local count=$((count+1))
	done
	echo -ne $output | column -t
}

function hr(){
	if [ "$CRON" == true ]; then
		printf '=%.0s' {1..100} >> $LOG_FILE
		printf "\n" >> $LOG_FILE
	else
		printf '=%.0s' {1..100}
		printf "\n"
		printf '=%.0s' {1..100} >> $LOG_FILE
		printf "\n" >> $LOG_FILE
	fi
}

function topline(){
	if [ "$CRON" == true ]; then
		printf '*%.0s' {1..100} >> $LOG_FILE
        printf "\n" >> $LOG_FILE
       	printf "Cron Backup started at $TIMEPRINT" >> $LOG_FILE
		printf "\n" >> $LOG_FILE
	else
		printf '*%.0s' {1..100} >> $LOG_FILE
		printf '*%.0s' {1..100}
       	printf "\n" >> $LOG_FILE
       	printf "\n"
		printf "Manual Backup started at $TIMEPRINT" >> $LOG_FILE
		printf "Manual Backup started at $TIMEPRINT"
		printf "\n" >> $LOG_FILE
		printf "\n"
	fi
}

function s3_upload(){
	for backup_file in $(cat $TMPBL); do
		aws s3 cp $backup_file s3://${S3_BUCKET}/
		local retval="$?"
		if [ $retval = 0 ]; then
			echo_pluslog "$backup_file successfully uploaded to S3 storage"
		else
			echo_pluslog "Error $retval uploading $backup_file to S3 storage"
		fi
		unset retval
	done
}

function upload_backup(){
	if [[ " ${UPLOAD_DAY[*]} " == *$CURRENTDAY* ]]; then
		echo_pluslog "It's $DAYNAME, time to upload"
		s3_upload
	elif [[ "$FORCES3" == "true" ]]; then
		echo_pluslog "Force upload activated, time to upload"
		s3_upload
	else
		echo_pluslog "$DAYNAME, No time to upload"
	fi
}

function close_routine(){
	rm -f $TMPBL
	hr
	echo_pluslog "database backup job finished at $(date +%F" "%T)"
	if [ "$CRON" != true ]; then
		printf '*%.0s' {1..100}
		printf '\n'
	fi
}

#==============================================================================
# RUN SCRIPT
#==============================================================================
check_parameters
topline
hr
delete_old_backups
hr
backup_databases
hr
upload_backup
close_routine
