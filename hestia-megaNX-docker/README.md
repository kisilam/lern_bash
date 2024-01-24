This is seample scripts and Docker container for copying last backups from HESTIA host to a Mega.nz storage using megaCDM container.


Create contsiner from build image

docker build --no-cache -t megacmd-ubuntu:18.04 .

docker create -m 512M --cpuset-cpus 1  -ti --name meganz -v /backup:/backup  megacmd-ubuntu:18.04
