#!/bin/bash
#
# Backup script for backuping VestaCP backups and Odoo-server to remote Hetzner Nextcloud storage
# for ZozulyaGroup
# Written Andrii Kisil <kisilams@gmail.com>
#

#Mount and umount DAV FS
DAV_FS=/usr/sbin/mount.davfs
DAV_FS_U=/usr/sbin/umount.davfs

# Remoute URL fro connect
DAV_REMOUTE=https://nx17062.your-storageshare.de/remote.php/dav/files/Admin/backup/

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

#Mount remoute folder
$DAV_FS $DAV_REMOUTE $HETZNER
sleep 5

# Starting try to backup
echo -e $LINE >> $B_LOG
echo -e $cur_date >> $B_LOG

# Check if remoute folder is mount
if [[ -d $HETZNER/odoo ]] || [[ -d $HETZNER/vesta  ]] then
	#Starting VestaCP backup
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
	
	#Umount reote DIR
	$DAV_FS_U $HETZNER
else
	echo -e "Seams like remoute directory doesn't mount. Check it. Canceling backuping.\n" >>$B_LOG
	echo -e $LINE >> $B_LOG
fi