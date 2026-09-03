# Splunk Enterprise — migracija iz root v `splunk` uporabnika

Pretvorba obstoječe Splunk Enterprise namestitve, ki teče kot **root**, v
namestitev, ki teče kot namenski **`splunk`** uporabnik pod **systemd**.

Pokriva `$SPLUNK_HOME`, zunanje index volumne (`coldPath`, `coldToFrozenDir`),
rsyslog ingestion, privilegirana vrata, systemd unit, polkit, AppArmor/SELinux,
logrotate in THP.

Primarna platforma: **Ubuntu 22.04 / 24.04**. Razlike za **Rocky Linux / RHEL**
so v sekciji 14.

> **Najprej naredi na klonu.** Migracija je načeloma povratna, ampak načini
> odpovedi so tihi — podatki nehajo prihajati, servis pa se normalno zažene.
> Pred začetkom naredi VM snapshot.

> **Opomba o verziji.** Od Splunk 10.2 naprej CLI privzeto teče kot `splunk`
> uporabnik, razen če `SPLUNK_OS_USER` pove drugače. Tek kot root je
> deprecated in predviden za odstranitev.

---

## 0. Kaj dejansko blokira migracijo

Te stvari razčisti pred vzdrževalnim oknom. Vsaka od njih spremeni 30-minutno
opravilo v rollback.

| Blokada | Zakaj | Sekcija |
| --- | --- | --- |
| Splunk Web na 443 | non-root ne sme bind-at < 1024 | 6 |
| Syslog na 514 / 6514 | isto | 7, 8 |
| Zunanji cold/frozen volumni | root-owned, splunkd ne more pisati | 5 |
| Syslog datoteke root-owned | splunk ne more brati, ingestion tiho stoji | 7 |
| AppArmor profil (Ubuntu) | rsyslog ne sme pisati v `/syslog` | 7 |
| `splunk` je login račun s `sudo` | migracija ti prinese malo | 3 |
| Cron opravila, ki poganjajo splunk kot root | po migraciji spet ustvarijo root-owned datoteke | 13 |

---

## 1. Inventar pred migracijo

Vse zajemi najprej — kasneje primerjaš proti temu.

```bash
# Trenutno stanje
/opt/splunk/bin/splunk version
/opt/splunk/bin/splunk status
ps -ef | grep [s]plunkd | head -3

# Nacin boot-start
systemctl list-unit-files | grep -i splunk
ls -l /etc/init.d/splunk* 2>/dev/null
grep -vE '^\s*(#|$)' /opt/splunk/etc/splunk-launch.conf

# Kje podatki dejansko lezijo — NE predpostavljaj, da je vse pod /opt/splunk
/opt/splunk/bin/splunk btool indexes list --debug \
  | grep -E 'homePath|coldPath|thawedPath|coldToFrozenDir|coldToFrozenScript' \
  | sort -u > /root/index-paths-pre.txt

# Vrata v uporabi, vkljucno s privilegiranimi
ss -tlnp | grep -E '443|8000|8089|8191|9997|514|6514|8443' > /root/ports-pre.txt

# Baseline za kasnejso primerjavo
/opt/splunk/bin/splunk btool check 2>&1 > /root/btool-pre.txt
/opt/splunk/bin/splunk list index      > /root/indexes-pre.txt
ls /opt/splunk/etc/apps/               > /root/apps-pre.txt

# Backup konfiguracije
tar czf /root/splunk-etc-premigration-$(date +%F).tgz -C /opt/splunk etc
```

Preberi `/root/index-paths-pre.txt` pozorno. Vsaka pot izven `/opt/splunk`
potrebuje obravnavo iz sekcije 5.

---

## 2. Ustavi Splunk

```bash
/opt/splunk/bin/splunk stop
/opt/splunk/bin/splunk status
ps -ef | grep -E '[s]plunkd|[m]ongod'      # nic ne sme ostati

# Odstrani stari boot-start (init.d skripta ali systemd unit) — kaze na root
/opt/splunk/bin/splunk disable boot-start
```

---

## 3. `splunk` uporabnik

Če račun že obstaja, preveri, kaj dejansko je:

```bash
id splunk
```

**UID v obsegu 1000+ s `sudo`, `plugdev`, `lpadmin` itd. je interaktivni login
račun, ne servisni račun.** Če lahko `splunk` naredi `sudo` do root-a, si z
migracijo pridobil malo. Odstrani privilegirane skupine:

