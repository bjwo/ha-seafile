# Home Assistant Add-on: Seafile

High performance file syncing and sharing, with also Markdown WYSIWYG editing, Wiki, file label and other knowledge management features.

## Installation

1. Add this repository to your Home Assistant Supervisor:
   `https://github.com/bjwo/ha-seafile`
2. Find the **Seafile** add-on and click Install.
3. Configure the required options (see below).
4. Start the add-on.
5. Open the web UI on port `8000` (Seahub).

Default credentials on first start: `me@example.com` / `a_very_secret_password` — change these immediately.

## Database requirement

**SQLite is not supported.** Seafile requires a MariaDB database. You must set one up before starting this add-on.

### Option A — Home Assistant MariaDB add-on (recommended)

1. Install and start the **MariaDB** add-on from the official Home Assistant add-on store.

2. In the MariaDB add-on, go to **Configuration** and create the databases and user that Seafile needs. Add the following under `databases` and `logins`:

   ```yaml
   databases:
     - ccnet_db
     - seafile_db
     - seahub_db
   logins:
     - username: seafile
       password: a_strong_password
   rights:
     - username: seafile
       host: "%"
       database: "*"
       grant: true
   ```

   The `database: "*"` (ALL PRIVILEGES ON \*.\*) is required because Seafile's setup script queries `mysql.user` to verify the database user exists. The MariaDB addon port is only reachable by other addons on the same HA instance — it is not exposed externally.

3. In the Seafile add-on configuration set:
   - `MYSQL_HOST`: `core-mariadb`
   - `MYSQL_PORT`: `3306`
   - `MYSQL_USER`: `seafile`
   - `MYSQL_USER_PASSWD`: the password you set above

   If you leave `MYSQL_USER_PASSWD` empty, the add-on will try to auto-discover credentials from the HA MariaDB service API.

### Option B — External MariaDB server

Provide the connection details explicitly in the add-on configuration:

| Option | Description |
|---|---|
| `MYSQL_HOST` | Hostname or IP of your MariaDB server |
| `MYSQL_PORT` | Port (default `3306`) |
| `MYSQL_USER` | Database user for Seafile |
| `MYSQL_USER_PASSWD` | Password for the Seafile database user |
| `MYSQL_ROOT_PASSWD` | Password for the MariaDB root/admin user (used during first-time setup) |

Create the three databases (`ccnet_db`, `seafile_db`, `seahub_db`) and grant the Seafile user full privileges on them before starting the add-on.

## Configuration options

| Option | Required | Default | Description |
|---|---|---|---|
| `url` | Yes | `seafile.example.com` | Public URL of your Seafile instance (e.g. `https://files.example.com`). Used as `SERVICE_URL`. `FILE_SERVER_ROOT` is auto-derived from this on port 8082. |
| `SEAFILE_ADMIN_EMAIL` | Yes | `me@example.com` | Admin account email |
| `SEAFILE_ADMIN_PASSWORD` | Yes | `a_very_secret_password` | Admin account password |
| `MYSQL_HOST` | Yes | `core-mariadb` | MariaDB hostname |
| `MYSQL_PORT` | No | `3306` | MariaDB port |
| `MYSQL_USER` | Yes | `seafile` | MariaDB username |
| `MYSQL_USER_PASSWD` | Yes* | _(empty)_ | MariaDB user password (*auto-discovered if HA MariaDB addon is running) |
| `data_location` | Yes | `/share/seafile` | Path where Seafile synced data is stored |
| `TZ` | No | `Europe/Paris` | Timezone |

## Add-on configuration files

Addon configuration files (Seafile conf, admin credentials, etc.) are stored in the addon's dedicated config folder, accessible on the host at `/addon_configs/759fb640_seafile/` (or `local_seafile` for a locally installed addon). Inside the container this is mounted at `/config`. This folder is included in Home Assistant Supervisor backups automatically.

Synced file data is stored separately in `data_location` (default `/share/seafile`).

## Network ports

| Port | Description |
|---|---|
| `8000/tcp` | Seahub web interface |
| `8082/tcp` | File server (seaf-server) |

## Backup

The add-on stores all Seafile data in `data_location` (default `/share/seafile`). Include this path in your Home Assistant backups. If you use the MariaDB add-on, ensure that add-on is also included in your backups — uninstalling it will delete all database data.

## Support

Issues and pull requests: https://github.com/bjwo/ha-seafile
