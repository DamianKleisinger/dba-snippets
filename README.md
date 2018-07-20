# MySQL-to-S3
Backup all MySQL databases to a local folder and Amazon S3

USAGE: ./mysql_backup.sh [--cron] [--forceupload]

AWS CLI must be installed and configured:

https://docs.aws.amazon.com/cli/latest/userguide/installing.html

SETUP CRON:

crontab -e

Daily db backup @ 7:30 am

30 7 * * * /home/user/mysql-backup.sh --cron


RESTORE FROM BACKUP

$ gunzip < [backupfile.sql.gz] | mysql -u [uname] -p[pass] [dbname]
