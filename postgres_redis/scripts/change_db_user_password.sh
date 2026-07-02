#!/bin/bash

# Script to change a PostgreSQL user's password
# Usage: ./change_db_user_password.sh <username> <new_password>

# Check if all arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <username> <new_password>"
    exit 1
fi

USERNAME=$1
NEW_PASSWORD=$2

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

echo "Changing password for PostgreSQL user '$USERNAME'..."

# switch to postgres user to execute commands
sudo -u postgres bash <<EOF

# Check if user exists
if psql -t -c '\du' | cut -d \| -f 1 | grep -qw "$USERNAME"; then
    psql -c "ALTER USER $USERNAME WITH PASSWORD '$NEW_PASSWORD';"
    echo "Password for user '$USERNAME' updated successfully."
else
    echo "Error: User '$USERNAME' does not exist."
    exit 1
fi

EOF
