# Splunk Enterprise — Manual Upgrade How-To

Procedure for upgrading a **standalone** Splunk Enterprise instance (non-root
`splunk` user, systemd-managed) on Ubuntu. Written for an in-place package
upgrade that preserves `/opt/splunk/etc` (all config) and indexed data.

> **Recommended target:** stay on the same minor line for low-risk patching
> (e.g. `10.2.6 -> 10.2.7`). Jumping a minor version (e.g. `10.2.x -> 10.4.x`)
> is a bigger change and needs the extra pre-flight in section 0. Do the bigger
> jump only in a planned window, and rehearse it on a clone first.

> **Who runs what:** run the whole procedure as **root** (or via `sudo`).
> Package install, `systemctl`, `enable boot-start` and `daemon-reload` are
> root operations. But **every `$SPLUNK_HOME/bin/splunk` invocation goes through
> `sudo -u splunk`**, even when you are already root. Running the Splunk binary
> as root writes root-owned files into a splunk-owned tree and you end up with
> `Permission denied` on the pidfile and `local.meta` files.

---

## Get the download URL (build hash)

Splunk download URLs embed a build hash that changes every release, e.g.:

```
splunk-10.2.7-<build>-linux-amd64.deb
```

The `<build>` hash is **not guessable**. Get the exact URL from:
<https://www.splunk.com/en_us/download/splunk-enterprise.html>
-> choose Linux `.deb` for your version -> copy the "wget" command shown on
the "Thank you for downloading" page.

Replace `<build>` everywhere below with the real hash (10.2.7 was
`c0bff5b0fac3` — yours will differ).

---

## 0. Extra pre-flight for a MINOR version jump

Skip this section for patch-level bumps within the same minor line. Do all of
it, days ahead of the window, for anything like `10.2.x -> 10.4.x`.

**Confirm the upgrade path is direct.** Do not assume. The table is on the
*How to upgrade Splunk Enterprise* page for the **target** version — find your
exact current version in the left column. If it is absent, an intermediate
upgrade is required first.

**App and add-on compatibility.** Check every non-Splunk app against the target
version on Splunkbase and the Splunk Products version compatibility matrix.
DB Connect and vendor TAs (Sophos, etc.) are the usual blockers.

```bash
ls /opt/splunk/etc/apps/
```

**Certificates.** 10.2 rejects SHA-1 signed certificates; 10.4 removes SHA-1
signature support entirely. Audit before upgrading:

```bash
for f in /opt/splunk/etc/auth/*.pem; do
  echo "== $f"
  openssl x509 -in "$f" -noout -subject -dates -serial 2>/dev/null
  openssl x509 -in "$f" -noout -text 2>/dev/null | grep -m1 'Signature Algorithm'
done
```

Note the stock `SplunkCommonCA` shipped in `cacert.pem` expires
**28 January 2027**. If any deployment sets `sslVerifyServerCert = true`
against the default certs, forwarder TLS breaks fleet-wide on that date. Check:

```bash
sudo -u splunk /opt/splunk/bin/splunk btool inputs list --debug  | grep -i sslVerifyServerCert
sudo -u splunk /opt/splunk/bin/splunk btool outputs list --debug | grep -i sslVerifyServerCert
```

**KV Store TLS settings.** 10.4 changes how TLS settings under the `[kvstore]`
stanza in `server.conf` are handled, and removes the old MongoDB engine
binaries. Review the stanza and strip anything not specifically used for
KV Store TLS.

```bash
sudo -u splunk /opt/splunk/bin/splunk btool server list kvstore --debug
```

**jQuery and Python readiness.** 10.4 removes jQuery 2. Run the Python Upgrade
Readiness App's jQuery scan and Python scan against all apps — Simple XML
dashboards in local apps are the exposure.

**Resource footprint.** 10.x adds sidecar processes (`splunk-supervisor`,
`ipc_broker`, `agent-manager`, `identity`, `splunk-spotlight`,
`cmp-orchestrator`) plus a JVM language server started with `-Xmx3g`. Check
free RAM before upgrading a constrained box.

**License manager ordering.** If the start output says
`Bypassing local license checks since this instance is configured with a
remote license master`, this box is a licence peer. Upgrade the licence
manager before its peers.

---

## 1. Pre-upgrade checks

```bash
# Confirm current version and note it down
sudo -u splunk /opt/splunk/bin/splunk version

# Check free disk space (need room for the package + extraction)
df -h /opt

# Ownership must be splunk — the 10.x preinstall drops privileges to the
# splunk user and aborts its prechecks if it cannot read the tree.
stat -c '%U:%G' /opt/splunk
find /opt/splunk -user root | wc -l      # expect 0 on a migrated box
```

If that count is non-zero, `chown -R splunk:splunk /opt/splunk` while Splunk is
stopped. Symptom if you skip it: `Cannot initialize: .../local.meta:
Permission denied`, a bogus `Active KVStore version upgrade precheck FAILED!`,
and `failed to run splunk-preinstall as splunk`. The KV Store error is a red
herring — it is a permissions problem, not a KV Store problem.