```bash
gpasswd -d splunk sudo
gpasswd -d splunk plugdev
gpasswd -d splunk lpadmin
gpasswd -d splunk cdrom
gpasswd -d splunk dip
usermod -s /usr/sbin/nologin splunk    # samo ce se nihce ne prijavlja kot splunk
```

Če računa ni:

```bash
useradd -r -m -d /opt/splunk -s /bin/bash splunk
```

V vsakem primeru mora biti `splunk` v skupini `adm`, da bere syslog datoteke
(sekcija 7) in standardne loge v `/var/log`:

```bash
usermod -aG adm splunk
id splunk
```

---

## 4. Lastništvo `$SPLUNK_HOME`

```bash
chown -R splunk:splunk /opt/splunk
find /opt/splunk ! -user splunk | head          # pricakovano prazno
```

Na velikih namestitvah traja dolgo (indexi, kvstore, podatki).

To zahteva tudi preinstall 10.x paketa — ta spusti privilegije na `splunk` in
prekine prechecke, če ne more brati drevesa. Če `dpkg -i` javi napako na
root-owned datotekah, je to razlog.

---

## 5. Zunanji index volumni

Za vsako pot iz `/root/index-paths-pre.txt`, ki je izven `/opt/splunk` —
običajno `/colddb`, `/frozenpath`, `/thaweddb` ali priklopljen arhivni volumen:

```bash
chown -R splunk:splunk /colddb /frozenpath
chmod 750 /colddb /frozenpath        # SAMO vrhnji nivo
```

**Ne uporabljaj `chmod -R`.** Splunk sam ustvarja bucket direktorije `700` in
datoteke `600`. Rekurzivna sprememba pravic ali po nepotrebnem odpre vsak
bucket ali pa premelje deset tisoče inode-ov brez učinka. Lastništvo popravi
rekurzivno, pravice samo na vrhnjem direktoriju.

Kaj splunkd potrebuje:

- **coldPath** — branje, pisanje, traverse. Warm buckete premika noter in jih
  ob retention briše, torej rabi write na *direktoriju*, ne samo na bucketih.
- **coldToFrozenDir** — pisanje in traverse.
- **coldToFrozenScript** — skripta teče *kot splunk uporabnik*. Rabi `+x` za
  splunk, in karkoli piše, mora biti splunk-writable.

Traverse pravica je potrebna na vsaki nadrejeni komponenti, ne samo na listu:

```bash
namei -l /colddb /frozenpath
```

Preveri, ne predpostavljaj:

```bash
sudo -u splunk touch /colddb/.wtest && sudo -u splunk rm /colddb/.wtest && echo cold-ok
sudo -u splunk touch /frozenpath/.wtest && sudo -u splunk rm /frozenpath/.wtest && echo frozen-ok
```

### Ločeni filesystemi in mrežna hramba

- **Mount pointi:** `chown` na mount pointu spremeni priklopljen filesystem. Če
  se kdaj ne priklopi, splunkd piše v spodaj ležeči direktorij in tiho napolni
  `/`. Pred zagonom Splunka potrdi, da je mount prisoten.
- **NFS/CIFS:** lastništvo določajo mount opcije (`uid=`/`gid=`), ne `chown`, in
  root-squash te bo ugriznil. Frozen na NFS je izvedljiv, cold na NFS je
  iskanje težav.

---

## 6. `splunk-launch.conf` in privilegirana vrata

```bash
# SPREMENI obstojeco vrstico — ne dodajaj druge
sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=splunk/' /opt/splunk/etc/splunk-launch.conf

# Ce vrstice sploh ni:
grep -q '^SPLUNK_OS_USER' /opt/splunk/etc/splunk-launch.conf \
  || echo "SPLUNK_OS_USER=splunk" >> /opt/splunk/etc/splunk-launch.conf

grep -vE '^\s*(#|$)' /opt/splunk/etc/splunk-launch.conf
```

### Splunk Web na 443

Non-root proces ne more bind-ati vrat pod 1024. Izberi eno:

**a) Web na visoka vrata + redirect (priporočeno).**

```bash
# web.conf
sudo -u splunk tee -a /opt/splunk/etc/system/local/web.conf >/dev/null <<'EOF'
[settings]
enableSplunkWebSSL = 1
httpport = 8443
EOF
```

