#!/bin/bash
#
# Backup script for backuping VestaCP backups and Odoo-server to remote Hetzner Nextcloud storage
# for ZozulyaGroup
# Written Andrii Kisil <kisilams@gmail.com>
#

# VestaCP backup dir
v_backup=/backup/

# Odoo-server backup directory
odoo_backup=/opt/odoo/backups/

# Nextcloud DAV directory, mount localy
HETZNER=/mnt/hetzner

# Log file
B_LOG=/root/hetzner-backup.log

cur_date=$(date +"%H-%M_%d-%m-%Y\n")

LINE="--------------------------------------------------------------------\n"

# Backup for VestaCP
echo -e $LINE >> $B_LOG

echo -e $cur_date >> $B_LOG

echo -e "Start backupping for VestaCP\n" >> $B_LOG

/usr/bin/rsync -avz --delete $v_backup $HETZNER/vesta/ >> $B_LOG

echo -e "\n" >> $B_LOG

echo -e "Finished backup for VestaCP\n" >> $B_LOG

echo -e $LINE >> $B_LOG

#Backup for Odoo
echo -e $LINE >> $B_LOG

echo -e $cur_date >> $B_LOG

echo -e "Start backupping for Odoo\n" >> $B_LOG

/usr/bin/rsync -avz --delete $odoo_backup $HETZNER/odoo/ >> $B_LOG

echo -e "\n" >> $B_LOG

echo -e "Finished backup for Odoo\n" >> $B_LOG

echo -e $LINE >> $B_LOG
