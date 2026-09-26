# Ansible role: zot OCI registry (binary + systemd)

This role installs **[zot](https://zotregistry.dev/)** – an OCI-native container registry – on
**Ubuntu 24.04** (VM or bare metal) using the **official binary + systemd**, HTTP only for internal use.

Based on the official documentation:
[Installing zot on Bare Metal Linux (v2.1.21)](https://zotregistry.dev/v2.1.21/install-guides/install-guide-linux/#registry-synchronization)
and [Configuring zot](https://zotregistry.dev/v2.1.21/admin-guide/admin-configuration/).

---

## 1. Features

| Group | Details |
| --- | --- |
| Binary source | `url` (GitHub Releases or an internal mirror, with auth headers) **or** `local` (copy a file already present on the Ansible controller) |
| Integrity | Automatically downloads the release `checksums.sha256.txt`, auto-detects the correct SHA256 for the asset/arch, fails when verification is impossible (can be disabled) |
| systemd | Dedicated service, `Restart=on-failure`, `LimitNOFILE`, `MemoryHigh/MemoryMax`, **sandbox hardening** (ProtectSystem, SystemCallFilter, capability drop…); zot always binds its own unprivileged port (>= 1024) |
| Flexible configuration | Port, bind address, data dir, log dir (journald or file), realm, timeouts, compat, rate limit, access control, scheduler |
| Security | Non-login system user, minimal file permissions, htpasswd (bcrypt), `failDelay` against brute force, optional ufw, warning when exposing the registry without auth |
| Storage | Configurable `rootDirectory`, dedupe, garbage collection (`gcDelay`/`gcInterval`/`gcTimeWindow`), `commit`, `maxRepos`, retention policies, S3/GCS passthrough |
| Extensions | search (+CVE/Trivy), ui, metrics (Prometheus), scrub, lint, trust (cosign/notation), sync/mirror (pull-through cache), events |
| Operations | `zot verify` before writing the config (validated inside `template`), HTTP health check after start, logrotate when logging to file, `backup` of config/binary, idempotent (re-runs report `changed=0`) |
| Quality | `ansible-lint` (production profile), `yamllint`, test playbook running on localhost |

---

## 2. Requirements

* **Target**: Ubuntu 24.04 LTS (noble), VM or bare metal, with systemd; a user with `sudo`.
* **Controller**: `ansible-core >= 2.15`.
* **Optional collections** (only needed when the corresponding feature is enabled):

  ```bash
  ansible-galaxy collection install -r requirements.yml
  ```

  * `community.general.htpasswd` → when `zot_auth_enabled: true` **and** `zot_auth_users` is defined
    (the role installs `python3-passlib` on the target itself).
  * `community.general.ufw` → when `zot_manage_firewall: true`.

* **Resources**: the `full` zot build is quite large (~229 MB extracted for v2.1.21) and the CVE scan
  extension needs extra CPU/RAM/`/tmp` for the Trivy DB. If you only need a plain registry, use
  `zot_binary_variant: minimal`.

---

## 3. Structure

```text
.
├── ansible.cfg                  # sample ansible config (roles_path, pipelining...)
├── inventory.ini                # sample inventory (zot_servers group + localhost test group)
├── install-zot.yml              # installation playbook (used for real environments)
├── requirements.yml             # optional collections
├── Makefile                     # make lint / syntax / test
├── group_vars/all/vault.yml.example
├── docs/OPERATIONS.md           # day-2 operations: upgrade, backup, troubleshoot, uninstall
├── tests/
│   ├── inventory.yaml
│   ├── install-zot-online.yaml          # test: download the binary from the Internet
│   └── install-zot-airgap.yaml          # test: install a pre-downloaded local binary
└── roles/zot/
    ├── defaults/main.yml        # all configuration variables (fully commented)
    ├── vars/main.yml            # internal constants + computed values
    ├── tasks/
    │   ├── main.yml             # execution order
    │   ├── preflight.yml        # input validation, security warnings
    │   ├── user.yml             # system user/group + directories
    │   ├── install_binary.yml   # download/copy binary + checksum verification
    │   ├── auth.yml             # htpasswd (users or a pre-built file)
    │   ├── configure.yml        # render config.json + `zot verify`
    │   ├── service.yml          # systemd service + enable/start
    │   ├── hardening.yml        # sysctl + ufw (optional)
    │   ├── logging.yml          # logrotate (optional)
    │   └── verify.yml           # service active + HTTP health check + summary
    ├── templates/
    │   ├── zot-config.json.j2
    │   ├── zot.service.j2
    │   └── zot.logrotate.j2
    ├── handlers/main.yml
    └── meta/main.yml
```

---

## 4. Quickstart

```bash
# 1) Edit the inventory: add real hosts to the [zot_servers] group
vi inventory.ini

# 2) (optional) install collections + preview the changes
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.ini install-zot.yml --check --diff

# 3) Install, pass the admin password via vault/extra-vars (never hard-code it)
ansible-playbook -i inventory.ini install-zot.yml -e zot_admin_password='...'
```

Run it right away on the local machine (test VM) without editing the inventory:

```bash
ansible-playbook -i inventory.ini install-zot.yml -e zot_target_hosts=zot_servers_test
```

Two test playbooks are provided:

* **Online** — downloads the binary from the release URL (htpasswd auth, journald,
  metrics, GC/dedupe):

  ```bash
  ansible-playbook -i tests/inventory.yaml tests/install-zot-online.yaml
  ```

* **Air-gap** — installs a binary that is already present on the controller (no
  Internet on the target; file logging, logrotate, pre-built htpasswd, local
  checksum verification). Pass the path with `-e zot_test_local_binary=...`
  (defaults to `/tmp/zot-test-local-binary`):

  ```bash
  ansible-playbook -i tests/inventory.yaml tests/install-zot-airgap.yaml \
    -e zot_test_local_binary=/path/to/zot-linux-amd64
  ```

Both accept `--check --diff` for a dry-run.

At the end of the play a summary is printed:

```text
zot binary    : /usr/local/bin/zot (full, v2.1.21)
zot config    : /etc/zot/config.json
Registry data : /var/lib/zot
Logs          : journalctl -u zot
HTTP endpoint : http://0.0.0.0:5000 (realm=zot-internal)
Auth          : htpasswd (/etc/zot/htpasswd)
Registry URL  : http://10.0.0.11:5000
```

Test push:

```bash
docker tag alpine 10.0.0.11:5000/alpine:test
docker login 10.0.0.11:5000 -u admin          # if auth is enabled
docker push 10.0.0.11:5000/alpine:test
curl -u admin:... http://10.0.0.11:5000/v2/_catalog
```

> Docker only allows HTTPS registries by default. For internal HTTP, add
> `"insecure-registries": ["10.0.0.11:5000"]` to `/etc/docker/daemon.json` and restart docker
> (or use `skopeo --tls-verify=false`, `crane --insecure`).

---

## 5. Key configuration variables

Every variable is documented in detail in [`roles/zot/defaults/main.yml`](roles/zot/defaults/main.yml).
The full list grouped by category is in
[docs/OPERATIONS.md](docs/OPERATIONS.md#appendix-full-variable-list).

### 5.1 Binary & version

| Variable | Default | Meaning |
| --- | --- | --- |
| `zot_version` | `2.1.21` | Release version (also accepts `v2.1.21`) |
| `zot_binary_variant` | `full` | `full` \| `minimal` \| `debug` |
| `zot_binary_source` | `url` | `url` \| `local` |
| `zot_binary_dest` | `/usr/local/bin/zot` | Binary path on the target |
| `zot_download_url` | GitHub Releases | Override with an internal mirror if needed |
| `zot_download_url_headers` | `{}` | Headers for a private mirror (token) |
| `zot_verify_checksum` | `true` | Require SHA256 verification (recommended: keep it) |
| `zot_binary_checksum` | `""` | Specify `sha256:<hex>` manually when checksums cannot be downloaded |
| `zot_local_binary_path` | `""` | File on the **controller** when `source=local` |
| `zot_local_binary_checksum` | `""` | SHA256 of the local file (optional, recommended) |
| `zot_force_update` | `false` | `true` = replace the binary even when the checksum is unchanged |

### 5.2 Port / directories / logs

| Variable | Default |
| --- | --- |
| `zot_http_address` | `0.0.0.0` (consider changing it to an internal IP) |
| `zot_http_port` | `5000` (unprivileged port, 1024-65535; lower ports are rejected) |
| `zot_http_realm` | `zot` |
| `zot_data_dir` | `/var/lib/zot` |
| `zot_log_dir` | `/var/log/zot` |
| `zot_log_output` | `journald` (or `file` → uses `zot_log_file` and enables logrotate) |
| `zot_log_level` | `info` (`debug`/`info`/`warn`/`error`) |
| `zot_log_audit_file` | `/var/log/zot/zot-audit.log` (`""` to disable) |

### 5.3 Security

| Variable | Default | Notes |
| --- | --- | --- |
| `zot_auth_enabled` | `false` | Enables htpasswd basic auth |
| `zot_auth_users` | `[]` | `[{name: admin, password: "..."}]` – use ansible-vault |
| `zot_auth_htpasswd_hash_scheme` | `bcrypt` | Matches zot's recommended `htpasswd -B` |
| `zot_auth_fail_delay` | `5` | Delay in seconds after a failed auth |
| `zot_auth_purge_other_users` | `false` | Keep only the declared users |
| `zot_http_access_control` | `{}` | Passthrough for `adminPolicy` / `repositories` / `groups` / `metrics` |
| `zot_manage_firewall` | `false` | Add a ufw rule (only when ufw is active) |
| `zot_firewall_allowed_cidrs` | `[]` | Example `["10.0.0.0/8"]` |

### 5.4 Storage / tuning

| Variable | Default | Notes |
| --- | --- | --- |
| `zot_storage_dedupe` | `true` | Saves disk space |
| `zot_storage_gc` | `true` | Inline GC, no offline run needed |
| `zot_storage_gc_delay` / `zot_storage_gc_interval` | `1h` / `6h` | |
| `zot_storage_gc_time_window` | `""` | Example `"02:00-04:00"` to run GC outside peak hours |
| `zot_storage_commit` | `false` | `true` = flush immediately (safer, slower) |
| `zot_storage_max_repos` | `0` | `0` = unlimited |
| `zot_storage_retention` | `{}` | Passthrough policy (use `dryRun: true` first) |
| `zot_scheduler_num_workers` | `0` | `0` = zot default (4 × CPU) |
| `zot_manage_sysctl` | `false` | Write `/etc/sysctl.d/90-<service>.conf` and run `sysctl --system` |

### 5.5 systemd

| Variable | Default |
| --- | --- |
| `zot_service_name` | `zot` |
| `zot_systemd_limit_nofile` | `500000` |
| `zot_systemd_memory_high` / `memory_max` | `""` (e.g. `4G` / `6G`) |
| `zot_systemd_hardening` | `true` (systemd sandboxing) |
| `zot_systemd_memory_deny_write_execute` | `false` (enable only if you are sure no cgo code is used) |
| `zot_systemd_extra_read_write_paths` | `[]` (extra paths for `ProtectSystem=strict`) |
| `zot_systemd_extra_options` | `{}` (add extra `[Service]` directives) |

---

## 6. Configuration examples

### 6.1 Using a binary already available on the controller (air-gapped)

```yaml
zot_binary_source: local
zot_local_binary_path: "{{ playbook_dir }}/files/zot-linux-amd64"
zot_local_binary_checksum: "sha256:8751cc0daf739634835a3bd8206e3094c84d552e2c462e4a4baf80f40dd92685"
```

The role runs `sha256sum` on the file on the controller, compares it, and only then `copy`s it to the
target (idempotent based on content).

### 6.2 Internal mirror instead of GitHub

```yaml
zot_download_url: "https://nexus.internal/repository/raw/zot/zot-linux-amd64"
zot_checksums_url: "https://nexus.internal/repository/raw/zot/checksums.sha256.txt"
zot_download_url_headers:
  Authorization: "Bearer {{ nexus_token }}"
```

### 6.3 Auth + authorization

```yaml
zot_auth_enabled: true
zot_auth_users:
  - {name: admin, password: "{{ vault_zot_admin_password }}"}
  - {name: ci, password: "{{ vault_zot_ci_password }}"}
zot_auth_purge_other_users: true
zot_http_access_control:
  adminPolicy:
    users: ["admin"]
    actions: ["read", "create", "update", "delete"]
  repositories:
    "**":
      defaultPolicy: ["read"]
      anonymousPolicy: []
    "ci/**":
      policies:
        - users: ["ci"]
          actions: ["read", "create", "update"]
  metrics:
    users: ["admin"]
```

### 6.4 Metrics for Prometheus

```yaml
zot_extensions_metrics: true
zot_extensions_metrics_path: /metrics
# scrape_configs:
#   - job_name: zot
#     static_configs: [{targets: ["10.0.0.11:5000"]}]
```

When auth is enabled, grant access to the metrics endpoint via `zot_http_access_control.metrics`.

### 6.5 Mirror / pull-through cache (registry synchronization)

```yaml
zot_extensions_sync: true
zot_extensions_sync_registries:
  # Docker Hub pull-through cache: the first pull is fetched and cached by zot
  - urls: ["https://registry-1.docker.io"]
    onDemand: true
    maxRetries: 3
    retryDelay: "5m"
    pollInterval: "6h"
  # Periodically mirror another internal registry
  - urls: ["https://registry.internal"]
    onDemand: false
    pollInterval: "1h"
    content:
      - prefix: "team-a/"
        destination: "/mirror/team-a/"
        stripPrefix: true
```

If you need to preserve the Docker image digest (so cosign/notation signatures remain valid), add:

```yaml
zot_http_compat: ["docker2s2"]
zot_extensions_sync_registries:
  - urls: ["https://registry-1.docker.io"]
    onDemand: true
    preserveDigest: true    # requires http.compat
```

### 6.6 Retention (cleaning up old images)

```yaml
zot_storage_retention:
  dryRun: true            # dry run first, check the logs, then set it to false
  delay: "24h"
  policies:
    - repositories: ["ci/**"]
      deleteUntagged: true
      keepTags:
        - patterns: ["^v.*"]
          mostRecentlyPushedCount: 10
```

### 6.7 Quickly change port / data dir / log dir

```yaml
zot_http_port: 8080
zot_data_dir: /data/zot
zot_log_dir: /data/log/zot
zot_log_output: file
zot_log_level: warn
```

The role creates the directories, sets `zot:zot 0750` permissions, adds them to the unit's
`ReadWritePaths` and configures logrotate. `zot_http_port` must be an unprivileged port
(1024-65535), because the service runs as a non-root user without any extra capability;
the role rejects privileged ports (< 1024) during preflight.

---

## 7. Security when using HTTP only on an internal network

zot here does **not enable TLS** (exactly as required: "HTTP only, for internal use"). Therefore:

1. **Bind to the internal network only**: set `zot_http_address` to an internal IP instead of `0.0.0.0`,
   or block at the firewall (`zot_manage_firewall: true` + `zot_firewall_allowed_cidrs`).
2. **Always enable auth** (`zot_auth_enabled: true`) when several people/systems access it – the role
   warns when it sees `0.0.0.0` without auth.
3. **If you need HTTPS**, put a reverse proxy (nginx/traefik) in front, terminate TLS and proxy to
   `http://127.0.0.1:5000`; set `zot_http_address: 127.0.0.1` and `zot_http_external_url`.
4. Basic auth over HTTP does **not encrypt** credentials – only use it on a trusted network.
5. The service runs as a dedicated user, with systemd sandboxing, config `0640 root:zot`, htpasswd
   `0640 root:zot`.

---

## 8. Verification & idempotency

* `template` calls `zot verify %s` before writing `config.json` → a config that fails the schema fails
  immediately and the previous file is kept.
* After start, the role checks `systemctl is-active` and issues an HTTP `GET /v2/` (accepts `200` or
  `401` when auth is enabled).
* The health check address is inferred automatically: binding `0.0.0.0`/`::` → check `127.0.0.1`;
  binding a specific IP → check that exact IP (override with `zot_health_check_address`).
* Re-running the playbook a second time must report `changed=0` (the test checks this).

```bash
# manual check on the target
sudo -u zot /usr/local/bin/zot verify /etc/zot/config.json
systemctl status zot
journalctl -u zot -n 100 --no-pager
curl -i http://127.0.0.1:5000/v2/
```

---

## 9. Day-2 operations

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md): version upgrades, binary/config rollback, storage backup
& restore, GC/retention, monitoring, common troubleshooting and uninstallation.

---

## 10. Development / testing

```bash
make lint      # ansible-lint + yamllint
make syntax    # syntax-check the playbooks
make test      # run both role tests (online + air-gap; requires sudo)
make test-online  # run only tests/install-zot-online.yaml
make test-airgap  # run only tests/install-zot-airgap.yaml
make check     # dry-run the installation playbook
```

---

## 11. References

* [Installing zot on Bare Metal Linux](https://zotregistry.dev/v2.1.21/install-guides/install-guide-linux/)
* [Configuring zot](https://zotregistry.dev/v2.1.21/admin-guide/admin-configuration/)
* [Registry synchronization / Mirroring](https://zotregistry.dev/v2.1.21/articles/mirroring/)
* [Authentication and Authorization](https://zotregistry.dev/v2.1.21/articles/authn-authz/)
* [Storage planning](https://zotregistry.dev/v2.1.21/articles/storage/) · [Retention](https://zotregistry.dev/v2.1.21/articles/retention/) · [Monitoring](https://zotregistry.dev/v2.1.21/articles/monitoring/)
* [zot releases & binary assets](https://github.com/project-zot/zot/releases)
* [Config JSON schema](https://github.com/project-zot/zot/releases/download/v2.1.21/zot-schema.json)
