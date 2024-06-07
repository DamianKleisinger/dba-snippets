#!/usr/bin/env bash

function print_error() {
  RED='\033[0;31m'
  NC='\033[0m'
  printf "%b$1%b\n" "${RED}" "${NC}"
}

if ! parsed_args=$(getopt -o hu:o:O:p:U:d:D:P:e --long help,origin-user:,origin-host:,origin-db:,origin-port:,destination-user:,destination-host:,destination-db:,destination-port:,export -- "$@"); then
    print_error "Error: Invalid option"
    exit 1
fi

eval set -- "$parsed_args"

function print_help() {
  cat << EOF
Usage: rename-restore-db [OPTIONS]
Backup, Rename and Restore a MySQL database

Options:
  -h, --help                  Print this help
  -u, --origin-user           Origin Database User
  -o, --origin-host           Origin host
  -O, --origin-db             Origin database
  -p, --origin-port           Origin port (default: 3306)
  -U, --destination-user      Destination Database User (default: same as origin)
  -d, --destination-host      Destination host (default: same as origin)
  -D, --destination-db        Destination database (default: same as origin)
  -P, --destination-port      Destination port (default: same as origin)
  -e, --export                Export dump to file
EOF
}

function clean_up() {
  [[ -e "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
  [[ -e "$REPLACED_BACKUP" ]] && rm -f "$REPLACED_BACKUP"
}

trap 'clean_up; print_error "Aborted"; exit 255' SIGINT SIGTERM

command -v mysqldump >/dev/null 2>&1 || { print_error "Error: mysqldump not found"; exit 3; }
command -v mysql >/dev/null 2>&1 || { print_error "Error: mysql not found"; exit 3; }
command -v pv >/dev/null 2>&1 || { print_error "Error: pv not found"; exit 3; }

while true; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -u|--origin-user)
            ORIGIN_DB_USER="$2"
            shift 2
            ;;
        -o|--origin-host)
            ORIGIN_HOST="$2"
            shift 2
            ;;
        -O|--origin-db)
            ORIGIN_DB="$2"
            shift 2
            ;;
        -p|--origin-port)
            ORIGIN_PORT="$2"
            shift 2
            ;;
        -d|--destination-host)
            DESTINATION_HOST="$2"
            shift 2
            ;;
        -U|--destination-user)
            DESTINATION_DB_USER="$2"
            shift 2
            ;;
        -D|--destination-db)
            DESTINATION_DB="$2"
            shift 2
            ;;
        -P|--destination-port)
            DESTINATION_PORT="$2"
            shift 2
            ;;
        -e|--export)
            EXPORT=true
            shift 1
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

if [ -z "$ORIGIN_DB_USER" ] || [ -z "$ORIGIN_HOST" ] || [ -z "$ORIGIN_DB" ]; then
  print_error "Error: Missing mandatory parameters"
  print_help
  exit 1
fi

ORIGIN_PORT=${ORIGIN_PORT:-3306}
DESTINATION_PORT=${DESTINATION_PORT:-$ORIGIN_PORT}
SAME_HOST=false
KEEP_DB_NAME=false

if [ -z "$DESTINATION_DB_USER" ]; then
  echo "Using same user for origin and destination"
  DESTINATION_DB_USER="$ORIGIN_DB_USER"
fi

# TODO: CHECK IF PROVIDED DEST AND ORIGIN ARE THE SAME
if [ -z "$DESTINATION_HOST" ]; then
  echo "Using same host for origin and destination"
  SAME_HOST=true
  DESTINATION_HOST="$ORIGIN_HOST"
fi

if [ -z "$DESTINATION_DB" ]; then
  echo "Keeping DB name at restore"
  KEEP_DB_NAME=true
  DESTINATION_DB="$ORIGIN_DB"
fi

if [ "$KEEP_DB_NAME" == true ] && [ "$SAME_HOST" == true ]; then
  echo "Error: Same host and same DB name, nothing to do"
  exit 1
fi

if [ -z "$MYSQL_PASS" ]; then
  read -r -s -p "MySQL Password: " MYSQL_PASS
fi

if [ -z "$MYSQL_PASS" ]; then
  print_error "Error: Password is required"
  exit 1
fi

ORIGIN_IP=$(dig +short "${ORIGIN_HOST}" A | tail -n1)

DESTINATION_IP=$(dig +short "${DESTINATION_HOST}" A | tail -n1)

BACKUP_FILE=$(mktemp /tmp/backup.XXXXXX)

