# MySQL-to-S3
Backup all MySQL databases to a local folder and Amazon S3


**AWS CLI must be installed and configured:**

https://docs.aws.amazon.com/cli/latest/userguide/installing.html


## USAGE:

To run from terminal:

```$ ./mysql_backup.sh [--cron] [--forceupload]```

To add a cron job for daily db backup @ 3:30 am, edit the crontab whit `$ crontab -e`, then insert `30 3 * * * /home/user/mysql-backup.sh --cron` and save.


To restore a db from backup: ```$ gunzip < [backupfile.sql.gz] | mysql -u [uname] -p[pass] [dbname]```
