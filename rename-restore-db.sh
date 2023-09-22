#!/bin/bash

parsed_args=$(getopt -o hu:o:d:O:D:p: --long help,user:,origin-host:,destination-host:,origin-db:,destination-db:,port: -- "$@")

if [ $? -ne 0 ]; then
    print_error "Error: Invalid option"
    exit 1
fi

eval set -- "$parsed_args"

function print_help() {
  cat << EOF
Usage: rename-restore-db.sh [OPTIONS]
Backup, Rename and Restore a MySQL database

Options:
  -h, --help                  Print this help
  -u, --user                  Database user
  -o, --origin-host           Origin host
  -O, --origin-db             Origin database
  -d, --destination-host      Destination host (default: same as origin)
  -D, --destination-db        Destination database (default: same as origin)
  -p, --port                  Port (default: 3306)
EOF
}

function print_error() {
  RED='\033[0;31m'
  NC='\033[0m'
  printf "${RED}$1${NC}\n"
}

function clean_up() {
  [ -e "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"
  [ -e "$REPLACED_BACKUP" ] && rm -f "$REPLACED_BACKUP"
}

while true ; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -u|--user)
            DB_USER="$2"
            shift 2
            ;;
        -o|--origin-host)
            ORIGIN_HOST="$2"
            shift 2
            ;;
        -d|--destination-host)
            DESTINATION_HOST="$2"
            shift 2
            ;;
        -O|--origin-db)
            ORIGIN_DB="$2"
            shift 2
            ;;
        -D|--destination-db)
            DESTINATION_DB="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            print_error "Error: Unable to parse options"
            print_help
            exit 1
            ;;
    esac
done

if [ -z "$DB_USER" ] || [ -z "$ORIGIN_HOST" ] || [ -z "$ORIGIN_DB" ]; then
  print_error "Error: Missing mandatory parameters"
  print_help
  exit 1
fi

PORT=${PORT:-3306}
SAME_HOST=false
KEEP_DB_NAME=false

if [ -z "$DESTINATION_HOST" ]; then
  SAME_HOST=true
  DESTINATION_HOST="$ORIGIN_HOST"
fi

if [ -z "$DESTINATION_DB" ]; then
  KEEP_DB_NAME=true
  DESTINATION_DB="$ORIGIN_DB"
fi

if [ -z "$MYSQL_PASS" ]; then
  read -s -p "MySQL Password: " MYSQL_PASS
fi

if [ -z "$MYSQL_PASS" ]; then
  print_error "Error: Password is required"
  exit 1
fi


ORIGIN_IP=$(dig +short ${ORIGIN_HOST} A | tail -n1)

DESTINATION_IP=$(dig +short ${DESTINATION_HOST} A | tail -n1)

BACKUP_FILE="$(mktemp)"

if [ "$KEEP_DB_NAME" != true ]; then
  REPLACED_BACKUP="$(mktemp)"
fi

echo ''
echo 'Getting DB size...'

db_size=$(mysql --user=${DB_USER} --password=${MYSQL_PASS} --protocol=TCP --port=${PORT} --skip-ssl --host=${ORIGIN_IP} -sn --execute="SELECT SUM(data_length + index_length) AS 'size' FROM information_schema.TABLES WHERE table_schema = '$ORIGIN_DB';")
backup_size=$(( db_size * 80 / 100 ))

if [ $backup_size -lt 1 ]; then
  clean_up
  print_error "Error: Unable to get DB size"
  exit 3
fi

echo "DB size $db_size bytes, estimated backup size $backup_size bytes, starting backup..."
mysqldump --user=${DB_USER} --password=${MYSQL_PASS} --protocol=TCP --port=${PORT} --skip-ssl --host=${ORIGIN_IP} --compress --databases ${ORIGIN_DB} --extended-insert --opt | pv -W -s ${backup_size} > "${BACKUP_FILE}"

RETURN_1=$?
if [ $RETURN_1 -ne 0 ]; then
  clean_up
  print_error "Error: Backup failed"
  exit 2
fi

echo "DB Backup completed at ${BACKUP_FILE}"

if [ "$KEEP_DB_NAME" != true ]; then
  total_lines=$(wc -l < "$BACKUP_FILE")
  pv "$BACKUP_FILE" | sed "s/$ORIGIN_DB/$DESTINATION_DB/g" > "$REPLACED_BACKUP"
  echo "Replacement completed at ${REPLACED_BACKUP}"
fi

echo "Starting restore..."

pv "${REPLACED_BACKUP:-$BACKUP_FILE}" | mysql --user=${DB_USER} --password=${MYSQL_PASS} --protocol=TCP --port=${PORT} --skip-ssl --host="${DESTINATION_IP}"

if [ $? -ne 0 ]; then
  clean_up
  print_error "Error: Restore failed"
  exit 3
fi

read -p "Delete backup files? " -n 1 -r
echo ''
if [[ $REPLY =~ ^[Yy]$ ]]
then
  clean_up
else
  echo "Backup files are located at:"
  echo "Original -> $BACKUP_FILE"
  [ -n "$REPLACED_BACKUP" ] && echo "Replaced -> $REPLACED_BACKUP"
fi
