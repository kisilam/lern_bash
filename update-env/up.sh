#!/bin/bash
dtr=$(date "+%d.%m.%Y %H:%m"); sed -i~ "/^VUE_APP_BUILD_TIME=/s/=.*/=$dtr/" .env.development
