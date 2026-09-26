# Operating the zot registry (day-2 operations)

This document is for people operating this role in a real environment. Every configuration change
**should be made through Ansible variables and then by re-running the playbook**, not by editing
`/etc/zot/config.json` directly (because the next run overwrites the file and your changes are lost).

---

## 1. Quick checks on the target

```bash
systemctl status zot
systemctl cat zot                                  # unit in use
sudo -u zot /usr/local/bin/zot verify /etc/zot/config.json
journalctl -u zot -n 100 --no-pager -o cat          # logs when using journald
tail -f /var/log/zot/zot.log                        # logs when zot_log_output=file

curl -i http://127.0.0.1:5000/v2/                    # 200 or 401 (with auth)
curl -u admin:'...' http://127.0.0.1:5000/v2/_catalog
curl -s http://127.0.0.1:5000/metrics | head        # if metrics are enabled
```

Changing the port or behavior as needed:

```bash
ansible-playbook -i inventory.ini install-zot.yml --check --diff
ansible-playbook -i inventory.ini install-zot.yml -l zot01
ansible-playbook -i inventory.ini install-zot.yml --tags zot:config   # config only
```

---

## 2. Changing configuration safely

1. Edit the variables in the playbook / `group_vars/`.
2. `--check --diff` to preview (the template runs `zot verify` on the rendered version).
3. Run for real: if the config is valid → write the file → handler restarts the service → health check.
4. If `zot verify` fails, the old config file **is not changed**; the service keeps running normally.

zot can hot-reload some settings when the config file changes, but the role always restarts so that the
state is deterministic. If you want to take advantage of hot-reload, you can use `--skip-tags zot:service`…
however, letting the role restart is recommended.

---

## 3. Upgrading the zot version

```yaml
zot_version: "2.1.21"     # switch to the new release
zot_verify_checksum: true # keep as is to download & verify the new binary
```

```bash
ansible-playbook -i inventory.ini install-zot.yml -l zot01 --check --diff   # preview
ansible-playbook -i inventory.ini install-zot.yml -l zot01
```

* `get_url` only downloads when the SHA256 differs → installing and upgrading are both idempotent.
* The old binary is kept as a backup (`backup: true`) in `/usr/local/bin/` (file `zot.<timestamp>`).

### Binary rollback

```bash
sudo systemctl stop zot
sudo cp -a /usr/local/bin/zot.<timestamp> /usr/local/bin/zot
# or point zot_version back to the old release and re-run the playbook
sudo systemctl start zot
curl -fsS http://127.0.0.1:5000/v2/
```

### Config rollback

Every time the config changes, a `.bak` copy is created next to the file (because `zot_config_backup: true`):

```bash
ls -l /etc/zot/config.json*
sudo cp -a /etc/zot/config.json.<timestamp> /etc/zot/config.json
sudo systemctl restart zot
```

---

## 4. Backup & restore

### What to back up

| Path | Contents | How to back up |
| --- | --- | --- |
| `zot_data_dir` (`/var/lib/zot`) | All images/blobs + `meta.db`, `cache.db` | LVM/VM snapshot, `tar`, or rsync while the registry writes little |
| `/etc/zot/config.json`, `/etc/zot/htpasswd` | Configuration + users | Small files, copy directly |
| `group_vars`/vault in the repo | Source of truth for configuration | Git (remember to encrypt the vault) |

Example of a relatively safe hot backup (zot writes blobs atomically, but it should be run outside peak hours):

```bash
sudo tar --xattrs -czf /backup/zot-data-$(date +%F).tar.gz -C /var/lib/zot .
sudo tar -czf /backup/zot-etc-$(date +%F).tar.gz -C /etc zot
```

### Restore

```bash
sudo systemctl stop zot
sudo tar -xzf /backup/zot-data-YYYY-MM-DD.tar.gz -C /var/lib/zot
sudo chown -R zot:zot /var/lib/zot
sudo systemctl start zot
```

If `meta.db`/`cache.db` is corrupted or out of sync with the storage, you can delete it and let zot rebuild:

```bash
sudo systemctl stop zot
sudo rm -f /var/lib/zot/meta.db /var/lib/zot/cache.db
sudo /usr/local/bin/zot serve /etc/zot/config.json --force-reparse   # run manually to rebuild
# Ctrl-C after the log reports the reparse is done, then:
sudo systemctl start zot
```

---

