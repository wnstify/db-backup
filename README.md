MySQL/MariaDB Backup Script
===========================

A simple, robust bash script for backing up MySQL/MariaDB databases on Linux systems.

![MySQL Backup](https://img.shields.io/badge/MySQL-Backup-blue) ![MariaDB Backup](https://img.shields.io/badge/MariaDB-Backup-orange) ![Bash](https://img.shields.io/badge/Bash-Script-green)

Features
--------

*   Dumps each non-system database to compressed `.sql.gz` files
*   Creates timestamped backup folders
*   Packs all database dumps into a single tar.gz archive
*   Configurable retention policy (auto-delete old backups)
*   Safe authentication using external config file
*   Intelligent compression (uses pigz for multi-threaded compression if available)
*   Comprehensive logging
*   Lock mechanism to prevent concurrent runs 

Requirements
------------

*   Bash shell
*   MySQL/MariaDB client tools
*   gzip (or pigz for faster compression)

Installation
------------

1.  Download the script:
    
        wget https://raw.githubusercontent.com/wnstify/db-backup/refs/heads/main/db_backup.sh
        chmod +x db_backup.sh
    
2.  (Optional) Create a credentials file to avoid password prompts:
    
        echo -e "[client]\nuser=root\npassword=YOUR_PASSWORD" > .db.cnf
        chmod 600 .db.cnf
    

Usage
-----

Simply run the script:

    ./mysql_backup.sh

Or set up a cron job for automated backups:

    # Run daily at 2:30 AM
    30 2 * * * /path/to/mysql_backup.sh

Configuration
-------------

Edit these variables at the top of the script:

    LOCAL_BACKUP_DIR="${PWD}/db_backups"   # where backups are stored
    KEEP_DAYS=14                           # retention period (0 = keep forever)
    REMOVE_FOLDER_AFTER_ARCHIVE=true       # remove individual dumps after archiving

How It Works
------------

1.  Creates a timestamped directory for the current backup
2.  Connects to MySQL/MariaDB and gets a list of non-system databases
3.  Dumps each database with optimal settings for reliable restores
4.  Compresses each dump with gzip/pigz
5.  Archives all dumps into a single tar.gz file
6.  Cleans up old backups according to retention policy
7.  Logs all operations

🌟 Premium Version Available 🌟
-------------------------------

For more advanced features, check out our **Premium Backup Solution**:

*   **Enhanced Security**: AES-256 encryption for all backups
*   **Multi-destination Support**: Upload to S3, Google Drive, FTP, SFTP
*   **Notification System**: Email, SMS, or Slack alerts
*   **Integrity Verification**: Automatic backup validation
*   **Cron Wizard**: Easy scheduling interface
*   **Remote Upload Wizard**: Simple configuration for cloud storage

### How to Get Premium Version

The premium version is available exclusively for Webnestify YouTube channel members.

**Join our channel**: [https://www.youtube.com/channel/UCqkKrB0YsnooQsRmwkBEV3g/join](https://www.youtube.com/channel/UCqkKrB0YsnooQsRmwkBEV3g/join)

Disclaimer
----------

This script is provided "AS IS", without any warranty, express or implied. The author is not responsible for any damages or data loss. By using this script, you accept full responsibility.

Author
------

Simon Gajdosik (Webnestify)

License
-------

MIT