```bash
# iptables-persistent, da pravila prezivijo reboot
# Pri vprasanju "Save current rules?" odgovori Yes
apt update
apt install -y iptables-persistent

# Promet iz omrezja: 443 -> 8443
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
# Lokalni promet (curl localhost): 443 -> 8443
iptables -t nat -A OUTPUT -o lo -p tcp --dport 443 -j REDIRECT --to-port 8443

# BREZ tega pravilo ob rebootu izgine
netfilter-persistent save

iptables -t nat -L -n -v
```

**b) Podeli capability namesto redirecta** — dodaj v systemd drop-in iz
sekcije 10:

```
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

Enostavneje, ampak velja za celotno procesno drevo — širša podelitev kot
redirect.

**c) Reverse proxy** (nginx/haproxy) terminira 443 in posreduje na 8000.

### Syslog na 514 / 6514

Ne poskušaj, da bi splunkd bind-al ta vrata. Naj privilegirana vrata drži
rsyslog, Splunk pa bere datoteke — sekcija 7.

---

## 7. Syslog ingestion (Ubuntu)

rsyslog teče naprej, bind-a 514 in spusti privilegije na `syslog:adm`, piše
datoteke, ki jih `splunk` bere preko monitor inputa. Splunk stran ne rabi
nobenega privilegija.

### 7.1 Direktorij `/syslog`

**Nova namestitev:**

```bash
mkdir -p /syslog
chown syslog:adm /syslog
chmod 750 /syslog
```

**Obstoječ `/syslog`:** popravi samo lastništvo in pravice. **Vsebine ne
briši** — obstoječi podatki ostanejo nedotaknjeni.

```bash
# Najprej poglej stanje
ls -la /syslog/
ls -la /syslog/*/ 2>/dev/null | head

# Pricakovano:
#   /syslog        -> syslog:adm  drwxr-x---  (0750)
#   /syslog/<ip>/  -> syslog:adm  drwxr-x---  (0750)
#   *.log          -> syslog:adm  -rw-r-----  (0640)
```

### 7.2 rsyslog konfiguracija (UDP + TCP 514)

`/etc/rsyslog.conf` ne spreminjamo — Ubuntu default ostane nedotaknjen. Vse
gre v en drop-in.

```bash
tee /etc/rsyslog.d/40-splunk.conf >/dev/null <<'EOF'
#### MODULI / LISTENERJI ####
module(load="imudp")
input(type="imudp" port="514" ruleset="f_remote_all")

module(load="imtcp")
input(type="imtcp" port="514" ruleset="f_remote_all")

#### LASTNISTVO IN PRAVICE ####
# Mora biti PRED ruleset omfile akcijo.
# $PrivDropToGroup adm je daemon-wide in povozi Ubuntu default 'syslog',
# tako da so datoteke ustvarjene z grupo adm in jih splunk (v adm) bere.
$FileOwner syslog
$FileGroup adm
$FileCreateMode 0640
$DirCreateMode 0750
$Umask 0027
$PrivDropToUser syslog
$PrivDropToGroup adm

#### TEMPLATE ####
# /syslog/<source-ip>/<facility>.log
template(name="d_catch_all" type="string"
         string="/syslog/%fromhost-ip%/%syslogfacility-text%.log")

#### RULESET ####
ruleset(name="f_remote_all" queue.type="LinkedList" queue.size="100000") {

    # per-source filtri gredo sem, vsak konca s `stop`

    action(type="omfile"
           DynaFile="d_catch_all"
           DirCreateMode="0750"
           FileCreateMode="0640")
    stop
}
EOF
```

**O pravicah.** `0755`/`0644` deluje, ker naredi datoteke world-readable —
ampak potem vsak lokalni račun na zbiralniku bere telemetrijo strank: firewall
seje, auth dogodke, interna imena gostiteljev in oznake podomrežij. Ker je
`splunk` v `adm`, mu `0750`/`0640` da točno toliko dostopa, kot ga rabi, in
nikomur drugemu nič.

`$PrivDropToGroup adm` in ožje pravice **gresta v paru**. Če postaviš 0640 brez
te direktive, bodo datoteke `syslog:syslog` in Splunk jih ne bo mogel brati —
tiho, brez napake.

### 7.3 Zaostritev obstoječe namestitve

`FileCreateMode` velja samo ob nastanku. Obstoječe datoteke obdržijo stare
pravice:

```bash
find /syslog -type d -exec chmod 750 {} +
find /syslog -type f -exec chmod 640 {} +
```

**Ne uporabljaj `chmod -R 0640 /syslog`** — to bi odvzelo execute bit
direktorijem in jih naredilo nedostopne (`cd`, `ls` vrneta "Permission
denied"). Če že rekurzivno, potem s simbolnim zapisom in velikim `X`, ki loči
med datotekami in direktoriji:

```bash
chmod -R u=rwX,g=rX,o= /syslog
```

### 7.4 Ownership sweep

Karkoli je rsyslog napisal, ko je bil sistem drugače nastavljen, je lahko še
vedno `root:root` in za Splunk neberljivo. To odpove **tiho** — dobiš luknjo v
starejših podatkih, ne napake:

```bash
find /syslog \( ! -user syslog -o ! -group adm \) -ls | head -20
chown -R syslog:adm /syslog
```

### 7.5 AppArmor (Ubuntu 22.04 / 24.04)

Ubuntu privzeto prepreči rsyslogu pisanje izven standardnih poti. Lokalni
override — profil ostane v veljavi, dodamo samo potrebne poti:

```bash
tee /etc/apparmor.d/local/usr.sbin.rsyslogd >/dev/null <<'EOF'
# Dovoli rsyslog pisanje Splunk ingestion datotek pod /syslog
/syslog/** rw,
# Dovoli rsyslog branje TLS certifikatov (sekcija 8)
/etc/rsyslog.d/tls/* r,
EOF

apparmor_parser -r /etc/apparmor.d/usr.sbin.rsyslogd
```

### 7.6 Restart in preverjanje

```bash
systemctl restart rsyslog
systemctl status rsyslog --no-pager

# Mora poslusati na 514 UDP/TCP (in 6514, ce si naredil sekcijo 8)
ss -tlnp | grep -E '514|6514'
ss -ulnp | grep 514

# Preveri kot splunk uporabnik — to je edini test, ki steje
sudo -u splunk ls /syslog/*/ | head
sudo -u splunk head -1 /syslog/<neki-ip>/<facility>.log
```

---

## 8. Syslog TLS na 6514 (opcijsko)

Potrebno samo, kjer stranka pošilja syslog preko nezaupanega omrežja ali kjer
to zahteva pogodba. Če ne rabiš, preskoči — imaš en certifikat manj za
obnavljati.

```bash
# gnutls driver za rsyslog
apt update
apt install -y rsyslog-gnutls

