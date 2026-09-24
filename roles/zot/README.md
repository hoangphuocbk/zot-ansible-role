# Role `zot`

Installs **zot**, an OCI-native container registry, on **Ubuntu 24.04** using the official binary +
systemd, HTTP only for internal use.

* Full configuration variables (commented): [`defaults/main.yml`](defaults/main.yml)
* Usage guide, examples, variable tables, security: [`../../README.md`](../../README.md)
* Operations (upgrade, backup, troubleshooting, uninstall): [`../../docs/OPERATIONS.md`](../../docs/OPERATIONS.md)

## Requirements

* Ubuntu 24.04 (VM/bare metal) + systemd, a user with `sudo`.
* `ansible-core >= 2.15`.
* The `community.general` collection **only when** using `zot_auth_users` (htpasswd) or
  `zot_manage_firewall` (ufw).

## Minimal example

```yaml
- hosts: zot_servers
  become: true
  roles:
    - role: zot
      vars:
        zot_version: "2.1.21"
        zot_http_port: 5000
        zot_data_dir: /var/lib/zot
        zot_log_dir: /var/log/zot
        zot_auth_enabled: true
        zot_auth_users:
          - {name: admin, password: "{{ vault_zot_admin_password }}"}
```

## Execution order

`preflight` → `user` (account + directories) → `install_binary` (url/local + checksum) →
`auth` (htpasswd) → `configure` (render + `zot verify`) → `service` (unit + enable/start) →
`hardening` (sysctl/ufw) → `logging` (logrotate) → `flush_handlers` → `verify` (active + HTTP).

Tags: `zot:preflight`, `zot:user`, `zot:install`, `zot:auth`, `zot:config`, `zot:service`,
`zot:hardening`, `zot:logging`, `zot:verify`.

## Design notes

* **TLS is not enabled**: the role is HTTP only; TLS should be terminated at a reverse proxy
  (see README section 7).
* The config is rendered **idempotently** (JSON keys sorted) and validated with `zot verify` before
  being written.
* The `zot` user is created with `create_home: false` and the `nologin` shell; `become_user: zot` is
  **not** used for Ansible tasks (there is no home directory to hold remote_tmp).
* `zot_config_extra` allows a deep merge of any key beyond the built-in variables (escape hatch).
* Multiple instances on the same host: change `zot_service_name`, `zot_http_port`, `zot_config_dir`,
  `zot_data_dir`, `zot_log_dir` (the unit/logrotate/sysctl files are all named after
  `zot_service_name`).
