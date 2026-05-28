# Splunk Enterprise Standalone — Bootstrap

One-command installer for a complete Splunk Enterprise standalone instance
on a fresh Ubuntu 24.04 VM with internet access.

Designed for Secureon MSP deployments — the box must be able to reach
`download.splunk.com`, `github.com`, and `raw.githubusercontent.com`.
For air-gapped clients, use the manual zip workflow.

---

## Usage

### Recommended (auditable)
```bash
curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh                # read it first
sudo bash bootstrap.sh           # then run
```

### One-liner (you trust the script)
```bash
curl -sL https://raw.githubusercontent.com/secureonas/splunk/main/bootstrap.sh | sudo bash
```

### Unattended / scripted
```bash
sudo bash bootstrap.sh -y \
  --splunk-version 10.2.3 \
  --indexer-ip 192.168.10.50 \
  --role full
```

## What it does

1. Checks Ubuntu 24.04, root, disk space, internet
2. Detects existing Splunk install (prompts before continuing)
3. Asks for Splunk version (from a curated list), indexer IP, role
4. Generates a strong random admin password
5. Installs prerequisites (`ansible`, `vim`, `unzip`, `wget`, `curl`)
6. Downloads the playbook from `secureonas/splunk` repo
7. Downloads the Splunk `.deb` from `download.splunk.com`
8. Configures `group_vars` from the inputs
9. Runs `ansible-playbook site.yml`
10. Prints the generated admin password at the end

## Curated Splunk versions

Update the `SPLUNK_VERSIONS` array at the top of `bootstrap.sh` when validating a new patch. Current entries:
- `10.4.0` (build `f798d4d49089`)
- `10.2.3` (build `4d61cf8a5c0c`) — default
- `10.0.6` (build `098ea5cc39ba`)
- `9.4.11` (build `bbcbf19b5450`)

Other versions: pass `--splunk-version` + `--splunk-build`.

## Roles

- `full` — everything (indexes, syslog, 443, deployment server, apps, system_config) — default
- `indexer` — bare indexer (install + ulimits + THP + service + 9997 receiving + license-saving transforms)

## What's in the repo

- `bootstrap.sh` — this installer
- `splunk-standalone-ansible.tar.gz` — the Ansible playbook (uploaded alongside the bootstrap)
- Splunk apps & TAs — fetched by the playbook at runtime

## Re-running

The playbook is idempotent — re-running on a configured box only updates config (skips reinstall). Pass `--admin-password '<existing>'` so it doesn't regenerate.

## Troubleshooting

Bootstrap log: `/var/log/splunk-bootstrap.log`
Splunk service log: `sudo journalctl -u Splunkd -n 100 --no-pager`
Playbook dir (for manual re-runs): `/root/splunk-bootstrap/splunk-standalone`
