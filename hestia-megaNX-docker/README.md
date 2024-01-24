This is a simple script and Docker container for copying the last backups from the HESTIA host to a Mega.nz storage using a megaCDM container.


Create a container from a built image

    docker build --no-cache -t megacmd-ubuntu:18.04 .

    docker create -m 512M --cpuset-cpus 1  -ti --name meganz -v /backup:/backup  megacmd-ubuntu:18.04

After preparing all resources You need to add a script to the cron task. I tested this script on the Ubuntu 22.04 and have placed the script to the /etc/weekly.cron folder (script must has not extension). 
I have added my own HESTIA users on to the script, You need to edit script for your situation.
