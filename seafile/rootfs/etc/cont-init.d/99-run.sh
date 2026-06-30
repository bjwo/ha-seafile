#!/usr/bin/env bashio
# shellcheck shell=bash
# shellcheck disable=SC2155
set -e

###################################
# Export all addon options as env #
###################################

bashio::log.info "Setting variables"

JSONSOURCE="/data/options.json"

mapfile -t arr < <(jq -r 'keys[]' "${JSONSOURCE}")

for KEYS in "${arr[@]}"; do
    if [[ "${KEYS}" == "env_vars" ]]; then
        continue
    fi
    # MYSQL_* vars are resolved with correct values in the MariaDB section below
    if [[ "${KEYS}" == MYSQL_* ]]; then
        continue
    fi
    VALUE=$(jq -r ."${KEYS}" "${JSONSOURCE}")
    if [[ "${KEYS}" == *"PASS"* || "${KEYS}" == *"PASSWD"* ]]; then
        bashio::log.blue "${KEYS}=******"
    else
        bashio::log.blue "${KEYS}='${VALUE}'"
    fi
    export "${KEYS}=${VALUE}"
done

#######################################
# Apply extra environment variables   #
#######################################

if jq -e '.env_vars? | length > 0' "${JSONSOURCE}" >/dev/null; then
    bashio::log.info "Applying env_vars"
    while IFS=$'\t' read -r ENV_NAME ENV_VALUE; do
        if [[ -z "${ENV_NAME}" || "${ENV_NAME}" == "null" ]]; then
            continue
        fi
        if [[ "${ENV_NAME}" == *"PASS"* ]]; then
            bashio::log.blue "${ENV_NAME}=******"
        else
            bashio::log.blue "${ENV_NAME}=${ENV_VALUE}"
        fi
        export "${ENV_NAME}=${ENV_VALUE}"
    done < <(jq -r '.env_vars[] | [.name, .value] | @tsv' "${JSONSOURCE}")
fi

#################
# DATA_LOCATION #
#################

bashio::log.info "Setting data location"
DATA_LOCATION=$(bashio::config 'data_location')

mkdir -p "$DATA_LOCATION"

# Seafile conf lives in /config (addon_config mount, HA Supervisor backed up).
# A symlink from $DATA_LOCATION/conf keeps upstream scripts working unchanged.
if [[ ! -e "${DATA_LOCATION}/conf" ]]; then
    mkdir -p /config/conf
    ln -s /config/conf "${DATA_LOCATION}/conf"
fi

