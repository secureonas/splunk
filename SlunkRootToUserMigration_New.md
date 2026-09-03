# Splunk Enterprise — Migrating from root to the `splunk` user

Converting a standalone Splunk Enterprise instance that runs as **root** into
one that runs as a dedicated **`splunk`** user under **systemd**, on Ubuntu.

Covers `$SPLUNK_HOME`, external index volumes (`coldPath`, `coldToFrozenDir`),
rsyslog ingestion directories, privileged ports, systemd unit and polkit rules.

> **Do this on a clone first.** The migration is reversible in principle but
> the failure modes are quiet — data that stops arriving rather than a service
> that fails to start. Take a VM snapshot before you begin.

> **Version note.** From Splunk 10.2, the CLI defaults to the `splunk` user
> unless `SPLUNK_OS_USER` says otherwise, and running as root is deprecated
> and slated for removal. This migration is where you want to end up anyway.

---

## 0. What actually blocks this

Work these out before the window. Each one turns a 30-minute job into a
rollback.

| Blocker | Why | Section |
|---|---|---|
| Splunk Web on 443 | non-root cannot bind < 1024 | 6 |
| Syslog input on 514 / 6514 | same | 6, 7 |
| External cold/frozen volumes | root-owned, splunkd can't write | 5 |
| Syslog files root-owned | splunk can't read, ingestion stops silently | 7 |
| `splunk` is a login account | migration gains you little if it has `sudo` | 3 |
| Cron jobs running `splunk` as root | recreate root-owned files after migration | 11 |

---

## 1. Pre-migration inventory

Capture everything first — you compare against this afterwards.

```bash
# Current state
/opt/splunk/bin/splunk version
/opt/splunk/bin/splunk status
ps -ef | grep [s]plunkd | head -3

# Boot-start method
systemctl list-unit-files | grep -i splunk
ls -l /etc/init.d/splunk* 2>/dev/null
grep -vE '^\s*(#|$)' /opt/splunk/etc/splunk-launch.conf

# Where the data actually lives — do NOT assume it is all under /opt/splunk
/opt/splunk/bin/splunk btool indexes list --debug \
  | grep -E 'homePath|coldPath|thawedPath|coldToFrozenDir|coldToFrozenScript' \
  | sort -u > /root/index-paths-pre.txt

# Ports in use, including privileged ones
ss -tlnp | grep -E '443|8000|8089|8191|9997|514|6514|8443' > /root/ports-pre.txt

# Baselines for later comparison
/opt/splunk/bin/splunk btool check 2>&1 > /root/btool-pre.txt
/opt/splunk/bin/splunk list index      > /root/indexes-pre.txt
ls /opt/splunk/etc/apps/               > /root/apps-pre.txt

# Config backup
tar czf /root/splunk-etc-premigration-$(date +%F).tgz -C /opt/splunk etc
```

Read `/root/index-paths-pre.txt` carefully. Every distinct path outside
`/opt/splunk` needs the treatment in section 5.

---

## 2. Stop Splunk

```bash
/opt/splunk/bin/splunk stop
/opt/splunk/bin/splunk status
ps -ef | grep -E '[s]plunkd|[m]ongod'      # nothing should remain

# Remove the old boot-start (init.d script or systemd unit) — it points at root
/opt/splunk/bin/splunk disable boot-start
```

---

## 3. The `splunk` user

If the account already exists, check what it actually is:

```bash
id splunk
```

**A UID in the 1000+ range with `sudo`, `plugdev`, `lpadmin` etc. is an
interactive login account, not a service account.** Running splunkd as an
account that can `sudo` to root defeats most of the point of this migration.
Either strip the privileged groups:

```bash
gpasswd -d splunk sudo
gpasswd -d splunk plugdev
gpasswd -d splunk lpadmin
gpasswd -d splunk cdrom
gpasswd -d splunk dip
usermod -s /usr/sbin/nologin splunk       # only if nothing needs to log in as splunk
```

or create a proper service account and reassign ownership to it.

If it does not exist:

```bash
useradd -r -m -d /opt/splunk -s /bin/bash splunk
```

Either way, `splunk` needs to be in `adm` to read syslog files (section 7):

