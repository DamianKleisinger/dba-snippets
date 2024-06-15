#!/usr/bin/env bash

function print_error() {
  local RED='\033[0;31m'
  local NC='\033[0m'
  printf "%b%s%b\n" "${RED}" "$1" "${NC}"
}

function print_help() {
  cat << EOF
Usage: rename-restore-db [OPTIONS]
Backup, Rename and Restore a MySQL database

Options:
  -h, --help                  Print this help message
  -u, --origin-user           Origin Database User
  -o, --origin-host           Origin Host
  -O, --origin-db             Origin Database
  -p, --origin-port           Origin Port (default: 3306)
  -U, --destination-user      Destination Database User (default: same as origin)
  -d, --destination-host      Destination Host (default: same as origin)
  -D, --destination-db        Destination Database (default: same as origin)
  -P, --destination-port      Destination Port (default: same as origin)
  -e, --export-only           Export dump to file
EOF
}

function clean_up() {
  [[ -e "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
  [[ -e "$REPLACED_BACKUP" ]] && rm -f "$REPLACED_BACKUP"
}

function check_command() {
  command -v "$1" >/dev/null 2>&1 || { print_error "Error: $1 not found"; exit 3; }
}

trap 'clean_up; print_error "Aborted"; exit 255' SIGINT SIGTERM

# Check if required commands are available
for cmd in mysqldump mysql pv; do
  check_command "$cmd"
done

# Parse arguments
if ! parsed_args=$(getopt -o hu:o:O:p:U:d:D:P:e --long help,origin-user:,origin-host:,origin-db:,origin-port:,destination-user:,destination-host:,destination-db:,destination-port:,export-only -- "$@"); then
  print_error "Error: Invalid option"
  exit 1
fi
eval set -- "$parsed_args"

# Process arguments
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
    -U|--destination-user)
      DESTINATION_DB_USER="$2"
      shift 2
      ;;
    -d|--destination-host)
      DESTINATION_HOST="$2"
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
    -e|--export-only)
      EXPORT_ONLY=true
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

# Validate mandatory parameters
if [ -z "$ORIGIN_DB_USER" ] || [ -z "$ORIGIN_HOST" ] || [ -z "$ORIGIN_DB" ]; then
  print_error "Error: Missing mandatory parameters"
  print_help
  exit 1
fi

# Set default values if not provided
ORIGIN_PORT=${ORIGIN_PORT:-3306}
DESTINATION_PORT=${DESTINATION_PORT:-$ORIGIN_PORT}
SAME_HOST=false
KEEP_DB_NAME=false
DESTINATION_DB_USER=${DESTINATION_DB_USER:-$ORIGIN_DB_USER}

if [[ -z "$DESTINATION_HOST" ]]; then
  echo "Using same host for origin and destination"
  SAME_HOST=true
  DESTINATION_HOST="$ORIGIN_HOST"
fi

# Set default destination database name if not provided
if [[ -z "$DESTINATION_DB" ]]; then
  echo "Keeping DB name at restore"
  KEEP_DB_NAME=true
  DESTINATION_DB="$ORIGIN_DB"
fi

# Check for invalid configuration
if [[ "$KEEP_DB_NAME" == true && "$SAME_HOST" == true && "$EXPORT_ONLY" != true ]]; then
  print_error "Error: Same host and same DB name, nothing to do"
  exit 1
fi

# Prompt for MySQL password if not set
if [[ -z "$MYSQL_PASS" ]]; then
  read -r -s -p "MySQL Password: " MYSQL_PASS
  echo ''
fi

if [[ -z "$MYSQL_PASS" ]]; then
  print_error "Error: Password is required"
  exit 1
fi

# Resolve IP addresses
ORIGIN_IP=$(dig +short "${ORIGIN_HOST}" A | tail -n1)
DESTINATION_IP=$(dig +short "${DESTINATION_HOST}" A | tail -n1)

# Create temporary files for backup
TMP_DIR=$(mktemp -d /tmp/backup.XXXXXX)
BACKUP_FILE="$TMP_DIR/backup.sql"
REPLACED_BACKUP="$TMP_DIR/replaced_backup.sql"

echo 'Getting DB size...'
QUERY_DB_SIZE="SELECT SUM(data_length + index_length) AS 'size' FROM information_schema.TABLES WHERE table_schema = '$ORIGIN_DB';"
db_size=$(mysql --user="${ORIGIN_DB_USER}" --password="${MYSQL_PASS}" --protocol=TCP --port="${ORIGIN_PORT}" --skip-ssl --host="${ORIGIN_IP}" -sn --execute="$QUERY_DB_SIZE") || { print_error "Error: Cannot connect to origin host"; exit 1; }
backup_size=$(( db_size * 80 / 100 ))