# Patch the upstream entrypoint to use DATA_LOCATION instead of /shared
sed -i "s|/shared|${DATA_LOCATION}|g" /docker_entrypoint.sh
sed -i "s|/shared|${DATA_LOCATION}|g" /home/seafile/*.sh

#####################
# Admin credentials #
#####################

ADMIN_EMAIL_VAL="$(bashio::config 'SEAFILE_ADMIN_EMAIL')"
ADMIN_PASSWORD_VAL="$(bashio::config 'SEAFILE_ADMIN_PASSWORD')"

if [[ -n "${ADMIN_EMAIL_VAL}" && "${ADMIN_EMAIL_VAL}" != "null" \
    && -n "${ADMIN_PASSWORD_VAL}" && "${ADMIN_PASSWORD_VAL}" != "null" ]]; then
    bashio::log.info "Seeding admin credentials"

    mkdir -p "${DATA_LOCATION}/conf"

    ADMIN_FILE="${DATA_LOCATION}/conf/admin.txt"
    jq -n --arg email "${ADMIN_EMAIL_VAL}" --arg password "${ADMIN_PASSWORD_VAL}" \
        '{email: $email, password: $password}' > "${ADMIN_FILE}"
    chown seafile:seafile "${ADMIN_FILE}"
    chmod 600 "${ADMIN_FILE}"

    SEAFILE_ENV_FILE="${DATA_LOCATION}/conf/seafile.env"
    touch "${SEAFILE_ENV_FILE}"
    sed -i '/^SEAFILE_ADMIN_EMAIL=/d' "${SEAFILE_ENV_FILE}"
    sed -i '/^SEAFILE_ADMIN_PASSWORD=/d' "${SEAFILE_ENV_FILE}"
    {
        printf 'SEAFILE_ADMIN_EMAIL=%s\n' "${ADMIN_EMAIL_VAL}"
        printf 'SEAFILE_ADMIN_PASSWORD=%s\n' "${ADMIN_PASSWORD_VAL}"
    } >> "${SEAFILE_ENV_FILE}"
    chown seafile:seafile "${SEAFILE_ENV_FILE}"
    chmod 600 "${SEAFILE_ENV_FILE}"
fi

#############################################
# Configure service URL and file server root #
#############################################

bashio::log.info "Configuring Seafile URLs"

SERVICE_URL_CONFIG=$(bashio::config 'url')

normalize_url() {
    local raw_url="${1%/}"
    local default_scheme="$2"
    if [[ -z "${raw_url}" || "${raw_url}" == "null" ]]; then echo ""; return; fi
    if [[ "${raw_url}" =~ ^https?:// ]]; then echo "${raw_url}"; else echo "${default_scheme}://${raw_url}"; fi
}

SERVICE_URL_VALUE=$(normalize_url "${SERVICE_URL_CONFIG}" "http")
_base=$(printf '%s' "${SERVICE_URL_VALUE}" | sed -E 's|^(https?://[^/:]+).*|\1|')
FILE_SERVER_ROOT_VALUE="${_base}:8082"

export SERVICE_URL="${SERVICE_URL_VALUE}"
export FILE_SERVER_ROOT="${FILE_SERVER_ROOT_VALUE}"

# Write into seahub_settings.py (may not exist yet on first run; written again by apply_addon_urls.sh)
for conf_dir in "${DATA_LOCATION}/conf" "${DATA_LOCATION}/seafile/conf"; do
    [[ -d "${conf_dir}" ]] || continue
    SEAHUB_SETTINGS_FILE="${conf_dir}/seahub_settings.py"
    touch "${SEAHUB_SETTINGS_FILE}"
    sed -i '/^SERVICE_URL *=/d' "${SEAHUB_SETTINGS_FILE}"
    sed -i '/^FILE_SERVER_ROOT *=/d' "${SEAHUB_SETTINGS_FILE}"
    {
        echo "SERVICE_URL = \"${SERVICE_URL_VALUE}\""
        echo "FILE_SERVER_ROOT = \"${FILE_SERVER_ROOT_VALUE}\""
    } >> "${SEAHUB_SETTINGS_FILE}"
done

bashio::log.info "SERVICE_URL set to ${SERVICE_URL_VALUE}"
bashio::log.info "FILE_SERVER_ROOT set to ${FILE_SERVER_ROOT_VALUE}"

# Re-apply URL config just before Seafile starts (upstream init may overwrite seahub_settings.py)
cat > /home/seafile/apply_addon_urls.sh << URLEOF
#!/bin/bash
for _CONF in "${DATA_LOCATION}/conf/seahub_settings.py" "${DATA_LOCATION}/seafile/conf/seahub_settings.py"; do
    [ -f "\$_CONF" ] || continue
    sed -i '/^SERVICE_URL *=/d' "\$_CONF"
    sed -i '/^FILE_SERVER_ROOT *=/d' "\$_CONF"
    printf 'SERVICE_URL = "%s"\n' "${SERVICE_URL_VALUE}" >> "\$_CONF"
    printf 'FILE_SERVER_ROOT = "%s"\n' "${FILE_SERVER_ROOT_VALUE}" >> "\$_CONF"
done
URLEOF
chmod +x /home/seafile/apply_addon_urls.sh
sed -i '/print "Launching seafile"/i /home/seafile/apply_addon_urls.sh' /home/seafile/launch.sh 2>/dev/null || true

###################
# Configure MariaDB #
###################

bashio::log.info "Configuring MariaDB"

MYSQL_HOST_CONFIG="$(bashio::config 'MYSQL_HOST' 2>/dev/null || true)"
MYSQL_PORT_CONFIG="$(bashio::config 'MYSQL_PORT' 2>/dev/null || true)"
MYSQL_USER_CONFIG="$(bashio::config 'MYSQL_USER' 2>/dev/null || true)"
MYSQL_USER_PASSWD_CONFIG="$(bashio::config 'MYSQL_USER_PASSWD' 2>/dev/null || true)"

if [[ -z "${MYSQL_USER_PASSWD_CONFIG}" || "${MYSQL_USER_PASSWD_CONFIG}" == "null" ]]; then
    if bashio::services.available 'mysql'; then
        bashio::log.info "Discovered MariaDB service — reading credentials from HA service API"
        MYSQL_USER_PASSWD_CONFIG="$(bashio::services 'mysql' 'password')"
        if [[ -z "${MYSQL_HOST_CONFIG}" || "${MYSQL_HOST_CONFIG}" == "null" ]]; then
            MYSQL_HOST_CONFIG="$(bashio::services 'mysql' 'host')"
        fi
        if [[ -z "${MYSQL_PORT_CONFIG}" || "${MYSQL_PORT_CONFIG}" == "null" ]]; then
            MYSQL_PORT_CONFIG="$(bashio::services 'mysql' 'port')"
        fi
        if [[ -z "${MYSQL_USER_CONFIG}" || "${MYSQL_USER_CONFIG}" == "null" ]]; then
            MYSQL_USER_CONFIG="$(bashio::services 'mysql' 'username')"
        fi
    else
        bashio::log.fatal "MariaDB is required. Provide MYSQL_USER_PASSWD in addon options, or install and start the MariaDB addon."
        bashio::exit.nok "No database credentials available"
    fi
fi

[[ -z "${MYSQL_HOST_CONFIG}" || "${MYSQL_HOST_CONFIG}" == "null" ]] && bashio::exit.nok "MYSQL_HOST is required"
[[ -z "${MYSQL_USER_CONFIG}" || "${MYSQL_USER_CONFIG}" == "null" ]] && bashio::exit.nok "MYSQL_USER is required"

MYSQL_HOST_IPV4="$(getent ahostsv4 "${MYSQL_HOST_CONFIG}" 2>/dev/null | awk '{print $1; exit}')"
MYSQL_HOST_RESOLVED="${MYSQL_HOST_IPV4:-${MYSQL_HOST_CONFIG}}"
[[ "${MYSQL_HOST_RESOLVED}" != "${MYSQL_HOST_CONFIG}" ]] && \
    bashio::log.info "Resolved ${MYSQL_HOST_CONFIG} -> ${MYSQL_HOST_RESOLVED} (forcing IPv4)"

MYSQL_PORT_RESOLVED="${MYSQL_PORT_CONFIG:-3306}"

export MYSQL_HOST="${MYSQL_HOST_RESOLVED}"
export MYSQL_PORT="${MYSQL_PORT_RESOLVED}"
export MYSQL_USER="${MYSQL_USER_CONFIG}"
export MYSQL_USER_PASSWD="${MYSQL_USER_PASSWD_CONFIG}"
# Reuse user password for root — databases are pre-created manually
export MYSQL_ROOT_PASSWD="${MYSQL_USER_PASSWD_CONFIG}"

# Fix wait_for_db.sh to authenticate with the configured user
sed -i 's|port=${MYSQL_PORT})|port=${MYSQL_PORT}, user="${MYSQL_USER}")|g' /home/seafile/wait_for_db.sh

# Seafile setup scripts default to connecting as "root" to create databases.
# Since databases are pre-created manually, patch them to use MYSQL_USER instead,
# which has full grants on the three Seafile databases and allows remote connections.
sed -i "s|user=\"root\"|user=\"${MYSQL_USER_CONFIG}\"|g" /home/seafile/clean_db.sh
sed -i "s|'root'|'${MYSQL_USER_CONFIG}'|g" /opt/seafile/*/setup-seafile-mysql.sh 2>/dev/null || true
sed -i "s|'root'|'${MYSQL_USER_CONFIG}'|g" /opt/seafile/*/setup-seafile-mysql.py 2>/dev/null || true

bashio::log.info "MariaDB configured: ${MYSQL_USER}@${MYSQL_HOST_RESOLVED}:${MYSQL_PORT_RESOLVED}"
bashio::log.warning "This addon uses an external MariaDB database."
bashio::log.warning "Ensure the database is included in your Home Assistant backups."

##############
# LAUNCH APP #
##############

bashio::log.info "Starting app"
/./docker_entrypoint.sh launch
