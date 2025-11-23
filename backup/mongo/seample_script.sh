#!/bin/bash

backup_dir=$HOME/mongo_backup

filename="backup_$(date +%Y-%m-%d___%H-%M-%S)"

cd $backup_dir

mongodump --uri=mongodb://127.0.0.1:27017/test --gzip --archive=dumps/$filename.gz

find dumps -type f -mtime +15 -exec rm {} \;