```bash
usermod -aG adm splunk
id splunk
```

---

## 4. `$SPLUNK_HOME` ownership

```bash
chown -R splunk:splunk /opt/splunk
find /opt/splunk ! -user splunk | head          # expect empty
```

This is also what the 10.x package preinstall requires — it drops privileges
to `splunk` and aborts its prechecks if it cannot read the tree.

---

## 5. External index volumes

For every path from `/root/index-paths-pre.txt` that sits outside
`/opt/splunk` — typically `/colddb`, `/frozenpath`, `/thaweddb`, or a mounted
archive volume:

```bash
chown -R splunk:splunk /colddb /frozenpath
chmod 750 /colddb /frozenpath        # top level ONLY
```

**Do not `chmod -R`.** Splunk creates bucket directories `700` and files `600`
itself. Recursive mode changes either loosen every bucket for no benefit or
churn tens of thousands of inodes to no effect. Fix ownership recursively; set
the mode on the top-level directory only.

What splunkd needs:

- **coldPath** — read, write and traverse. It moves warm buckets in and deletes
  them at retention, so it needs write on the *directory*, not just the buckets.
- **coldToFrozenDir** — write and traverse.
- **coldToFrozenScript** — the script runs *as the splunk user*. It needs `+x`
  for splunk, and anything it writes to must be splunk-writable.

Traverse permission is needed on every parent component, not just the leaf:

```bash
namei -l /colddb /frozenpath
```

Verify rather than assume:

```bash
sudo -u splunk touch /colddb/.wtest && sudo -u splunk rm /colddb/.wtest && echo cold-ok
sudo -u splunk touch /frozenpath/.wtest && sudo -u splunk rm /frozenpath/.wtest && echo frozen-ok
```

### Separate filesystems and network storage

- **Mount points:** `chown` on a mount point affects the mounted filesystem. If
  it ever fails to mount, splunkd writes to the underlying directory and
  silently fills `/`. Confirm the mount is present before starting Splunk.
- **NFS/CIFS:** ownership comes from mount options (`uid=`/`gid=`), not
  `chown`, and root-squash will bite. Frozen on NFS is workable; cold on NFS is
  asking for trouble.

---

## 6. `splunk-launch.conf` and privileged ports

```bash
# CHANGE the existing line — do not append a second one
sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=splunk/' /opt/splunk/etc/splunk-launch.conf
grep -vE '^\s*(#|$)' /opt/splunk/etc/splunk-launch.conf
```

### Splunk Web on 443

A non-root process cannot bind ports below 1024. Pick one:

**a) Move Web to a high port and redirect (recommended).**

```bash
# web.conf
[settings]
httpport = 8443
enableSplunkWebSSL = true
```

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
iptables -t nat -A OUTPUT -o lo -p tcp --dport 443 -j REDIRECT --to-port 8443
netfilter-persistent save        # WITHOUT this the rule vanishes at reboot
```

**b) Grant the capability instead** — add to the systemd drop-in in section 8:

```
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

Simpler, but it applies to the whole process tree, which is a broader grant
than the redirect.

**c) Reverse proxy** (nginx/haproxy) terminating 443 and forwarding to 8000.

### Syslog on 514 / 6514

Don't try to make splunkd bind these. Let rsyslog own the privileged port and
have Splunk read files — section 7.

---

## 7. Syslog ingestion

rsyslog keeps running as root (or drops to `syslog:adm`), binds 514, and writes
files that the `splunk` user reads via a monitor input. Nothing about the
Splunk side needs privilege.

### rsyslog config

`/etc/rsyslog.d/40-splunk.conf` — the `DirCreateMode` / `FileCreateMode`
settings are what make the output readable by Splunk:

```rsyslog
## Templates
template (name="d_catch_all" type="string"
          string="/syslog/%FROMHOST-IP%/%syslogfacility-text%.log")

## Rulesets
ruleset(name="f_remote_all" queue.type="LinkedList" queue.size="100000") {

    # per-source filters go here, each ending in `stop`

    # Catch all
    action(type="omfile" DynaFile="d_catch_all"
           DirCreateMode="0750" FileCreateMode="0640")
    stop
}
```

