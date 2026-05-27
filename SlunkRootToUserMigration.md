# Splunk: Migracija iz root v splunk uporabnika (Ubuntu)

> Runbook za pretvorbo obstoječe Splunk Enterprise namestitve, ki teče kot
> **root**, da teče kot **splunk** uporabnik. Vključuje tudi syslog (UDP/TCP +
> TLS), iptables 443->8443, logrotate, systemd ulimits in THP.
> Namestitev: `/opt/splunk` (standardna pot).

---

## 0. Pred začetkom / Pre-flight

```bash
# Preveri trenutno verzijo in stanje
sudo /opt/splunk/bin/splunk version
sudo /opt/splunk/bin/splunk status

# Backup konfiguracije (etc/) - VEDNO pred spremembami
sudo tar czf /root/splunk-etc-backup-$(date +%Y%m%d).tgz -C /opt/splunk etc

# splunk uporabnik in skupina ze obstajata (Splunk ju ustvari ob namestitvi)
id splunk
```

---

## 1. Sprememba lastništva (root -> splunk)

```bash
# Ustavi Splunk (trenutno tece kot root)
sudo /opt/splunk/bin/splunk stop

# Onemogoci obstojeci boot-start (bil nastavljen kot root)
sudo /opt/splunk/bin/splunk disable boot-start

# Spremeni lastnistvo CELOTNE namestitve na splunk uporabnika
# Pozor: na velikih namestitvah lahko traja dolgo (indexi, kvstore, podatki)
sudo chown -R splunk:splunk /opt/splunk

# Nastavi, da Splunk tece pod splunk uporabnikom
# Datoteka: /opt/splunk/etc/splunk-launch.conf
echo "SPLUNK_OS_USER = splunk" | sudo tee -a /opt/splunk/etc/splunk-launch.conf
```

---

## 2. systemd boot-start kot splunk uporabnik

```bash
# Ponovno omogoci boot-start, tokrat za splunk uporabnika, s polkit pravili
# (polkit dovoli splunk uporabniku start/stop/restart brez sudo)
sudo /opt/splunk/bin/splunk enable boot-start \
  -systemd-managed 1 \
  -user splunk -group splunk \
  -create-polkit-rules 1 \
  --accept-license --answer-yes --no-prompt

sudo systemctl daemon-reload
```

---

## 3. systemd ulimits (drop-in)

```bash
# POMEMBNO: systemd ignorira /etc/security/limits.d za servise.
# Limite je treba nastaviti v service unit-u preko drop-in datoteke.
sudo mkdir -p /etc/systemd/system/Splunkd.service.d

sudo tee /etc/systemd/system/Splunkd.service.d/limits.conf >/dev/null <<'EOF'
[Service]
LimitNOFILE=65536
LimitNPROC=16384
LimitFSIZE=infinity
LimitDATA=infinity
EOF

# Dodatno (login shell fallback) - /etc/security/limits.d
sudo tee /etc/security/limits.d/99-splunk.conf >/dev/null <<'EOF'
splunk soft nofile 65536
splunk hard nofile 65536
splunk soft nproc 16384
splunk hard nproc 16384
splunk soft fsize unlimited
splunk hard fsize unlimited
EOF

sudo systemctl daemon-reload
```

---

## 4. THP (Transparent Huge Pages) - onemogoci

