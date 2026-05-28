### bootstrap-README is the main setup script


---
---
## old manual setup /use at own risk..
### 1. prereqs
sudo apt install -y ansible vim unzip
### 2. download the 10.2.1 deb 
cd ~ && wget -O splunk-10.2.1-c892b66d163d-linux-amd64.deb \
  "https://download.splunk.com/products/splunk/releases/10.2.1/linux/splunk-10.2.1-c892b66d163d-linux-amd64.deb"
### 3. Download unzip role, move deb into files
unzip splunk-standalone-ansible.zip

mv splunk-10.2.1-c892b66d163d-linux-amd64.deb splunk-standalone/roles/splunk_standalone/files/
### 4. set admin password / IP in group_vars
vim splunk-standalone/group_vars/splunk_standalone.yml

splunk_indexer_ip:

splunk_ssl_password:

### 5. run (as root)
sudo su -
cd /home/<user>/splunk-standalone

ansible-playbook site.yml
