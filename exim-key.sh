#!/bin/bash
#dst_dir for exim key
EXIM_SSL_DIR=/etc/exim4/ssl
#Domain
LE_DOMAIN=mail.zozulya.sale

cp -H /etc/letsencrypt/live/$LE_DOMAIN/privkey.pem $EXIM_SSL_DIR/privkey.pem
cp -H /etc/letsencrypt/live/$LE_DOMAIN/fullchain.pem $EXIM_SSL_DIR/fullchain.pem

chown root:mail $EXIM_SSL_DIR/*
chmod 660 $EXIM_SSL_DIR/*

/bin/systemctl restart nginx.service
/bin/systemctl restart dovecot.service
/bin/systemctl restart exim4.service