# Self-signed server certifikat (anon mode — sifriranje brez validacije odjemalca)
mkdir -p /etc/rsyslog.d/tls
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/rsyslog.d/tls/syslog-server-key.pem \
  -out /etc/rsyslog.d/tls/syslog-server-cert.pem \
  -days 3650 -subj "/CN=$(hostname -f)"
chown syslog:adm /etc/rsyslog.d/tls/*
chmod 640 /etc/rsyslog.d/tls/syslog-server-key.pem
chmod 644 /etc/rsyslog.d/tls/syslog-server-cert.pem
```

```bash
# TLS listener na 6514 — uporablja isti f_remote_all ruleset
tee /etc/rsyslog.d/45-splunk-tls.conf >/dev/null <<'EOF'
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

systemctl restart rsyslog
ss -tlnp | grep 6514
```

`anon` pomeni šifriranje brez preverjanja odjemalca. Če rabiš tudi
avtentikacijo pošiljateljev, je to `StreamDriver.AuthMode="x509/name"` in
`PermittedPeer` — druga zgodba, ki zahteva CA.

Datum poteka si zapiši. Certifikat velja 10 let in nihče se ga ne bo spomnil.

---

## 9. Logrotate

```bash
tee /etc/logrotate.d/splunk >/dev/null <<'EOF'
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

Ker stanza nima eksplicitne `create` direktive, rotirane datoteke podedujejo
lastništvo in pravice od originala. To preveri po prvi rotaciji, ne
predpostavljaj:

```bash
logrotate -d /etc/logrotate.d/splunk     # dry-run
ls -la /syslog/*/*.gz | head -3
```

Če se pokaže, da rotirane datoteke ne podedujejo pravilno, dodaj v stanzo:

```
create 0640 syslog adm
```

---

## 10. systemd, polkit, limits, THP

### boot-start

```bash
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 \
  -user splunk -group splunk -create-polkit-rules 1 \
  --accept-license --answer-yes --no-prompt