## 2. Back up configuration (CRITICAL)

Backs up all config: indexes, props, transforms, deployment-apps,
serverclass, TLS certs, everything under etc/.

```bash
sudo tar czf /root/splunk-etc-backup-$(date +%Y%m%d).tgz -C /opt/splunk etc
```

**Take a VM snapshot as well.** There is no supported downgrade; the snapshot
is the only clean rollback.

## 3. Back up the KV store

10.x relies heavily on the KV store; back it up before migration.

```bash
sudo -u splunk /opt/splunk/bin/splunk backup kvstore
# prompts for credentials — do NOT pass -auth admin:<pass> on the command
# line, it lands in shell history and in ps output
# archive lands under $SPLUNK_HOME/var/lib/splunk/kvstorebackup/
```

## 4. Record current running state (for comparison afterward)

Capture a baseline so section 12 is a `diff`, not an eyeball check.

```bash
sudo -u splunk /opt/splunk/bin/splunk status
ss -tlnp | grep -E "8000|8089|9997|8443|514|6514"      > /root/ports-pre.txt
sudo -u splunk /opt/splunk/bin/splunk btool check 2>&1 > /root/btool-pre.txt
sudo -u splunk /opt/splunk/bin/splunk list index       > /root/indexes-pre.txt
ls /opt/splunk/etc/apps/                               > /root/apps-pre.txt
systemctl cat Splunkd                                  > /root/Splunkd.service-pre.txt
```

## 5. Download the new package

```bash
cd ~
wget -O splunk-10.2.7-<build>-linux-amd64.deb \
  "https://download.splunk.com/products/splunk/releases/10.2.7/linux/splunk-10.2.7-<build>-linux-amd64.deb"
```

## 6. Stop Splunk and take systemd out of the way

```bash
sudo systemctl stop Splunkd
sudo -u splunk /opt/splunk/bin/splunk status     # confirm fully stopped

# Required: see step 8 for why
sudo /opt/splunk/bin/splunk disable boot-start
```

## 7. Install the new package over the existing one

dpkg upgrades in place, preserving /opt/splunk/etc and indexed data.

```bash
sudo dpkg -i splunk-10.2.7-<build>-linux-amd64.deb
```

Expect `dpkg: warning: unable to delete old directory
'/opt/splunk/lib/python3.x/...': Directory not empty` lines. Cosmetic — stale
directories holding app-dropped files. Leave them.

## 8. First start as the splunk user (runs migration)

Run the binary directly so you see the migration output and can answer the
migration prompt. On 10.x this takes several minutes (mongod, sidecars
re-initialize) — do not Ctrl-C it.

**This only works with boot-start disabled (step 6).** When the instance is
systemd-managed, `splunk start` is mapped to `systemctl start Splunkd`, the
`--answer-yes --no-prompt` flags are dropped, and a minor-version upgrade can
stall on the interactive migration prompt with nowhere to answer it.

```bash
sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt
```

Second terminal:

```bash
tail -F /opt/splunk/var/log/splunk/splunkd.log | grep -iE 'error|fail|cert|kvstore|bind'
```

Harmless things you will see in the output:

- `New certs have been generated in '/opt/splunk/etc/auth'` — regenerates
  `server.pem` only. `cacert.pem` / `ca.pem` report *already a renewed Splunk
  certificate: skipping renewal*. Forwarder TLS is unaffected.
- A KV Store `version 4.2 no longer supported` advisory even when the correct
  mongod is running and `splunk show kvstore-status` reports `ready`.

## 9. Confirm the new version

```bash
sudo -u splunk /opt/splunk/bin/splunk version
sudo -u splunk /opt/splunk/bin/splunk show kvstore-status | grep -iE 'status|version|migration'
```

## 10. Hand control back to systemd

```bash
sudo -u splunk /opt/splunk/bin/splunk stop

sudo /opt/splunk/bin/splunk enable boot-start -systemd-managed 1 \
  -user splunk -group splunk -create-polkit-rules 1 \
  --accept-license --answer-yes --no-prompt
sudo systemctl daemon-reload

sudo systemctl start Splunkd
sudo systemctl status Splunkd --no-pager
```

Confirm splunkd is running as `splunk` and not root:

```bash
ps -ef | grep [s]plunkd | head -3
```

## 11. Verify ports and service health

```bash
diff /root/ports-pre.txt <(ss -tlnp | grep -E "8000|8089|9997|8443|514|6514")
sudo journalctl -u Splunkd -n 100 --no-pager
```

## 12. Confirm configuration survived the upgrade