## 5. Cleanup: GC, retention, deleting images

* **Garbage collection** runs inline (no offline step needed). `gcDelay` keeps orphan blobs around a
  little longer so that clients currently pulling are not broken. Tune it via `zot_storage_gc*`.
* **Retention**: use `zot_storage_retention`, **always run with `dryRun: true` first** and read the log
  to check the list that would be deleted.
* **Manually deleting** a tag:

  ```bash
  curl -X DELETE -u admin:'...' \
    http://127.0.0.1:5000/v2/<repo>/manifests/<digest>
  # the blob will be cleaned up by GC after gcDelay
  ```

* Monitoring disk usage:

  ```bash
  du -sh /var/lib/zot
  curl -s http://127.0.0.1:5000/v2/_catalog | jq '.repositories | length'
  ```

---

## 6. Monitoring & logs

| Source | How to use |
| --- | --- |
| journald | `journalctl -u zot -f` (recommended, no logrotate needed) |
| Log file | Set `zot_log_output: file`; the role configures logrotate (`copytruncate`, 14 copies, compressed) |
| Audit log | `zot_log_audit_file`, records every API operation – should be shipped to a central logging system |
| Prometheus | `zot_extensions_metrics: true` → `GET /metrics` |
| Scrub | `zot_extensions_scrub: true` periodically detects bit-rot |
| CVE scan | `zot_extensions_search_cve: true` (Trivy DB, needs `/tmp` space) |

Suggested alerts: `up{job="zot"} == 0`, `zot_data_dir` usage > 80%, `zotregistry_http_...` error rate,
GC job failure (log `garbage collection`), scrub detecting a bad blob.

---

## 7. Troubleshooting

| Symptom | Common cause | Fix |
| --- | --- | --- |
| `Unit zot.service not found` | The role has not been run, or `zot_service_name` differs | `ansible-playbook ... --tags zot:service` |
| Service restarts continuously | Bad config, missing permission to read config/htpasswd, port already in use | `journalctl -u zot -n 200`, `zot verify <config>`, `ss -ltnp \| grep <port>` |
| `permission denied` when writing to storage | Wrong owner for `zot_data_dir` or `ReadWritePaths` is missing a path | `chown -R zot:zot <dir>`; add the path to `zot_systemd_extra_read_write_paths` |
| Push returns `401` | Wrong user/pass or htpasswd uses the wrong scheme | `htpasswd -bnB user pass` to check; the role uses `bcrypt` |
| Push returns `403` | access control blocks it | Check `zot_http_access_control` (adminPolicy/repositories) |
| Push returns `400` with a Docker image | Docker manifest rejected | Add `zot_http_compat: ["docker2s2"]` (and `preserveDigest` when syncing) |
| Pull through sync fails | Missing credentials/cert for the upstream registry | See `zot_extensions_sync_credentials_file`, `certDir`, `sync` logs |
| Docker reports `http: server gave HTTP response to HTTPS client` | The registry is HTTP only | Add `insecure-registries` to `/etc/docker/daemon.json` |
| Service dies after log rotation | Sending SIGHUP is not supported | The role uses `copytruncate`; do not add a `postrotate` that sends HUP |
| systemd hardening causes strange errors | `SystemCallFilter`/`ProtectSystem` too strict for the new version | Temporarily set `zot_systemd_hardening: false` to confirm, then re-enable it piece by piece via `zot_systemd_extra_options` |
| Expected `changed=0` but it still reports changed | The binary was replaced outside the role, or the config was edited by hand | Check `--diff`; let the role be the single source of configuration |
| Cannot download the checksum | The machine blocks GitHub | Use an internal mirror via `zot_checksums_url`, or `zot_binary_checksum`, or `zot_binary_source: local` |
| `zot verify` or startup fails with `panic: open <file>: no such file or directory` | The directory of `zot_log_file` / `zot_log_audit_file` does not exist (zot opens the log file while loading the config) | The role creates `dirname(zot_log_file)` and `dirname(zot_log_audit_file)`; create the directory manually if you changed those paths outside the role |

Quick troubleshooting commands:

```bash
systemctl status zot --no-pager
journalctl -u zot -n 200 --no-pager -o cat
sudo systemd-analyze verify /etc/systemd/system/zot.service
sudo systemd-analyze security zot.service        # hardening score
sudo ss -ltnp | grep 5000
sudo -u zot /usr/local/bin/zot verify /etc/zot/config.json
```