systemctl daemon-reload
```

Ime unita sledi `SPLUNK_SERVER_NAME` v `splunk-launch.conf` — pri
`SPLUNK_SERVER_NAME=Splunkd` dobiš `Splunkd.service`.

### Limits drop-in

Limite daj v drop-in, nikoli v sam unit — `enable boot-start` unit regenerira
in ročne popravke povozi.

```bash
mkdir -p /etc/systemd/system/Splunkd.service.d
tee /etc/systemd/system/Splunkd.service.d/limits.conf >/dev/null <<'EOF'
[Service]
LimitNOFILE=65536
LimitNPROC=16384
LimitFSIZE=infinity
LimitDATA=infinity
TasksMax=infinity
EOF

systemctl daemon-reload
```

Dodatno, kot fallback za login shell (systemd za servise ignorira
`/etc/security/limits.d`, ampak `sudo -u splunk ... splunk` iz shella ga
upošteva):

```bash
tee /etc/security/limits.d/99-splunk.conf >/dev/null <<'EOF'
splunk soft nofile 65536
splunk hard nofile 65536
splunk soft nproc 16384
splunk hard nproc 16384
splunk soft fsize unlimited
splunk hard fsize unlimited
EOF
```

Tek kot root je maskiral težave z limiti. Kot navaden uporabnik se pokažejo
takoj, običajno kot padci iskanj pod obremenitvijo.

### polkit

`-create-polkit-rules 1` napiše `/etc/polkit-1/rules.d/10-Splunkd.rules`, kar
`splunk` uporabniku omogoči upravljanje servisa brez sudo:

```bash
cat /etc/polkit-1/rules.d/*Splunkd*
```

Mora biti `.rules` (JavaScript) datoteka — Ubuntu 24.04 ima polkit 124, ki je
podporo za `.pkla` popolnoma opustil. Generirano pravilo podeli samo `start`,
`stop` in `restart`, ne pa `reload`, `enable` ali `disable`.

Če ga pišeš ročno:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "Splunkd.service" &&
        subject.user == "splunk") {
        var verb = action.lookup("verb");
        if (verb == "start" || verb == "stop" || verb == "restart")
            return polkit.Result.YES;
    }
});
```

### THP (Transparent Huge Pages)

```bash
tee /etc/systemd/system/disable-thp.service >/dev/null <<'EOF'
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

systemctl daemon-reload
systemctl enable --now disable-thp.service

cat /sys/kernel/mm/transparent_hugepage/enabled     # [never]
```

---

## 11. Zagon in validacija

```bash
systemctl start Splunkd
systemctl status Splunkd --no-pager

# Tece kot splunk, ne root
ps -ef | grep [s]plunkd | head -3
ps -ef | grep [m]ongod | head -1

# Limiti so prijeli
cat /proc/$(pgrep -f "splunkd.*under-systemd" | head -1)/limits \
  | grep -E 'processes|open files'

# Vrata — primerjaj z baseline
diff /root/ports-pre.txt <(ss -tlnp | grep -E '443|8000|8089|8191|9997|514|6514|8443')

# Konfiguracija nedotaknjena
sudo -u splunk /opt/splunk/bin/splunk btool check 2>&1 | diff /root/btool-pre.txt -
sudo -u splunk /opt/splunk/bin/splunk list index | diff /root/indexes-pre.txt -

# splunk lahko upravlja servis brez sudo
su - splunk -c 'systemctl restart Splunkd'
sudo -u splunk /opt/splunk/bin/splunk status
```

V Splunk Web:

- Prijava deluje, vključno s SAML/SSO, če je konfiguriran
- `index=_internal earliest=-5m` vrne dogodke
- Iskanje po pravem client indexu vrne svež podatek
- Forwarder Management se naloži, klienti se javljajo
- DB Connect health dashboard, oba JVM-ja gor (`ps -ef | grep [j]ava`)
- Modularni inputi tečejo (`ps -ef | grep [p]ython3`)

Nato potrdi, da cold/frozen dejansko delujeta — ta odpoved se pokaže šele čez
dneve, zato jo izsili, če lahko:

```bash
sudo -u splunk /opt/splunk/bin/splunk btool indexes list --debug \
  | grep -E 'coldPath|coldToFrozenDir' | sort -u
find /colddb -newermt '-1 hour' | head
```

---

## 12. Reboot test

Ni opcijski. Vse iz sekcij 6, 7, 8 in 10 ima past s persistenco.

```bash
reboot
```

Po vrnitvi:

```bash
systemctl is-active Splunkd
ps -ef | grep [s]plunkd | head -3
ss -tlnp | grep -E '443|8000|8089|9997|514|6514|8443'
iptables -t nat -L -n -v | grep 8443       # redirect prezivel
mount | grep -E 'colddb|frozen'            # volumni priklopljeni pred splunkd
sudo -u splunk head -1 /syslog/*/*.log 2>/dev/null | head -3
aa-status | grep rsyslog                   # AppArmor profil nalozen
```

Če je redirect izginil: `netfilter-persistent save` ni bil nikoli izveden.

---

## 13. Hardening in odprti konci

**Prepreči, da bi se splunk uporabnik povzpel nazaj v root.** Če lahko ureja
`splunk-launch.conf`, lahko nastavi `SPLUNK_OS_USER=root` — to je Splunk
advisory SPL-CAAAP3M:

```bash
chown root:splunk /opt/splunk/etc/splunk-launch.conf
chmod 640 /opt/splunk/etc/splunk-launch.conf
```

Najbolj pomembno tam, kjer je `splunk` pravi login račun in ne `useradd -r`
servisni račun.

**Poišči vse, kar še vedno poganja Splunk kot root:**

```bash
crontab -l | grep -i splunk
ls -la /etc/cron.d/ | grep -i splunk
grep -rl '/opt/splunk/bin/splunk' /etc/cron* /usr/local/bin 2>/dev/null
```

Backup skripte in diag cron opravila so običajni krivci. Vsak od njih rabi
`sudo -u splunk` pred binarko, sicer znotraj splunk-owned drevesa spet ustvari
root-owned datoteke in si nazaj pri `Permission denied` na pidfile.

**Stalno pravilo:** postopek izvajaš kot root, ampak vsak klic
`$SPLUNK_HOME/bin/splunk` gre skozi `sudo -u splunk`.

**Drift check** — poženi teden dni kasneje:

```bash
find /opt/splunk ! -user splunk | head
find /syslog ! -user syslog | head
```

Karkoli se pojavi, identificira proces, ki še vedno teče kot root.

---

## 14. Rocky Linux / RHEL — razlike

Postopek je enak, spremenijo se štiri stvari.

**SELinux namesto AppArmorja.** Nestandarden syslog direktorij rabi label,
sicer rsyslog vanj tiho ne more pisati:

```bash
semanage fcontext -a -t var_log_t "/syslog(/.*)?"
restorecon -Rv /syslog
ausearch -m avc -ts recent        # ko nekaj tiho ne dela
```

**Ni skupine `adm`.** RHEL nima `adm` skupine v istem pomenu. Naredi namensko
skupino:

```bash
groupadd -r syslogread
usermod -aG syslogread splunk
```

in v `40-splunk.conf` uporabi `$FileGroup syslogread` namesto `adm`.
Alternativa je ACL:

```bash
setfacl -R -m u:splunk:rX /syslog
setfacl -R -d -m u:splunk:rX /syslog     # default ACL za nove datoteke
```

**rsyslog privzeto teče kot root** in ne spusti privilegijev. `$FileOwner` /
`$FileGroup` zato eksplicitno nastavi, sicer dobiš `root:root` datoteke, ki jih
splunk ne bere.

**firewalld/nftables namesto `iptables-persistent`.** Za 443 → 8443:

```bash
firewall-cmd --permanent --add-forward-port=port=443:proto=tcp:toport=8443
firewall-cmd --permanent --add-port=8443/tcp
firewall-cmd --reload
firewall-cmd --list-all
```

Za lokalni promet (`curl https://localhost`) firewalld forward-port ne velja —
če to rabiš, dodaj še nft pravilo v `output` chain ali testiraj direktno na
8443.

