# Changelog

## 12.0.18-6

### Changes

- Removed `SERVER_IP` option — redundant now that `url` is required.
- `FILE_SERVER_ROOT` is now optional; when omitted it is auto-derived from `url` by replacing the port with the value of `PORT` (default `8082`). Set it explicitly only if your file server is reachable at a different host or URL.
- Fixed `MYSQL_*` env vars being injected with empty values before the MariaDB credential resolution runs, causing Seafile's init script to see blank passwords.


### Breaking changes

- **SQLite is no longer supported.** MariaDB is now mandatory. See the README for setup instructions.

### Automatic config migration

If you are upgrading from a previous version, Seafile's configuration directory was stored inside `data_location` (`/share/seafile/conf/`). On first start this addon automatically migrates it:

1. The contents of `$data_location/conf/` are copied to `/config/conf/` (the addon's dedicated backup folder).
2. The old directory is renamed to `$data_location/conf_migrated/` — preserved as a manual backup.
3. A symlink `$data_location/conf -> /config/conf` is created so the upstream Seafile service is unaffected.
4. The addon restarts automatically.

No manual action is required. Once you have verified everything works you may delete `conf_migrated/`.

- **Explicit MariaDB credentials** (`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_USER_PASSWD`, `MYSQL_ROOT_PASSWD`) can now be set directly in the addon configuration, removing the dependency on the HA MariaDB addon service API. If password fields are left empty, credentials are still auto-discovered from the HA MariaDB addon as before.
- Addon configuration files are now stored in the addon's dedicated config folder (`/config` inside the container, accessible on the host at `/addon_configs/759fb640_seafile/`), consistent with current HA addon standards. Synced file data continues to live in `data_location` (default `/share/seafile`).

### Removed

- `database` option (`sqlite` / `mariadb_addon`) — MariaDB is now the only supported backend.