---

## 8. Uninstall

```bash
# 1) Stop and disable the service
sudo systemctl disable --now zot

# 2) Remove the unit, config, logrotate, sysctl
sudo rm -f /etc/systemd/system/zot.service
sudo rm -f /etc/logrotate.d/zot /etc/sysctl.d/90-zot.conf
sudo rm -rf /etc/zot
sudo systemctl daemon-reload

# 3) Remove the binary (and any backups)
sudo rm -f /usr/local/bin/zot /usr/local/bin/zot.*

# 4) Remove the registry data (IRRECOVERABLE if you have no backup!)
sudo rm -rf /var/lib/zot /var/log/zot

# 5) Remove the system user/group
sudo userdel zot 2>/dev/null || true
sudo groupdel zot 2>/dev/null || true
```

---

## 9. Security checklist

- [ ] `zot_http_address` is an internal IP (not `0.0.0.0`) **or** there is a firewall blocking access.
- [ ] `zot_auth_enabled: true` with the password stored in ansible-vault.
- [ ] Admin/CI passwords have been changed away from the default values (`ChangeMe-Admin-123`).
- [ ] TLS is not used by this role (HTTP only): if you need HTTPS, terminate it at a reverse proxy and set `zot_http_address: 127.0.0.1`.
- [ ] `zot_http_access_control` restricts write/delete rights per repo when several teams are involved.
- [ ] `zot_systemd_hardening: true`, the service runs as the non-login `zot` user.
- [ ] `zot_manage_firewall`/security group only opens the port to internal CIDR ranges.
- [ ] `zot_data_dir` + config are backed up regularly and the restore **has been tested**.
- [ ] Audit logs are shipped to a central logging system; alerts fire when the service is down / disk > 80%.

---

## Appendix: full variable list

The table below is generated from [`roles/zot/defaults/main.yml`](../roles/zot/defaults/main.yml)
(the most accurate source, with inline explanatory comments).