if [[ $backup_size -lt 1 ]]; then
  clean_up
  print_error "Error: Unable to get DB size"
  exit 3
fi

echo "DB size $db_size bytes, estimated backup size $backup_size bytes"

echo "Starting backup from ${ORIGIN_HOST}..."
mysqldump --user="${ORIGIN_DB_USER}" --password="${MYSQL_PASS}" --protocol=TCP --port="${ORIGIN_PORT}" --skip-ssl --host="${ORIGIN_IP}" --compress --databases "${ORIGIN_DB}" --extended-insert --opt | pv -W -s ${backup_size} > "${BACKUP_FILE}"

RETURN_1=$?
if [ $RETURN_1 -ne 0 ]; then
  clean_up
  print_error "Error: mysqldump failed with exit code ${RETURN_1}"
  exit 2
fi

echo "DB Backup completed at ${BACKUP_FILE}"

if [[ "$KEEP_DB_NAME" != true ]]; then
  echo "DB name ${ORIGIN_DB} will be replaced with ${DESTINATION_DB} in the backup file..."
  SED_COMMAND="s/${ORIGIN_DB}/${DESTINATION_DB}/g"
fi

read -p "Remove definer from backup? (y/n) " -n 1 -r
echo ''
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Removing DEFINER to restore without SUPER privileges..."
  SED_COMMAND+="${SED_COMMAND:+;}"
  SED_COMMAND+='s/\sDEFINER=`[^`]*`@`[^`]*`//g'
fi

if [[ -n "$SED_COMMAND" ]]; then
  echo "Replacing values in ${BACKUP_FILE} to ${REPLACED_BACKUP}..."
  # TODO: replace file in place to avoid disk space issues
  # sed -i -e "${SED_COMMAND}" "$BACKUP_FILE"
  pv "$BACKUP_FILE" | sed -e "${SED_COMMAND}" > "${REPLACED_BACKUP}"
  rm -f "$BACKUP_FILE"
else
  rm -f "$REPLACED_BACKUP"
  REPLACED_BACKUP="$BACKUP_FILE"
fi

# Export backup file to home
function export_backup() {
  local export_path="${HOME}/${DESTINATION_DB}-$(date --iso-8601)-replaced.sql"
  if [[ -e "$REPLACED_BACKUP" ]]; then
    echo "Saving replaced backup file to ${export_path}"
    mv "$REPLACED_BACKUP" "${export_path}"
  fi
}

if [[ "$EXPORT_ONLY" == true ]]; then
  export_backup
  clean_up
  exit 0
fi

echo "Starting restore to ${DESTINATION_HOST}..."

if [[ "$SAME_HOST" != true ]]; then
  read -p "Use different password for destination? (y/n) " -n 1 -r
  echo ''
fi

if [[ $REPLY =~ ^[Yy]$ ]]; then
  read -r -s -p "Destination MySQL Password: " DESTINATION_MYSQL_PASS
  echo ''
else
  DESTINATION_MYSQL_PASS="$MYSQL_PASS"
fi

if [[ "$SAME_HOST" != true ]]; then
  QUERY_DB_EXISTS="SELECT 'true' AS 'db_exists' FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '${DESTINATION_DB}';"
  destination_exists=$(mysql --user="${DESTINATION_DB_USER}" --password="${DESTINATION_MYSQL_PASS}" --protocol=TCP --port="${DESTINATION_PORT}" --skip-ssl --host="${DESTINATION_IP}" -sn --execute="${QUERY_DB_EXISTS}") || { print_error "Error: Cannot connect to destination host"; exit 1; }
fi

if [[ "$destination_exists" == true ]]; then
  read -p "Destination DB already exists, overwrite? (y/n) " -n 1 -r
  echo ''
  [[ ! $REPLY =~ ^[Yy]$ ]] && { print_error "Aborted"; clean_up; exit 5; }
fi

pv "${REPLACED_BACKUP}" | mysql --user="${DESTINATION_DB_USER}" --password="${DESTINATION_MYSQL_PASS}" --protocol=TCP --port="${DESTINATION_PORT}" --skip-ssl --host="${DESTINATION_IP}"
IMPORT_RETURN_CODE=$?
if [[ $IMPORT_RETURN_CODE -ne 0 ]]; then
  clean_up
  print_error "Error: mysql restore failed with exit code ${IMPORT_RETURN_CODE}"
  exit 3
fi

read -p "Keep backup files? (y/n) " -n 1 -r
echo ''
if [[ $REPLY =~ ^[Yy]$ ]]; then
  export_backup
fi

clean_up
