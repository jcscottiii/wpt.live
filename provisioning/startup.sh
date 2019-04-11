#!/bin/bash

mkdir /var/www-data
chown www-data:www-data /var/www-data

# The gcloud CLI which is included on the target machine image is out-of-date
# and does not properly integrate with Docker. Install the latest version.
# Source: https://cloud.google.com/sdk/docs/quickstart-debian-ubuntu

# Create environment variable for correct distribution
export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"

# Add the Cloud SDK distribution URI as a package source
echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | \
  tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# Import the Google Cloud Platform public key
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
  apt-key add -

# Update the package list and install the Cloud SDK
apt-get update
apt-get --yes install google-cloud-sdk docker.io

# Configure Docker to fetch images from gcloud's image repository
gcloud auth configure-docker

cat > /etc/systemd/system/web-platform-tests.service << HERE
[Unit]
Description=Web Platform Test Service
After=network.target auditd.service

[Service]
WorkingDirectory=/var/www-data
User=root
ExecStart=date > /now.txt
KillMode=control-group
Restart=on-failure

[Install]
WantedBy=multi-user.target
HERE

systemctl enable web-platform-tests.service