if [ "$KEEP_DB_NAME" != true ]; then
  REPLACED_BACKUP=$(mktemp /tmp/replaced_backup.XXXXXX)
fi

echo ''
echo 'Getting DB size...'

QUERY_DB_SIZE="SELECT SUM(data_length + index_length) AS 'size' FROM information_schema.TABLES WHERE table_schema = '$ORIGIN_DB';"
db_size=$(mysql --user="${ORIGIN_DB_USER}" --password="${MYSQL_PASS}" --protocol=TCP --port="${ORIGIN_PORT}" --skip-ssl --host="${ORIGIN_IP}" -sn --execute="$QUERY_DB_SIZE") || { print_error "Error: Cannot connect to origin host"; exit 1; }
backup_size=$(( db_size * 80 / 100 ))

if [ $backup_size -lt 1 ]; then
  clean_up
  print_error "Error: Unable to get DB size"
  exit 3
fi

if [ "$SAME_HOST" != true ]; then
  read -p "Use different password for destination? (y/n) " -n 1 -r
  echo ''
fi

if [[ $REPLY =~ ^[Yy]$ ]]; then
  read -r -s -p "Destination MySQL Password: " DESTINATION_MYSQL_PASS
else
  DESTINATION_MYSQL_PASS="$MYSQL_PASS"
fi

if [ "$SAME_HOST" != true ]; then
  QUERY_DB_EXISTS="SELECT 'true' AS 'db_exists' FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '${DESTINATION_DB}';"
  destination_exists=$(mysql --user="${DESTINATION_DB_USER}" --password="${DESTINATION_MYSQL_PASS}" --protocol=TCP --port="${DESTINATION_PORT}" --skip-ssl --host="${DESTINATION_IP}" -sn --execute="${QUERY_DB_EXISTS}") || { print_error "Error: Cannot connect to destination host"; exit 1; }
fi

if [ "$destination_exists" == true ]; then
  read -p "Destination DB already exists, overwrite? " -n 1 -r
  echo ''
  [[ ! $REPLY =~ ^[Yy]$ ]] && { print_error "Aborted"; clean_up; exit 5; }
fi

echo "DB size $db_size bytes, estimated backup size $backup_size bytes"

echo "Starting backup from ${ORIGIN_HOST}..."
mysqldump --user="${ORIGIN_DB_USER}" --password="${MYSQL_PASS}" --protocol=TCP --port="${ORIGIN_PORT}" --skip-ssl --host="${ORIGIN_IP}" --compress --databases "${ORIGIN_DB}" --extended-insert --opt | pv -W -s ${backup_size} > "${BACKUP_FILE}"

RETURN_1=$?
if [ $RETURN_1 -ne 0 ]; then
  clean_up
  print_error "Error: Backup failed"
  exit 2
fi

echo "DB Backup completed at ${BACKUP_FILE}"

echo "Removing DEFINER to restore without SUPER privileges..."
SED_COMMAND='s/\sDEFINER=`[^`]*`@`[^`]*`//g'

if [ "$KEEP_DB_NAME" != true ]; then
  echo "DB name ${ORIGIN_DB} would be replaced with ${DESTINATION_DB}..."
  SED_COMMAND+="; s/${ORIGIN_DB}/${DESTINATION_DB}/g"
fi

echo "Replacing values in ${BACKUP_FILE} to ${REPLACED_BACKUP}..."
pv "$BACKUP_FILE" | sed -e "${SED_COMMAND}"  > "${REPLACED_BACKUP}"

if [ "$EXPORT" == true ]; then
  cp "$BACKUP_FILE" "${HOME}/${DESTINATION_DB}-$(date --iso-8601).sql"
fi

echo "Starting restore to ${DESTINATION_HOST}..."

pv "${REPLACED_BACKUP:-$BACKUP_FILE}" | mysql --user="${DESTINATION_DB_USER}" --password="${DESTINATION_MYSQL_PASS}" --protocol=TCP --port="${DESTINATION_PORT}" --skip-ssl --host="${DESTINATION_IP}"

if [ $? -ne 0 ]; then
  clean_up
  print_error "Error: Restore failed"
  exit 3
fi

read -p "Delete backup files? " -n 1 -r
echo ''
if [[ $REPLY =~ ^[Yy]$ ]]; then
  clean_up
else
  echo "Backup files are located at:"
  echo "Original -> $BACKUP_FILE"
  [ -n "$REPLACED_BACKUP" ] && echo "Replaced -> $REPLACED_BACKUP"
fi