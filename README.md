# Splunk Enterprise Standalone — Automated Deployment

One-command deployment of Splunk Enterprise Standalone with syslog ingestion,
TLS receiver, deployment server, and license-saving optimizations. Designed for
Secureon MSP setups — repeatable, idempotent, and audit-friendly.

**Supported OS:**
- Ubuntu 22.04 / 24.04 LTS
- RHEL 9 / 10, Rocky Linux 9 / 10, AlmaLinux 9 / 10, Oracle Linux 9 / 10

**Required:** Internet access to `download.splunk.com`, `github.com`,
`raw.githubusercontent.com`, distro package mirrors. For air-gapped sites, see
the [Air-gapped install](#air-gapped-install) section.

---

## Quick start

On a fresh VM (root or sudo-capable user), pick one of these:

```bash
# Interactive (recommended — see what the script does before running)
curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh            # inspect
sudo bash bootstrap.sh       # run

# One-liner (you trust the script)
curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh | sudo bash

# Unattended / scripted
sudo bash bootstrap.sh -y \
  --splunk-version 10.2.3 \
  --indexer-ip 192.168.10.50 \
  --role full
```

That's it. After 5-10 minutes the script prints the admin password and the
Web URL. Splunk is installed, running, configured, and accepting data on all
expected ports.

---

## What it does

The bootstrap script handles the OS detection and orchestration. It calls an
Ansible playbook that does the actual work in layers:

| Layer | What it does | Skipped in `indexer` role |
|---|---|---|
| OS prep | ulimits, THP disable, SELinux permissive (RHEL), firewall disable (RHEL), ACLs (RHEL) | no |
| Splunk install | Non-root `splunk` user, package install, admin password seed, boot-start with polkit | no |
| Receiving | SSL receiver on 9997 (`splunktcp-ssl`) | no |
| License-saving | Windows event shortener, nullQueue rules, data integrity | no |
| Indexes | Creates 7 custom indexes (windows, linux, o365, fw, av, iis, network) | yes |
| Syslog | rsyslog on UDP/TCP 514 + TLS on 6514, writes to `/syslog/<ip>/<facility>.log` | yes |
| Web on 443 | iptables redirects 443 → 8443 (SSL Web), saved persistently | yes |
| Deployment Server | SendToIndexer apps + 4 serverclasses (Linux/Windows × send/collect) | yes |
| Apps | CIM, Splunk_TA_nix, Splunk_TA_windows (pristine in etc/apps + custom inputs in deployment-apps), Sigma_Alerts disabled | yes |
| Server self-monitoring | Splunk monitors its own `/var/log` and runs `df.sh` every 6h | yes |

---

## Roles (deployment profiles)

The script asks which role you want, or accept the flag:

### `full` (default)
Complete standalone Splunk:
- Indexer + Search Head + Deployment Server in one box
- Syslog receiver active
- Web UI on https://&lt;ip&gt;/ (port 443 redirects to SSL 8443)
- All apps, indexes, license-saving rules

Use this for: lab installs, small client deployments, single-server SOCs.

### `indexer`
Bare indexer only:
- Splunk installed under `splunk` user with ulimits + THP
- Boot-start configured
- SSL receiving on 9997 (an indexer's job)
- License-saving transforms applied
- **No** syslog, **no** Web on 443, **no** deployment server, **no** apps, **no** custom indexes

Use this for: an indexer node in a distributed Splunk environment where
deployment server lives elsewhere and indexes are managed by a cluster master.

---

## Splunk version selection

The script ships with a curated table of validated versions:

| Version | Build hash | Notes |
|---|---|---|
| 10.4.0 | f798d4d49089 | latest |
| **10.2.3** | **4d61cf8a5c0c** | **default — current 10.2 patch** |
| 10.0.6 | 098ea5cc39ba | 10.0 maintenance line |
| 9.4.11 | bbcbf19b5450 | older clients still on 9.x |

Press Enter at the prompt for the default. Or pass `--splunk-version` for a
specific one. For versions not in the table, pass both
`--splunk-version X.Y.Z --splunk-build &lt;hash&gt;` (get the hash from
splunk.com/download).

When a new Splunk version comes out, update the `SPLUNK_VERSIONS` array near
the top of `bootstrap.sh`, then re-upload to the GitHub repo.

---

## Per-OS specifics

### Ubuntu 24.04

- Splunk runs as `splunk` user, in `adm` group (so it can read `/var/log` and
  `/syslog` standard files)
- rsyslog runs as `syslog:adm` (default), files in `/syslog` get same ownership
- AppArmor profile for rsyslog gets a local override allowing
  `/syslog/** rw` + cert dir reads
- Firewall: `ufw` left untouched (assumed inactive)
- 443→8443 persistence via `iptables-persistent` (package
  `netfilter-persistent`)

### RHEL 9/10 (and Rocky/Alma/Oracle Linux 9/10)

- Splunk runs as `splunk` user (no `adm` group on RHEL)
- rsyslog runs as `root` (RHEL default) and is configured to write `/syslog`
  files directly as `splunk:splunk`
- `/var/log` is `root:root` (no `adm` group) so the playbook applies a POSIX
  ACL: `setfacl -R -m u:splunk:rx /var/log` and a default ACL so newly-created
  files inherit the access
- SELinux set to **permissive** (logged but not enforced). Auditors should be
  told this is the intentional choice; the alternative would be writing a
  proper SELinux policy.
- firewalld is **disabled and stopped**. Filter chains are flushed; only NAT
  rules for the 443→8443 redirect remain. iptables-services persists those
  rules across reboots.
- AppArmor not present (RHEL uses SELinux instead)

---

## What you get after install

- **Web UI:** https://&lt;server-ip&gt;/ (port 443 redirects to SSL 8443)
- **Receiving from forwarders:** SSL on 9997
- **Syslog ingestion:** UDP/TCP on 514, TLS on 6514, lands in `/syslog/&lt;ip&gt;/&lt;facility&gt;.log`
- **7 indexes ready:** windows, linux, o365, fw, av, iis, network (2TB each, 1 year retention, data integrity enabled)
- **Deployment server ready:** 4 serverclasses defined, TA_nix + TA_windows pre-deployed with custom `local/inputs.conf`
- **Server self-monitoring:** Splunk reads its own `/var/log` and runs `df.sh` every 6 hours into `index=linux`
- **Sigma alerts installed (disabled):** ready to enable when you're ready to tune

---

## Re-running and idempotency

The playbook is idempotent. Re-running on a configured box is safe:
- Splunk install steps are skipped if already current
- The admin password is **not regenerated** if you pass `--admin-password &lt;existing&gt;`
- Config files are checked and only updated if different

If something fails mid-run, fix the issue and re-run the playbook directly
(no need to re-bootstrap):
```bash
cd /root/splunk-bootstrap/splunk-standalone
sudo ansible-playbook site.yml
```

To re-run with different settings, edit `group_vars/splunk_standalone.yml`
on disk, then re-run the playbook.

---

## Files and paths

| Path | Purpose |
|---|---|
| `/root/splunk-bootstrap/` | Bootstrap working directory (downloaded playbook + Splunk package) |
| `/root/splunk-bootstrap/splunk-standalone/` | Ansible playbook root |
| `/root/splunk-bootstrap/splunk-standalone/group_vars/splunk_standalone.yml` | Edit-to-reconfigure variables |
| `/var/log/splunk-bootstrap.log` | Full output of every bootstrap run |
| `/opt/splunk/` | Splunk installation |
| `/syslog/` | Per-source-IP syslog landing tree |
| `/etc/rsyslog.d/40-splunk.conf` | rsyslog drop-in (UDP+TCP 514) |
| `/etc/rsyslog.d/45-splunk-tls.conf` | rsyslog TLS drop-in (6514) |
| `/etc/rsyslog.d/tls/syslog-server-cert.pem` | Self-signed TLS cert |
| `/etc/iptables/rules.v4` *(Ubuntu)* | Persistent iptables rules |
| `/etc/sysconfig/iptables` *(RHEL)* | Persistent iptables rules |

---

## Ports

| Port | Proto | Purpose | Externally accessible by default? |
|---|---|---|---|
| 443 | TCP | Splunk Web (redirects to 8443) | yes |
| 514 | UDP | syslog UDP | yes |
| 514 | TCP | syslog TCP | yes |
| 6514 | TCP | syslog TLS | yes |
| 9997 | TCP | SSL receiving from forwarders | yes |
| 8443 | TCP | Splunk Web SSL (target of 443 redirect) | yes (direct access works too) |
| 8089 | TCP | splunkd management | **localhost only** — do not expose externally |

---

## Common operations

### Verify Splunk is running and healthy
```bash
sudo systemctl status Splunkd --no-pager
sudo -u splunk /opt/splunk/bin/splunk status
ss -tlnp | grep -E "8443|8089|9997|6514"
ss -ulnp | grep ":514 "
```

### Recover the admin password
```bash
grep splunk_admin_password /root/splunk-bootstrap/splunk-standalone/group_vars/splunk_standalone.yml
```

### Restart Splunk
```bash
# As splunk user (preferred, Splunk-aware shutdown)
sudo -u splunk /opt/splunk/bin/splunk restart

# Or via systemd
sudo systemctl restart Splunkd
```
(Polkit rules let the `splunk` user manage the `Splunkd` service without sudo.)

### Send a test syslog message and verify it landed
```bash
# From any host that can reach the Splunk server
logger -p user.info -n &lt;splunk-ip&gt; -P 514 -d "test from $(hostname)"

# Then on the Splunk server, check the file
ls -la /syslog/&lt;sender-ip&gt;/
sudo cat /syslog/&lt;sender-ip&gt;/user.log
```

### Send a TLS syslog test
```bash
# From any other Linux box (no special config needed)
echo '&lt;14&gt;TLS test from openssl' | openssl s_client -connect &lt;splunk-ip&gt;:6514 -quiet
```

---

## Re-deploying / fresh-install on the same box

The playbook detects existing installs and prompts before overwriting. If you
want a truly fresh install:

```bash
sudo systemctl stop Splunkd
sudo /opt/splunk/bin/splunk disable boot-start 2>/dev/null
sudo rm -rf /opt/splunk
sudo userdel splunk 2>/dev/null
sudo rm -rf /root/splunk-bootstrap

# Then re-run the bootstrap
```

---

## Troubleshooting

### Bootstrap failed partway
The script prints the admin password even on partial failure. Splunk may
already be installed. To continue from where it failed:
```bash
cd /root/splunk-bootstrap/splunk-standalone
sudo ansible-playbook site.yml
```
The playbook is idempotent and will skip completed work.

### "Connection refused" or "No route to host" from another machine
On RHEL, check the iptables filter chains:
```bash
sudo iptables -L INPUT -n -v
```
Expected: empty INPUT chain with `policy ACCEPT`. If there are REJECT rules,
the filter table got reloaded somehow. Fix:
```bash
sudo iptables -F INPUT
sudo iptables -F FORWARD
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables-save &gt; /etc/sysconfig/iptables
```

### 443 redirect not working
Verify the NAT rule and its packet counter:
```bash
sudo iptables -t nat -L PREROUTING -n -v
```
The PREROUTING line should show packets. If counter is 0, you may be hitting
:8443 directly in the browser (bypasses 443 entirely) or there's an upstream
firewall blocking 443.

### Splunk user can't read /var/log files (RHEL)
Verify the ACL is in place:
```bash
getfacl /var/log | grep splunk
# Expected: user:splunk:r-x AND default:user:splunk:r-x
```
If missing, re-run the playbook or apply manually:
```bash
sudo setfacl -R -m u:splunk:rx /var/log
sudo setfacl -d -m u:splunk:rx /var/log
```

### SELinux blocking something (RHEL)
SELinux is in permissive mode by default, so it logs but doesn't enforce.
Check what would have been blocked:
```bash
sudo grep AVC /var/log/audit/audit.log | tail -20
```
This is informational — permissive mode won't break anything.

### Splunk's deployment server page shows "unavailable"
After the playbook completes, deployment server may take 1-2 minutes to
fully initialize. If the issue persists:
```bash
sudo -u splunk /opt/splunk/bin/splunk reload deploy-server -auth admin:&lt;password&gt;
```

### Check the full bootstrap log
```bash
sudo less /var/log/splunk-bootstrap.log
```

---

## Air-gapped install

For clients with no internet access, the bootstrap script can't pull files
remotely. Workflow:

1. On a workstation with internet, run the bootstrap or download the artifacts
   manually
2. Bundle the playbook + Splunk package + TAs:
   ```bash
   tar czf splunk-bundle.tar.gz \
     splunk-standalone-ansible.tar.gz \
     splunk-X.Y.Z-&lt;build&gt;.{deb,rpm} \
     splunk-add-on-for-unix-and-linux_*.tgz \
     splunk-add-on-for-microsoft-windows_*.spl \
     splunk-common-information-model-cim_*.tgz \
     sigma_alerts.tar.gz
   ```
3. `scp` the bundle to the air-gapped server
4. On the server: extract, place Splunk package + TAs in the right locations,
   set `splunk_apps_source: local` in `group_vars`, run the playbook directly

(A dedicated air-gapped bootstrap script may be added later — for now the
manual workflow above is the path.)

---

## Customizing per-deployment

After bootstrap downloads the playbook, you can edit
`/root/splunk-bootstrap/splunk-standalone/group_vars/splunk_standalone.yml`
before letting it run. Key variables:

| Variable | Purpose |
|---|---|
| `splunk_admin_password` | Admin password (script auto-generates if not set) |
| `splunk_indexer_ip` | The IP this server uses as the indexer endpoint (auto-detected) |
| `splunk_role` | `full` or `indexer` |
| `splunk_apps_source` | `url` (download from GitHub) or `local` (use files/ dir — air-gapped) |
| `splunk_configure_syslog` | Set false to skip syslog setup |
| `splunk_syslog_tls` | Set false to skip TLS listener (6514) |
| `splunk_web_443` | Set false to skip 443 redirect (use 8000 instead) |
| `splunk_configure_deployment_server` | Set false to skip deployment server |
| `splunk_install_sigma` | Set false to skip sigma_alerts app |
| `splunk_indexes` | List of custom indexes to create |

After editing, run the playbook:
```bash
cd /root/splunk-bootstrap/splunk-standalone
sudo ansible-playbook site.yml
```

---

## Architecture reference

### App layout

`/opt/splunk/etc/apps/` (server-side, pristine — for parsing):
- `Splunk_SA_CIM` — Common Information Model data models
- `Splunk_TA_nix` — Linux parsing TA (+ a local/inputs.conf for server self-monitoring of /var/log + df.sh)
- `Splunk_TA_windows` — Windows parsing TA (pristine)
- `Sigma_Alerts` — installed disabled
- `app_indexes` — defines the 7 custom indexes

`/opt/splunk/etc/deployment-apps/` (pushed to forwarders):
- `SendToIndexerNix` — Linux forwarders: outputs.conf pointing at this indexer over SSL
- `SendToIndexerWin` — Windows forwarders: same purpose
- `Splunk_TA_nix` (full TA + custom `local/inputs.conf` for `/var/log` monitoring)
- `Splunk_TA_windows` (full TA + custom `local/inputs.conf` for Windows event log baseline)

`/opt/splunk/etc/system/local/`:
- `inputs.conf` — SSL receiving on 9997
- `indexes.conf` — `[default] enableDataIntegrityControl = true`
- `props.conf` — routes Windows Security events to license-saving transforms
- `transforms.conf` — event shortener + nullQueue rules for noisy events

### Serverclass mappings

```
Linux_Class            machineTypesFilter=linux-x86_64  → pushes Splunk_TA_nix
Windows_Class          machineTypesFilter=windows-x64    → pushes Splunk_TA_windows
SendToIndexerNix_Class machineTypesFilter=linux-x86_64  → pushes SendToIndexerNix
SendToIndexerWin_Class machineTypesFilter=windows-x64    → pushes SendToIndexerWin
```
A Linux forwarder phoning home gets: `Splunk_TA_nix` (what to collect) + `SendToIndexerNix` (where to send). Same pattern for Windows.

---

## Manual install / migration

If you can't run the automation (or want to convert an existing root-running
Splunk to the `splunk` user), see the [migration runbook](https://github.com/secureonas/splunk/blob/main/SlunkRootToUserMigration.md)
in the repo. It covers the same steps the playbook does, written in
Slovenian comments + English structure for hand-execution.

For Splunk version upgrades on an already-deployed box, see the [upgrade
howto](https://github.com/secureonas/splunk/blob/main/upgrade-howto.md).

---

## Repository structure

```
github.com/secureonas/splunk/
├── bootstrap.sh                              ← the installer (this is what you curl)
├── splunk-standalone-ansible.tar.gz          ← the Ansible playbook (fetched by bootstrap)
├── README.md                                 ← this file
├── SlunkRootToUserMigration.md               ← manual migration runbook (Slovenian)
├── upgrade-howto.md                          ← Splunk upgrade procedure
├── splunk-add-on-for-unix-and-linux_*.tgz    ← TAs (Splunkbase, you upload)
├── splunk-add-on-for-microsoft-windows_*.spl
├── splunk-common-information-model-cim_*.tgz
└── sigma_alerts.tar.gz
```

The Splunk Enterprise package itself is **never** mirrored in this repo (size
limits + licensing). The bootstrap always downloads it directly from
download.splunk.com.

---

## Notes on security

- **Generated admin password** is shown once at end of install and never logged
- **Splunk runs as non-root** (`splunk` user) with polkit-granted systemd control
- **Syslog landing dir** (`/syslog`) is owned `syslog:adm` (Ubuntu) or `splunk:splunk` (RHEL), mode 0755
- **TLS syslog cert** is self-signed (anon mode) — encrypted in transit, no auth
- **Splunk's receiver on 9997** uses SSL with default Splunk certs (encryption, no client cert validation by default)
- **8089 management port** stays localhost-only — do not expose
- **SELinux on RHEL** is permissive (logged, not enforced) — this is an
  intentional choice; auditors should be aware

For hardened deployments (proper SELinux policy, firewall allow-list instead
of flush, mutual-TLS on syslog, real CA-signed certs), the playbook is the
starting point — those tightening steps would be applied per-environment.