```bash
# systemd servis, ki onemogoci THP pred zagonom Splunka
sudo tee /etc/systemd/system/disable-thp.service >/dev/null <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP) for Splunk
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=Splunkd.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable disable-thp.service
sudo systemctl start disable-thp.service

# Preveri
cat /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 5. Splunk uporabnik v adm skupino

```bash
# splunk mora biti v 'adm' skupini, da lahko bere:
#  - /syslog datoteke (rsyslog jih ustvari z grupo adm)
#  - /var/log standardne sistemske loge
sudo usermod -aG adm splunk
```

---

## 6. Syslog: priprava /syslog direktorija

```bash
# Direktorij kamor rsyslog pise prejete syslog podatke
sudo mkdir -p /syslog
sudo chown syslog:adm /syslog
sudo chmod 755 /syslog
```

---

## 7. Syslog: rsyslog konfiguracija (UDP + TCP 514)

```bash
# NE spreminjamo /etc/rsyslog.conf (Ubuntu default ostane nedotaknjen).
# Vse damo v en drop-in: 40-splunk.conf
sudo tee /etc/rsyslog.d/40-splunk.conf >/dev/null <<'EOF'
#### MODULES / LISTENERS ####
module(load="imudp")
input(type="imudp" port="514" ruleset="f_remote_all")

module(load="imtcp")
input(type="imtcp" port="514" ruleset="f_remote_all")

#### FILE PERMISSIONS ####
# Mora biti PRED ruleset omfile akcijo, da velja za ustvarjene datoteke.
# $PrivDropToGroup adm je daemon-wide in povozi Ubuntu default 'syslog',
# tako da so datoteke ustvarjene z grupo adm in jih splunk (v adm) bere.
$FileOwner syslog
$FileGroup adm
$FileCreateMode 0644
$DirCreateMode 0755
$Umask 0022
$PrivDropToUser syslog
$PrivDropToGroup adm

#### TEMPLATE ####
# Datoteke pristanejo v /syslog/<source-ip>/<facility>.log
template(name="d_catch_all" type="string" string="/syslog/%fromhost-ip%/%syslogfacility-text%.log")

#### RULESET ####
ruleset(name="f_remote_all" queue.type="LinkedList" queue.size="100000") {
    action(type="omfile"
           DynaFile="d_catch_all"
           DirCreateMode="0755"
           FileCreateMode="0644")
    stop
}
EOF
```

---

## 8. Syslog TLS (TCP 6514)

```bash
# gnutls driver za rsyslog
sudo apt update
sudo apt install -y rsyslog-gnutls

# Self-signed server certifikat (anon mode - sifriranje brez validacije)
sudo mkdir -p /etc/rsyslog.d/tls
sudo openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/rsyslog.d/tls/syslog-server-key.pem \
  -out /etc/rsyslog.d/tls/syslog-server-cert.pem \
  -days 3650 -subj "/CN=$(hostname -f)"