**On the mode.** `0755`/`0644` works because it makes the files world-readable,
but then every local account on the collector can read client telemetry —
firewall sessions, auth events, internal hostnames and subnet labels. Since
`splunk` is in `adm`, `0750`/`0640` gives Splunk exactly the access it needs
and nothing to anyone else. Use the tighter modes on new builds.

If you tighten an existing deployment, existing files keep their old mode —
`FileCreateMode` only applies at creation:

```bash
find /syslog -type d -exec chmod 750 {} +
find /syslog -type f -exec chmod 640 {} +
```

### Ownership sweep

Anything rsyslog wrote while the box was configured differently may still be
`root:root` and unreadable to Splunk. This fails **silently** — you get a gap
in older data, not an error:

```bash
find /syslog \( ! -user syslog -o ! -group adm \) -ls | head -20
chown -R syslog:adm /syslog
```

### Verify as the splunk user

```bash
sudo -u splunk ls /syslog/*/ | head
sudo -u splunk head -1 /syslog/<some-ip>/<facility>.log
ls -la /syslog/*/*.gz | head -3      # rotated files inherit correctly
```

### logrotate

If the stanza has no explicit `create` directive, rotated files inherit from
the original. Confirm after the next rotation rather than assuming.

---

## 8. systemd, polkit and limits

```bash
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 \
  -user splunk -group splunk -create-polkit-rules 1 \
  --accept-license --answer-yes --no-prompt
```

The unit name follows `SPLUNK_SERVER_NAME` in `splunk-launch.conf` — with
`SPLUNK_SERVER_NAME=Splunkd` you get `Splunkd.service`.

### Limits drop-in

Put limits in a drop-in, never in the unit itself — `enable boot-start`
regenerates the unit and wipes hand-edits.

```bash
mkdir -p /etc/systemd/system/Splunkd.service.d
cat > /etc/systemd/system/Splunkd.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65536
LimitNPROC=16384
LimitFSIZE=infinity
LimitDATA=infinity
TasksMax=infinity
EOF
systemctl daemon-reload
```

Running as root masks limit problems; as a normal user they surface
immediately, usually as search failures under load.

### polkit

`-create-polkit-rules 1` writes `/etc/polkit-1/rules.d/10-Splunkd.rules`,
letting the `splunk` user manage the service without sudo:

```bash
cat /etc/polkit-1/rules.d/*Splunkd*
```

It must be a `.rules` (JavaScript) file — Ubuntu 24.04 ships polkit 124, which
dropped `.pkla` support entirely. The generated rule grants `start`, `stop` and
`restart` only, not `reload`, `enable` or `disable`.

If you need to write it by hand:

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

### Rocky Linux / RHEL

No AppArmor — SELinux instead. A non-standard syslog directory needs a label
or rsyslog silently cannot write to it:

```bash
semanage fcontext -a -t var_log_t "/syslog(/.*)?"
restorecon -Rv /syslog
ausearch -m avc -ts recent        # when something silently does not work
```

Firewall is `firewalld`/`nftables`, not `iptables-persistent`. There is no
`adm` group — grant Splunk read access via a dedicated group or `setfacl`.

---

## 9. Start and verify

```bash
systemctl start Splunkd
systemctl status Splunkd --no-pager

# Running as splunk, not root
ps -ef | grep [s]plunkd | head -3
ps -ef | grep [m]ongod | head -1

# Limits took effect
cat /proc/$(pgrep -f "splunkd.*under-systemd" | head -1)/limits \
  | grep -E 'processes|open files'

# Ports — compare against the baseline
diff /root/ports-pre.txt <(ss -tlnp | grep -E '443|8000|8089|8191|9997|514|6514|8443')

# Config intact
/opt/splunk/bin/splunk btool check 2>&1 | diff /root/btool-pre.txt -
sudo -u splunk /opt/splunk/bin/splunk list index | diff /root/indexes-pre.txt -

# splunk user can drive the service without sudo
su - splunk -c 'systemctl restart Splunkd'
```

In Splunk Web:

- Login works, including SAML/SSO if configured
- `index=_internal earliest=-5m` returns events
- A search against a real client index returns current data
- Forwarder Management loads, clients phoning home
- DB Connect health dashboard, both JVMs up (`ps -ef | grep [j]ava`)
- Modular inputs running (`ps -ef | grep [p]ython3`)