```bash
sudo -u splunk /opt/splunk/bin/splunk btool check 2>&1 | diff /root/btool-pre.txt -
sudo -u splunk /opt/splunk/bin/splunk list index      | diff /root/indexes-pre.txt -
ls /opt/splunk/etc/apps/                              | diff /root/apps-pre.txt -

# SSL receiving still defined
sudo -u splunk /opt/splunk/bin/splunk btool inputs list --debug | grep "splunktcp-ssl"
```

New warnings from `btool check` that are absent in `btool-pre.txt` are the ones
worth chasing. Watch in particular for deprecated or invalid keys in
`authentication.conf` — the migration edits that file (it reports *Renaming
biased terminology inside authentication.conf*). **On instances using SAML,
test SSO login immediately after the upgrade.**

```bash
diff /opt/splunk/etc/system/local/authentication.conf \
     <(tar xzOf /root/splunk-etc-backup-*.tgz etc/system/local/authentication.conf)
```

## 13. Verify resource limits and polkit (systemd)

The package upgrade and `enable boot-start` both regenerate the systemd unit.
The limits drop-in lives in a separate `.d/` directory so it should survive —
confirm:

```bash
cat /etc/systemd/system/Splunkd.service.d/limits.conf
cat /proc/$(pgrep -f "splunkd.*under-systemd" | head -1)/limits | grep -E "processes|open files"
# expect: Max processes 16384 / Max open files 65536

# splunk user can manage the service without sudo
ls -la /etc/polkit-1/rules.d/ | grep -i splunk
su - splunk -c 'systemctl restart Splunkd'
```

The generated polkit rule grants `start`, `stop` and `restart` only — not
`reload`, `enable` or `disable`.

## 14. Functional checks (web UI)

- Log into Splunk Web (https://<server-ip> on 443 via the 8443 redirect, or :8000)
- **SAML/SSO login** if configured — see step 12
- Settings -> Forwarder Management — deployment server page loads, server
  classes present
- Run a search against a live index to confirm data flows
- Confirm forwarders are still connecting and sending
- DB Connect: check the app's health dashboard and that both JVMs are up
  (`ps -ef | grep [j]ava`)
- Modular inputs running (Sophos TA and similar): `ps -ef | grep [p]ython3`

## 15. Reboot test

Non-negotiable. Boot-start failure is silent until the next unplanned reboot.

```bash
reboot
```

After it comes back:

```bash
systemctl is-active Splunkd
ps -ef | grep [s]plunkd | head -3
ss -tlnp | grep -E "8000|8089|9997|8443|514|6514"
sudo iptables -t nat -L -n -v | grep 8443     # 443 -> 8443 redirect survived
```

If the redirect is gone, the iptables rules were never persisted:
`sudo netfilter-persistent save`.

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
Compare against `/root/Splunkd.service-pre.txt`.

---

## Rollback plan

**Restore the VM snapshot.** That is the only clean path — Splunk does not
support downgrade.

Config-only fallback if no snapshot exists:

1. Stop Splunk: `sudo systemctl stop Splunkd`
2. Restore the etc backup:
   ```bash
   sudo rm -rf /opt/splunk/etc
   sudo tar xzf /root/splunk-etc-backup-<date>.tgz -C /opt/splunk
   sudo chown -R splunk:splunk /opt/splunk/etc
   ```
3. Reinstall the OLD package: `sudo dpkg -i splunk-<oldversion>-<build>-linux-amd64.deb`
4. Start and verify.

**Caveat:** 10.2 replaced the fishbucket database backend. Downgrading loses
checkpoints written after the upgrade, which causes partial re-ingestion and
duplicate events. The config-only rollback is a last resort, not a clean undo.

**Keep the previous version's `.deb` and the backups until the upgrade is
confirmed solid.**

---

## Revision notes

**2026-09-02 — revised after the 9.4.12 -> 10.2.7 rollout.**

- **Steps 6/8/10 restructured.** The old step 8 said "do NOT use systemctl for
  this first start" but `sudo -u splunk splunk start` *is* a systemctl call
  when the instance is systemd-managed — the flags were being dropped and a
  minor upgrade would stall on the migration prompt. Boot-start is now disabled
  in step 6 and re-enabled in step 10.
- **Step 1 gained an ownership check.** The 10.x preinstall drops privileges to
  the `splunk` user; on a tree with root-owned files it aborts with a
  misleading KV Store precheck failure.
- **Step 3 no longer passes `-auth admin:<pass>`** on the command line.
- **Step 4 now captures a baseline**, so step 12 is a `diff` rather than a
  visual scan.
- **New section 0** for minor-version jumps: upgrade path, app compatibility,
  SHA-1 certificates, `[kvstore]` TLS settings, jQuery/Python readiness,
  resource footprint, licence manager ordering.
- **New step 15: reboot test**, including the 443 -> 8443 redirect.
- **Step 12 now covers `authentication.conf`** — the migration edits it, so
  SAML login needs an explicit test.
- **Rollback** now leads with the VM snapshot and documents the fishbucket
  caveat.
- Header note added on who runs what (root vs `sudo -u splunk`).