---

## 15. Diagnostika / pogoste težave

```bash
# splunkd se vedno tece kot root?
#  -> preveri /opt/splunk/etc/splunk-launch.conf: SPLUNK_OS_USER=splunk
#  -> preveri, da ni podvojene vrstice (zadnja zmaga)
#  -> preveri lastnistvo: ls -la /opt/splunk | head

# Limiti se vedno stari (npr. 15145 namesto 16384)?
#  -> systemctl restart Splunkd (proces obdrzi limite od zagona)
#  -> systemctl show Splunkd -p LimitNPROC -p LimitNOFILE

# rsyslog ne posodablja datotek v /syslog?
#  -> ali sploh poslusa: ss -ulnp | grep 514
#  -> AppArmor: aa-status | grep rsyslog
#  -> override: cat /etc/apparmor.d/local/usr.sbin.rsyslogd
#  -> SELinux (Rocky): ausearch -m avc -ts recent

# splunk ne more brati /syslog datotek?
#  -> id splunk               (mora biti v adm)
#  -> ls -la /syslog/<ip>/    (mora biti syslog:adm, 0640)
#  -> manjka $PrivDropToGroup adm v 40-splunk.conf?
#  -> test: sudo -u splunk head -1 /syslog/<ip>/<facility>.log

# 443 ne dela po rebootu?
#  -> pravila niso shranjena: netfilter-persistent save
#  -> preveri: cat /etc/iptables/rules.v4

# Podatki manjkajo samo za starejse datoteke?
#  -> ownership sweep ni bil izveden: find /syslog ! -user syslog | head

# Podroben startup log
journalctl -u Splunkd -n 100 --no-pager
```

