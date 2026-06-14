#!/bin/bash

# 1. Generate fresh certs (Tailscale usually needs sudo anyway)
sudo tailscale cert spaceberry.tail188bbf.ts.net

# 2. Overwrite the NPM files (REQUIRE SUDO)
# We use 'cp' to overwrite the content while keeping the file inode intact
sudo cp spaceberry.tail188bbf.ts.net.crt /home/adler/homelab/containers/nginx/data/custom_ssl/npm-9/fullchain.pem
sudo cp spaceberry.tail188bbf.ts.net.key /home/adler/homelab/containers/nginx/data/custom_ssl/npm-9/privkey.pem

# 3. Fix Permissions (REQUIRE SUDO)
# Ensure they remain readable by the container (root:root is fine for Docker mapping)
sudo chmod 644 /home/adler/homelab/containers/nginx/data/custom_ssl/npm-9/fullchain.pem
sudo chmod 644 /home/adler/homelab/containers/nginx/data/custom_ssl/npm-9/privkey.pem

# 4. Reload Nginx (REQUIRE SUDO usually)
sudo docker exec nginx-app-1 nginx -s reload

# 5. Cleanup (REQUIRE SUDO if created with sudo)
sudo rm spaceberry.tail188bbf.ts.net.crt spaceberry.tail188bbf.ts.net.key

# 6. Restart the application
docker restart nginx-app-1
