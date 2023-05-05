#!/bin/bash
#dst_dir for key
DS_SSL_DIR=/home/sammy/.minio/certs/docs.movingboardsusa.com
#Domain
LE_DOMAIN=docs.example.com
#User
KEY_USER=minio-user
#Group
KEY_GROUP=minio-user
#Service

cp -H /etc/letsencrypt/live/$LE_DOMAIN/privkey.pem $DS_SSL_DIR/private.key
cp -H /etc/letsencrypt/live/$LE_DOMAIN/fullchain.pem $DS_SSL_DIR/public.crt

chown $KEY_USER:$KEY_GROUP $DS_SSL_DIR/*
#chmod 660 $EXIM_SSL_DIR/*

/bin/systemctl restart minio.service
