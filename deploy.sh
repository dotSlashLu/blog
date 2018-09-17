#!/bin/bash
rsync --exclude='.git/' -avz -e "ssh" --progress ./ lotuslab:/var/www/blog-src --delete-after
ssh lotuslab hugo --config="/var/www/blog-src/config.toml" -s /var/www/blog-src -d /var/www/blog