sudo chown syslog:adm /etc/rsyslog.d/tls/*
sudo chmod 640 /etc/rsyslog.d/tls/syslog-server-key.pem
sudo chmod 644 /etc/rsyslog.d/tls/syslog-server-cert.pem

# TLS listener na 6514 - uporablja isti f_remote_all ruleset
sudo tee /etc/rsyslog.d/45-splunk-tls.conf >/dev/null <<'EOF'
global(
    DefaultNetstreamDriver="gtls"
    DefaultNetstreamDriverCertFile="/etc/rsyslog.d/tls/syslog-server-cert.pem"
    DefaultNetstreamDriverKeyFile="/etc/rsyslog.d/tls/syslog-server-key.pem"
)

module(load="imtcp")
input(
    type="imtcp"
    port="6514"
    StreamDriver.Name="gtls"
    StreamDriver.Mode="1"
    StreamDriver.AuthMode="anon"
    ruleset="f_remote_all"
)
EOF
```

---

## 9. AppArmor: dovoli rsyslog pisanje v /syslog + branje certifikatov

```bash
# Ubuntu 24.04 AppArmor privzeto prepreci rsyslog pisanje izven standardnih poti.
# Lokalni override (profil ostane v veljavi, dodamo samo potrebne poti).
sudo tee /etc/apparmor.d/local/usr.sbin.rsyslogd >/dev/null <<'EOF'
# Dovoli rsyslog pisanje Splunk ingestion datotek pod /syslog
/syslog/** rw,
# Dovoli rsyslog branje TLS certifikatov
/etc/rsyslog.d/tls/* r,
EOF

# Ponovno nalozi profil
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd

# Ponovni zagon rsyslog
sudo systemctl restart rsyslog

# Preveri da poslusa na 514 (UDP/TCP) in 6514 (TLS)
sudo ss -tlnp | grep -E "514|6514"
```

---

## 10. Logrotate za /syslog

```bash
# Dnevna rotacija, 7 dni, kompresija, HUP rsyslog po rotaciji
sudo tee /etc/logrotate.d/splunk >/dev/null <<'EOF'
/syslog/*/*.log
{
    daily
    missingok
    dateext
    dateformat -%Y%m%d-%s
    rotate 7
    compress
    notifempty
    sharedscripts
    postrotate
          /usr/bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF
```

---

## 11. Splunk Web na 443 (iptables redirect)

```bash
# splunk uporabnik (non-root) ne sme bind-at na vrata < 1024.
# Resitev: Splunk Web poslusa na 8443 (SSL), iptables preusmeri 443 -> 8443.

# 11a. web.conf - vklopi SSL in nastavi port 8443
sudo -u splunk tee -a /opt/splunk/etc/system/local/web.conf >/dev/null <<'EOF'
[settings]
enableSplunkWebSSL = 1
httpport = 8443
EOF

# 11b. iptables-persistent (da pravila prezivijo reboot)
# Pri vprasanju "Save current rules?" odgovori Yes
sudo apt update
sudo apt install -y iptables-persistent

# 11c. Pravila za preusmeritev
# Promet iz omrezja: 443 -> 8443
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
# Lokalni promet (curl localhost): 443 -> 8443
sudo iptables -t nat -A OUTPUT -o lo -p tcp --dport 443 -j REDIRECT --to-port 8443

# 11d. Shrani pravila (prezivijo reboot)
sudo netfilter-persistent save

# Preveri
sudo iptables -t nat -L -n -v
```

---

## 12. Zagon in validacija

```bash
# Zazeni Splunk (zdaj kot splunk uporabnik preko systemd)
sudo systemctl start Splunkd
sudo systemctl status Splunkd --no-pager

# Preveri da splunkd tece kot splunk uporabnik (NE root)
ps -ef | grep splunkd | grep -v grep | head -3

# Preveri limite (mora biti 16384 / 65536)
cat /proc/$(pgrep -f "splunkd.*under-systemd" | head -1)/limits | grep -E "processes|open files"

# Preveri vrata
sudo ss -tlnp | grep -E "8000|8089|9997|8443|514|6514"

# splunk uporabnik lahko upravlja servis brez sudo (polkit)
sudo -u splunk /opt/splunk/bin/splunk status

# Web UI: https://<server-ip>/  (preusmeritev 443 -> 8443)
```

---

## 13. Diagnostika / pogoste tezave

```bash
# splunkd se vedno tece kot root?
#  -> preveri /opt/splunk/etc/splunk-launch.conf vsebuje SPLUNK_OS_USER = splunk
#  -> preveri lastnistvo: ls -la /opt/splunk | head

# Limite se vedno stare (15145 namesto 16384)?
#  -> systemctl restart Splunkd (proces obdrzi limite od zagona)
#  -> systemctl show Splunkd -p LimitNPROC -p LimitNOFILE

# rsyslog ne pise v /syslog?
#  -> AppArmor: sudo aa-status | grep rsyslog
#  -> preveri override: cat /etc/apparmor.d/local/usr.sbin.rsyslogd

# splunk ne more brati /syslog datotek?
#  -> preveri da je v adm skupini: id splunk
#  -> preveri lastnistvo datotek: ls -la /syslog/<ip>/

# 443 ne dela po rebootu?
#  -> iptables pravila niso shranjena: sudo netfilter-persistent save
#  -> preveri: cat /etc/iptables/rules.v4

# journalctl za podroben startup log
sudo journalctl -u Splunkd -n 100 --no-pager
```