| Variable | Default | Description |
| --- | --- | --- |
| `zot_skip_os_check` | `false` | true = skip the OS assertion (not recommended) |
| `zot_minimum_os_version` | `"24.04"` | Minimum Ubuntu version (noble = 24.04) |
| `zot_version` | `"2.1.21"` | "2.1.21" or "v2.1.21" are both accepted |
| `zot_binary_variant` | `full` | full / minimal / debug |
| `zot_binary_source` | `url` | url (download over HTTP/HTTPS) / local (copy from the controller) |
| `zot_binary_dest` | `/usr/local/bin/zot` | Binary: version, source, checksum |
| `zot_binary_dir` | `"{{ zot_binary_dest \| dirname }}"` | Binary: version, source, checksum |
| `zot_binary_owner` | `root` | Binary: version, source, checksum |
| `zot_binary_group` | `root` | Binary: version, source, checksum |
| `zot_binary_mode` | `"0755"` | Binary: version, source, checksum |
| `zot_arch` | `"{{ zot_arch_map[ansible_architecture] \| default(an…` | Binary: version, source, checksum |
| `zot_variant_suffix` | `"{{ zot_variant_suffix_map[zot_binary_variant] \| de…` | Binary: version, source, checksum |
| `zot_binary_asset_name` | `"zot-linux-{{ zot_arch }}{{ zot_variant_suffix }}"` | Binary: version, source, checksum |
| `zot_download_url` | `"https://github.com/project-zot/zot/releases/downloa…` | Source: "url" Defaults to GitHub Releases; override to use an internal mirror. |
| `zot_download_url_headers` | `{}` | e.g. {Authorization: "Bearer <token>"} for a private mirror |
| `zot_download_timeout` | `300` | Binary: version, source, checksum |
| `zot_download_retries` | `3` | Binary: version, source, checksum |
| `zot_download_delay` | `5` | Binary: version, source, checksum |
| `zot_local_binary_path` | `""` | e.g. "{{ playbook_dir }}/files/zot-linux-amd64" |
| `zot_local_binary_checksum` | `""` | optional: "sha256:<hex>" to detect a corrupt file |
| `zot_verify_checksum` | `true` | strongly recommended: keep it true |
| `zot_binary_checksum` | `""` | manual value: "sha256:<hex>" or "<hex>"; wins over auto-detection |
| `zot_checksums_url` | `"https://github.com/project-zot/zot/releases/downloa…` | Binary: version, source, checksum |
| `zot_force_update` | `false` | true = always replace the binary (useful when the checksum does not change) |
| `zot_user` | `zot` | System account and directories |
| `zot_group` | `zot` | System account and directories |
| `zot_user_shell` | `/usr/sbin/nologin` | System account and directories |
| `zot_user_home` | `/nonexistent` | no home directory: the account only runs the service |
| `zot_user_comment` | `"zot registry service account"` | System account and directories |
| `zot_config_dir` | `/etc/zot` | System account and directories |
| `zot_config_file` | `"{{ zot_config_dir }}/config.json"` | System account and directories |
| `zot_config_mode` | `"0640"` | root:zot, the service only needs read access |
| `zot_config_backup` | `true` | keep a .bak file whenever the config changes |
| `zot_validate_config_on_write` | `true` | run `zot verify` before writing the config |
| `zot_data_dir` | `/var/lib/zot` | storage directory (holds images and blobs) |
| `zot_log_dir` | `/var/log/zot` | System account and directories |
| `zot_http_address` | `"0.0.0.0"` | tighten to an internal IP (e.g. 10.0.0.10) if desired |
| `zot_http_port` | `5000` | unprivileged port (1024-65535); privileged ports (< 1024) are not supported |
| `zot_http_realm` | `zot` | HTTP (plain HTTP only - internal use; terminate TLS on a reverse proxy) |
| `zot_http_external_url` | `""` | e.g. "http://registry.internal:5000" |
| `zot_http_read_timeout` | `""` | e.g. "60s" (empty = zot default) |
| `zot_http_write_timeout` | `""` | e.g. "60s" |
| `zot_http_allow_origin` | `""` | e.g. "https://portal.internal" when a web client is used |
| `zot_http_compat` | `[]` | e.g. ["docker2s2"] to mirror/keep Docker digests unchanged |
| `zot_http_ratelimit` | `{}` | e.g. {rate: 100, methods: [{method: GET, rate: 50}]} |
| `zot_http_access_control` | `{}` | full passthrough (adminPolicy/repositories/groups/metrics) |
| `zot_auth_enabled` | `false` | enable htpasswd basic authentication |
| `zot_auth_htpasswd_path` | `"{{ zot_config_dir }}/htpasswd"` | Authentication and authorization |
| `zot_auth_htpasswd_mode` | `"0640"` | root:zot |
| `zot_auth_htpasswd_hash_scheme` | `bcrypt` | bcrypt / apr_md5_crypt / ... |
| `zot_auth_fail_delay` | `5` | seconds, brute-force protection (0 = disabled) |
| `zot_auth_api_key` | `false` | allow API keys (zot >= 2.1.4) |
| `zot_auth_no_log` | `true` | false = show task output (debugging only) |
| `zot_auth_users` | `[]` | Local users: [{name: admin, password: "..."}] (prefer ansible-vault for passwords) |
| `zot_auth_htpasswd_local_file` | `""` | Or copy a pre-built htpasswd file from the controller (path on the controller): |
| `zot_auth_purge_other_users` | `false` | true = the htpasswd file only contains zot_auth_users |
| `zot_storage_commit` | `false` | true = flush to disk immediately (safer, slower) |
| `zot_storage_dedupe` | `true` | deduplicate blobs shared between images |
| `zot_storage_gc` | `true` | inline garbage collection (no downtime needed) |
| `zot_storage_gc_delay` | `"1h"` | grace period before orphan blobs are deleted |
| `zot_storage_gc_interval` | `"6h"` | Storage and tuning |
| `zot_storage_gc_time_window` | `""` | e.g. "02:00-04:00" (empty = GC may run at any time) |
| `zot_storage_max_repos` | `0` | 0 = unlimited (set > 0 to cap the number of repositories) |
| `zot_storage_redirect_blob_url` | `false` | true when using S3/CDN |
| `zot_storage_retention` | `{}` | passthrough: {dryRun: true, policies: [...]} |
| `zot_storage_storage_driver` | `{}` | passthrough for S3/GCS (defaults to local filesystem) |
| `zot_scheduler_num_workers` | `0` | 0 = zot default (4 x number of CPUs) |
| `zot_log_level` | `info` | debug / info / warn / error |
| `zot_log_output` | `journald` | journald (stdout) / file |
| `zot_log_file` | `"{{ zot_log_dir }}/zot.log"` | Logging |
| `zot_log_audit_file` | `"{{ zot_log_dir }}/zot-audit.log"` | "" = disable the audit log |
| `zot_manage_logrotate` | `true` | only used when zot_log_output == "file" |
| `zot_logrotate_days` | `14` | Logging |
| `zot_logrotate_frequency` | `daily` | daily / weekly / monthly |
| `zot_extensions_search` | `true` | GraphQL search + /v2/_zot/ext/* |
| `zot_extensions_search_cve` | `false` | CVE scanning via Trivy (CPU/RAM/disk intensive) |
| `zot_extensions_search_cve_update_interval` | `"24h"` | minimum 2h |
| `zot_extensions_ui` | `true` | web interface |
| `zot_extensions_metrics` | `false` | Prometheus /metrics |
| `zot_extensions_metrics_path` | `/metrics` | Extensions (only effective with the "full" binary) |
| `zot_extensions_scrub` | `true` | periodic bit-rot detection |
| `zot_extensions_scrub_interval` | `"24h"` | minimum 2h |
| `zot_extensions_lint` | `false` | Extensions (only effective with the "full" binary) |
| `zot_extensions_lint_mandatory_annotations` | `[]` | Extensions (only effective with the "full" binary) |
| `zot_extensions_trust` | `false` | Extensions (only effective with the "full" binary) |
| `zot_extensions_trust_cosign` | `true` | Extensions (only effective with the "full" binary) |
| `zot_extensions_trust_notation` | `true` | Extensions (only effective with the "full" binary) |
| `zot_extensions_sync` | `false` | mirroring / pull-through cache |
| `zot_extensions_sync_registries` | `[]` | see the examples in README.md |
| `zot_extensions_sync_credentials_file` | `""` | e.g. "{{ zot_config_dir }}/sync-credentials.json" |
| `zot_extensions_sync_download_dir` | `""` | temporary directory used by sync (empty = zot default) |
| `zot_extensions_events` | `false` | Extensions (only effective with the "full" binary) |
| `zot_extensions_events_sinks` | `[]` | Extensions (only effective with the "full" binary) |
| `zot_extensions_extra` | `{}` | passthrough for any additional extension |
| `zot_config_extra` | `{}` | passthrough for the whole config (deep merge, highest priority) |
| `zot_service_name` | `zot` | systemd |
| `zot_service_enabled` | `true` | systemd |
| `zot_service_state` | `started` | started / stopped |
| `zot_systemd_restart` | `on-failure` | systemd |
| `zot_systemd_restart_sec` | `5` | systemd |
| `zot_systemd_timeout_stop_sec` | `120` | systemd |
| `zot_systemd_limit_nofile` | `500000` | systemd |
| `zot_systemd_memory_high` | `""` | e.g. "4G" |
| `zot_systemd_memory_max` | `""` | e.g. "6G" |
| `zot_systemd_environment` | `{}` | e.g. {GOMAXPROCS: "4"} |
| `zot_systemd_extra_options` | `{}` | e.g. {IOSchedulingClass: "best-effort"} |
| `zot_systemd_hardening` | `true` | systemd sandboxing (recommended: keep it true) |
| `zot_systemd_memory_deny_write_execute` | `false` | true only when no cgo code is used |
| `zot_systemd_extra_read_write_paths` | `[]` | extra paths for ProtectSystem=strict |
| `zot_manage_sysctl` | `false` | true = write /etc/sysctl.d/90-zot.conf and apply it |
| `zot_sysctl_settings` | `(dict/list)` | Optional OS hardening |
| `zot_manage_firewall` | `false` | true = add ufw rules (only when ufw is already active) |
| `zot_firewall_allowed_cidrs` | `[]` | e.g. ["10.0.0.0/8", "192.168.0.0/16"] |
| `zot_firewall_extra_rules` | `[]` | community.general.ufw passthrough: [{port: 9000, proto: tcp, from_ip: ...}] |
| `zot_health_check_enabled` | `true` | Post-install verification |
| `zot_health_check_address` | `""` | Empty = auto-detect: 127.0.0.1 when zot binds 0.0.0.0/::, otherwise zot_http_address. |
| `zot_health_check_path` | `/v2/` | Post-install verification |
| `zot_health_check_retries` | `12` | Post-install verification |
| `zot_health_check_delay` | `5` | Post-install verification |
| `zot_health_check_timeout` | `5` | Post-install verification |
| `zot_show_summary` | `true` | Post-install verification |