---

## 16. Rollback

Povrni VM snapshot. To je čista pot.

Ročno, če je treba:

```bash
systemctl stop Splunkd
/opt/splunk/bin/splunk disable boot-start
sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=root/' /opt/splunk/etc/splunk-launch.conf
chown -R root:root /opt/splunk
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 \
  --accept-license --answer-yes --no-prompt
systemctl daemon-reload
systemctl start Splunkd
```

Povrni tudi `web.conf` `httpport` in odstrani iptables redirect, če si ju
spreminjal.

Lastništvo na `/colddb`, `/frozenpath` in `/syslog` lahko ostane `splunk` —
root jih bere v vsakem primeru.

---

## Checklist

- [ ] VM snapshot, `etc` tarball, KV store backup
- [ ] Index poti popisane (`btool indexes list --debug`)
- [ ] `splunk` račun ni `sudo`-sposoben login uporabnik
- [ ] `splunk` v `adm` (oz. `syslogread` na RHEL)
- [ ] `chown -R splunk:splunk /opt/splunk`
- [ ] `chown -R splunk:splunk` na vsaki zunanji cold/frozen/thawed poti
- [ ] Write test kot splunk na vsaki zunanji poti
- [ ] `SPLUNK_OS_USER=splunk` (spremenjen, ne dodan)
- [ ] Splunk Web z 443 (redirect persistiran ali capability podeljena)
- [ ] `iptables-persistent` nameščen, `netfilter-persistent save` izveden
- [ ] rsyslog listenerji (`imudp` + `imtcp` 514) prisotni
- [ ] `$PrivDropToGroup adm` + `DirCreateMode 0750` / `FileCreateMode 0640`
- [ ] Obstoječe datoteke zaostrene in ownership sweep izveden
- [ ] AppArmor override (Ubuntu) ali SELinux fcontext (RHEL)
- [ ] `systemctl restart rsyslog` + `ss -tlnp | grep 514`
- [ ] `splunk` bere `/syslog` (testirano, ne predpostavljeno)
- [ ] TLS 6514, če je potreben — certifikat in datum poteka zabeležen
- [ ] Logrotate stanza nameščena, rotacija preverjena
- [ ] `enable boot-start -systemd-managed 1 -user splunk -create-polkit-rules 1`
- [ ] Limits drop-in v `.d/`, preverjen v `/proc/<pid>/limits`
- [ ] `limits.d/99-splunk.conf` fallback
- [ ] THP onemogočen (`disable-thp.service`)
- [ ] splunkd teče kot `splunk`
- [ ] `splunk-launch.conf` lastnik `root:splunk`, mode 640
- [ ] Cron/skripte posodobljene na `sudo -u splunk`
- [ ] Reboot test opravljen, vključno z iptables redirectom in mounti
