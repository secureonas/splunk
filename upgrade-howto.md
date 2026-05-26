# Splunk Enterprise — Manual Upgrade How-To

Procedure for upgrading a **standalone** Splunk Enterprise instance (non-root
`splunk` user, systemd-managed) on Ubuntu. Written for an in-place package
upgrade that preserves `/opt/splunk/etc` (all config) and indexed data.

> **Recommended target:** stay on the same minor line for low-risk patching
> (e.g. `10.2.1 -> 10.2.3`). Jumping a minor version (e.g. to `10.4`) is a
> bigger change (new navigation, Python 3.13, deprecated features) and needs
> more validation, especially with custom TAs and props/transforms. Do the
> bigger jump only in a planned window.

---

## Get the download URL (build hash)

Splunk download URLs embed a build hash that changes every release, e.g.:

```
splunk-10.2.3-<build>-linux-amd64.deb
```

The `<build>` hash is **not guessable**. Get the exact URL from:
<https://www.splunk.com/en_us/download/splunk-enterprise.html>
-> choose Linux `.deb` for your version -> copy the "wget" command shown on
the "Thank you for downloading" page.

Replace `<build>` everywhere below with the real hash (e.g. the 10.2.0 build
was `d749cb17ea65`, 10.2.1 was `c892b66d163d` — yours will differ).

---

## 1. Pre-upgrade checks

```bash
# Confirm current version and note it down
sudo -u splunk /opt/splunk/bin/splunk version

# Check free disk space (need room for the package + extraction)
df -h /opt
```

## 2. Back up configuration (CRITICAL)

Backs up all config: indexes, props, transforms, deployment-apps,
serverclass, TLS certs, everything under etc/.

```bash
sudo tar czf /root/splunk-etc-backup-$(date +%Y%m%d).tgz -C /opt/splunk etc
```

## 3. Back up the KV store

10.x relies heavily on the KV store; back it up before migration.

```bash
sudo -u splunk /opt/splunk/bin/splunk backup kvstore -auth admin:<yourpass>
# archive lands under $SPLUNK_HOME/var/lib/splunk/kvstorebackup/
```

## 4. Record current running state (for comparison afterward)

```bash
sudo -u splunk /opt/splunk/bin/splunk status
ss -tlnp | grep -E "8000|8089|9997|6514"
```

## 5. Download the new package

```bash
cd ~
wget -O splunk-10.2.3-<build>-linux-amd64.deb \
  "https://download.splunk.com/products/splunk/releases/10.2.3/linux/splunk-10.2.3-<build>-linux-amd64.deb"
```

## 6. Stop Splunk cleanly

```bash
sudo systemctl stop Splunkd
# confirm fully stopped
sudo -u splunk /opt/splunk/bin/splunk status
```

## 7. Install the new package over the existing one

dpkg upgrades in place, preserving /opt/splunk/etc and indexed data.

```bash
sudo dpkg -i splunk-10.2.3-<build>-linux-amd64.deb
```

## 8. First start as the splunk user (runs migration)

Do NOT use systemctl for this first start — run the binary so you see the
migration output. On 10.x this takes a few minutes (mongod, postgres,
sidecars re-initialize).

```bash
sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes
```

## 9. Confirm the new version

```bash
sudo -u splunk /opt/splunk/bin/splunk version
```

## 10. Hand control back to systemd

```bash
sudo -u splunk /opt/splunk/bin/splunk stop
sudo systemctl start Splunkd
sudo systemctl status Splunkd --no-pager
```

## 11. Verify ports and service health

```bash
ss -tlnp | grep -E "8000|8089|9997|6514"
sudo journalctl -u Splunkd -n 100 --no-pager
```

## 12. Confirm configuration survived the upgrade

```bash
# SSL receiving still defined
sudo -u splunk /opt/splunk/bin/splunk btool inputs list --debug | grep "splunktcp-ssl"

# Apps present
ls /opt/splunk/etc/apps/ | grep -E "Splunk_TA|CIM|Sigma|app_indexes"

# Indexes present
sudo -u splunk /opt/splunk/bin/splunk list index | grep -E "windows|linux|fw|av|o365|iis|network"
```

## 13. Verify resource limits (systemd drop-in)

The package upgrade can regenerate the systemd unit. The limits drop-in lives
in a separate `.d/` directory so it should survive — confirm:

```bash
cat /etc/systemd/system/Splunkd.service.d/limits.conf
cat /proc/$(pgrep -f "splunkd.*under-systemd" | head -1)/limits | grep -E "processes|open files"
# expect: Max processes 16384 / Max open files 65536
```

## 14. Functional checks (web UI)

- Log into Splunk Web (https://<server-ip> on 443, or :8000)
- Settings -> Forwarder Management — deployment server page loads, server
  classes present
- Run a search against a live index to confirm data flows
- Confirm forwarders are still connecting and sending

---

## If boot-start is broken after upgrade

If `systemctl start Splunkd` fails or the unit looks wrong, regenerate it:

```bash
sudo /opt/splunk/bin/splunk enable boot-start -systemd-managed 1 \
  -user splunk -group splunk -create-polkit-rules 1 \
  --accept-license --answer-yes --no-prompt
sudo systemctl daemon-reload
```

Then re-check the limits drop-in (step 13) still exists; if the unit was
replaced, the `.d/limits.conf` is separate and should remain, but verify.

---

## Rollback plan

Splunk does not officially support downgrade, but for a standalone box:

1. Stop Splunk: `sudo systemctl stop Splunkd`
2. Restore the etc backup:
   ```bash
   sudo rm -rf /opt/splunk/etc
   sudo tar xzf /root/splunk-etc-backup-<date>.tgz -C /opt/splunk
   sudo chown -R splunk:splunk /opt/splunk/etc
   ```
3. Reinstall the OLD package: `sudo dpkg -i splunk-<oldversion>-<build>-linux-amd64.deb`
4. Start and verify.

**Keep the previous version's `.deb` and the backups until the upgrade is
confirmed solid.**