Then confirm cold/frozen actually work — the failure here is delayed by days,
so force it if you can:

```bash
sudo -u splunk /opt/splunk/bin/splunk btool indexes list --debug \
  | grep -E 'coldPath|coldToFrozenDir' | sort -u
find /colddb -newermt '-1 hour' | head
```

---

## 10. Reboot test

Non-negotiable. Everything in section 6 and 7 has a persistence trap.

```bash
reboot
```

After it returns:

```bash
systemctl is-active Splunkd
ps -ef | grep [s]plunkd | head -3
ss -tlnp | grep -E '443|8000|8089|9997|514|6514|8443'
iptables -t nat -L -n -v | grep 8443       # redirect survived
mount | grep -E 'colddb|frozen'            # volumes mounted before splunkd started
sudo -u splunk head -1 /syslog/*/*.log 2>/dev/null | head -3
```

If the redirect is gone: `netfilter-persistent save` was never run.

---

## 11. Hardening and loose ends

**Stop the splunk user escalating back to root.** If it can edit
`splunk-launch.conf`, it can set `SPLUNK_OS_USER=root` — this is Splunk
advisory SPL-CAAAP3M:

```bash
chown root:splunk /opt/splunk/etc/splunk-launch.conf
chmod 640 /opt/splunk/etc/splunk-launch.conf
```

Matters most where `splunk` is a real login account rather than a
`useradd -r` service account.

**Find anything still running Splunk as root:**

```bash
crontab -l | grep -i splunk
ls -la /etc/cron.d/ | grep -i splunk
grep -rl '/opt/splunk/bin/splunk' /etc/cron* /usr/local/bin 2>/dev/null
```

Backup scripts and diag cron jobs are the usual offenders. Every one of them
needs `sudo -u splunk` in front of the binary, or it recreates root-owned files
inside a splunk-owned tree and you are back to `Permission denied` on the
pidfile.

**Ongoing rule:** run the procedure as root, but every
`$SPLUNK_HOME/bin/splunk` invocation goes through `sudo -u splunk`.

**Drift check** — run a week later:

```bash
find /opt/splunk ! -user splunk | head
find /syslog ! -user syslog | head
```

Anything that shows up identifies a process still running as root.

---

## 12. Rollback

Restore the VM snapshot. That is the clean path.

Manual reversal if you have to:

```bash
systemctl stop Splunkd
/opt/splunk/bin/splunk disable boot-start
sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=root/' /opt/splunk/etc/splunk-launch.conf
chown -R root:root /opt/splunk
/opt/splunk/bin/splunk enable boot-start -systemd-managed 1 --accept-license --answer-yes --no-prompt
systemctl daemon-reload
systemctl start Splunkd
```

Also revert `web.conf` `httpport` and remove the iptables redirect if you
changed them.

Ownership on `/colddb`, `/frozenpath` and `/syslog` can stay as `splunk` — root
reads them regardless.

---

## Checklist

- [ ] VM snapshot, `etc` tarball, KV store backup
- [ ] Index paths inventoried (`btool indexes list --debug`)
- [ ] `splunk` account is not a `sudo`-capable login user
- [ ] `splunk` in `adm`
- [ ] `chown -R splunk:splunk /opt/splunk`
- [ ] `chown -R splunk:splunk` on every external cold/frozen/thawed path
- [ ] Write test as splunk on each external path
- [ ] `SPLUNK_OS_USER=splunk` (changed, not appended)
- [ ] Splunk Web off port 443 (redirect persisted, or capability granted)
- [ ] rsyslog `DirCreateMode`/`FileCreateMode` set; existing files swept
- [ ] `splunk` can read `/syslog` (tested, not assumed)
- [ ] `enable boot-start -systemd-managed 1 -user splunk -create-polkit-rules 1`
- [ ] limits drop-in in `.d/`, verified in `/proc/<pid>/limits`
- [ ] splunkd running as `splunk`
- [ ] `splunk-launch.conf` owned `root:splunk`, mode 640
- [ ] Cron/scripts updated to `sudo -u splunk`
- [ ] Reboot test passed, including iptables redirect and mounts
