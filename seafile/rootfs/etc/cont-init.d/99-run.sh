#!/usr/bin/env bashio
# shellcheck shell=bash
# shellcheck disable=SC2155,SC2016
set -e

###################################
# Export all addon options as env #
###################################

bashio::log.info "Setting variables"

# For all keys in options.json
JSONSOURCE="/data/options.json"

# Export keys as env variables
mapfile -t arr < <(jq -r 'keys[]' "${JSONSOURCE}")

for KEYS in "${arr[@]}"; do
    if [[ "${KEYS}" == "env_vars" ]]; then
        continue
    fi
    # MYSQL_* vars are handled by the MariaDB section below with the correct
    # resolved values; skip them here to avoid injecting empty values that
    # would override the real ones in the upstream shell scripts.
    if [[ "${KEYS}" == MYSQL_* ]]; then
        continue
    fi
    # export key
    VALUE=$(jq ."$KEYS" "${JSONSOURCE}")
    line="${KEYS}='${VALUE//[\"\']/}'"
    # text
    if bashio::config.false "verbose" || [[ "${KEYS}" == *"PASS"* ]] || [[ "${KEYS}" == *"PASSWD"* ]]; then
        bashio::log.blue "${KEYS}=******"
    else
        bashio::log.blue "$line"
    fi
    # Use locally
    export "${KEYS}=${VALUE//[\"\']/}"
    # Export the variable to run scripts
    sed -i "1a export $line" /home/seafile/*.sh 2> /dev/null
    find /opt/seafile -name '*.sh' -print0 | xargs -0 sed -i "1a export $line"
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

        if bashio::config.false "verbose" || [[ "${ENV_NAME}" == *"PASS"* ]]; then
            bashio::log.blue "${ENV_NAME}=******"
        else
            bashio::log.blue "${ENV_NAME}=${ENV_VALUE}"
        fi

        export "${ENV_NAME}=${ENV_VALUE}"

        ENV_VALUE_ESCAPED=$(printf "%q" "${ENV_VALUE}")
        ENV_LINE="export ${ENV_NAME}=${ENV_VALUE_ESCAPED}"
        sed -i "1a ${ENV_LINE}" /home/seafile/*.sh 2>/dev/null
        find /opt/seafile -name '*.sh' -print0 | xargs -0 sed -i "1a ${ENV_LINE}"
    done < <(jq -r '.env_vars[] | [.name, .value] | @tsv' "${JSONSOURCE}")
fi

#################
# DATA_LOCATION #
#################

bashio::log.info "Setting data location"
DATA_LOCATION=$(bashio::config 'data_location')

echo "... check $DATA_LOCATION folder exists"
mkdir -p "$DATA_LOCATION"

# Ensure Seafile conf lives in /config (addon_config mount, HA Supervisor backed up),
# with a symlink from $DATA_LOCATION/conf so upstream scripts find it unchanged.
if [[ ! -e "${DATA_LOCATION}/conf" ]]; then
    mkdir -p /config/conf
    ln -s /config/conf "${DATA_LOCATION}/conf"
fi

echo "... setting permissions"
chown -R seafile:seafile "$DATA_LOCATION"
chown -R seafile:seafile /config/conf

echo "... correcting official script"
sed -i "s|/shared|$DATA_LOCATION|g" /docker_entrypoint.sh
sed -i "s|/shared|$DATA_LOCATION|g" /home/seafile/*.sh

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

    case "${ADMIN_EMAIL_VAL}" in
        *$'\n'*|*$'\r'*)
            bashio::exit.nok "SEAFILE_ADMIN_EMAIL must not contain newlines"
            ;;
    esac

    case "${ADMIN_PASSWORD_VAL}" in
        *$'\n'*|*$'\r'*)
            bashio::exit.nok "SEAFILE_ADMIN_PASSWORD must not contain newlines"
            ;;
    esac

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

    if [[ -z "${raw_url}" || "${raw_url}" == "null" ]]; then
        echo ""
        return
    fi

    if [[ "${raw_url}" =~ ^https?:// ]]; then
        echo "${raw_url}"
    else
        echo "${default_scheme}://${raw_url}"
    fi
}

SERVICE_URL_VALUE=$(normalize_url "${SERVICE_URL_CONFIG}" "http")

# Auto-derive FILE_SERVER_ROOT: same scheme+host as url on port 8082
_base=$(printf '%s' "${SERVICE_URL_VALUE}" | sed -E 's|^(https?://[^/:]+).*|\1|')
FILE_SERVER_ROOT_VALUE="${_base}:8082"

SEAHUB_CONF_DIRS=()
if [[ -d "${DATA_LOCATION}/conf" || ! -d "${DATA_LOCATION}/seafile/conf" ]]; then
    SEAHUB_CONF_DIRS+=("${DATA_LOCATION}/conf")
fi
if [[ -d "${DATA_LOCATION}/seafile/conf" ]]; then
    SEAHUB_CONF_DIRS+=("${DATA_LOCATION}/seafile/conf")
fi
if [[ "${#SEAHUB_CONF_DIRS[@]}" -eq 0 ]]; then
    SEAHUB_CONF_DIRS+=("${DATA_LOCATION}/conf")
fi

for conf_dir in "${SEAHUB_CONF_DIRS[@]}"; do
    SEAHUB_SETTINGS_FILE="${conf_dir}/seahub_settings.py"
    mkdir -p "${conf_dir}"
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

# Inject apply_addon_urls.sh to re-apply URL config just before Seafile starts
cat > /home/seafile/apply_addon_urls.sh << URLEOF
#!/bin/bash
for _CONF in "${DATA_LOCATION}/conf/seahub_settings.py" "${DATA_LOCATION}/seafile/conf/seahub_settings.py"; do
    if [ -f "\$_CONF" ]; then
        sed -i '/^SERVICE_URL *=/d' "\$_CONF"
        sed -i '/^FILE_SERVER_ROOT *=/d' "\$_CONF"
        echo 'SERVICE_URL = "${SERVICE_URL_VALUE}"' >> "\$_CONF"
        echo 'FILE_SERVER_ROOT = "${FILE_SERVER_ROOT_VALUE}"' >> "\$_CONF"
    fi
done
URLEOF
chmod +x /home/seafile/apply_addon_urls.sh
sed -i '/print "Launching seafile"/i /home/seafile/apply_addon_urls.sh' /home/seafile/launch.sh
if ! grep -q 'apply_addon_urls.sh' /home/seafile/launch.sh 2>/dev/null; then
    bashio::log.warning "Could not inject URL configuration into launch.sh; URLs may use upstream defaults"
fi

###################
# Configure MariaDB #
###################

bashio::log.info "Configuring MariaDB"

# Read credentials from addon options
MYSQL_HOST_CONFIG="$(bashio::config 'MYSQL_HOST' 2>/dev/null || true)"
MYSQL_PORT_CONFIG="$(bashio::config 'MYSQL_PORT' 2>/dev/null || true)"
MYSQL_USER_CONFIG="$(bashio::config 'MYSQL_USER' 2>/dev/null || true)"
MYSQL_USER_PASSWD_CONFIG="$(bashio::config 'MYSQL_USER_PASSWD' 2>/dev/null || true)"

# If password is empty, try to discover credentials from the HA MariaDB addon service
if [[ -z "${MYSQL_USER_PASSWD_CONFIG}" || "${MYSQL_USER_PASSWD_CONFIG}" == "null" ]]; then

    if bashio::services.available 'mysql'; then
        bashio::log.info "Discovered MariaDB service — reading credentials from HA service API"
        MYSQL_USER_PASSWD_CONFIG="$(bashio::services 'mysql' 'password')"

        # Override host/port/user from service if not explicitly set
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
        bashio::log.fatal "MariaDB is required. Either provide MYSQL_USER_PASSWD in addon options, or install and start the MariaDB addon."
        bashio::exit.nok "No database credentials available"
    fi
fi

# MYSQL_ROOT_PASSWD is only used by Seafile's first-run setup scripts to create
# databases — since the user creates these manually, we simply reuse the user password.
MYSQL_ROOT_PASSWD_CONFIG="${MYSQL_USER_PASSWD_CONFIG}"

# Validate we have all required values
if [[ -z "${MYSQL_HOST_CONFIG}" || "${MYSQL_HOST_CONFIG}" == "null" ]]; then
    bashio::exit.nok "MYSQL_HOST is required"
fi
if [[ -z "${MYSQL_USER_CONFIG}" || "${MYSQL_USER_CONFIG}" == "null" ]]; then
    bashio::exit.nok "MYSQL_USER is required"
fi

# Resolve hostname to IPv4 to avoid IPv6 connection issues on HAOS
MYSQL_HOST_IPV4="$(getent ahostsv4 "${MYSQL_HOST_CONFIG}" 2>/dev/null | awk '{print $1; exit}')"
MYSQL_HOST_RESOLVED="${MYSQL_HOST_IPV4:-${MYSQL_HOST_CONFIG}}"
if [[ "${MYSQL_HOST_RESOLVED}" != "${MYSQL_HOST_CONFIG}" ]]; then
    bashio::log.info "Resolved ${MYSQL_HOST_CONFIG} -> ${MYSQL_HOST_RESOLVED} (forcing IPv4)"
fi

MYSQL_PORT_RESOLVED="${MYSQL_PORT_CONFIG:-3306}"

export MYSQL_HOST="${MYSQL_HOST_RESOLVED}"
export MYSQL_PORT="${MYSQL_PORT_RESOLVED}"
export MYSQL_USER="${MYSQL_USER_CONFIG}"
export MYSQL_USER_PASSWD="${MYSQL_USER_PASSWD_CONFIG}"
export MYSQL_ROOT_PASSWD="${MYSQL_ROOT_PASSWD_CONFIG}"

sed -i "1a export MYSQL_HOST=${MYSQL_HOST_RESOLVED}" /home/seafile/*.sh
sed -i "1a export MYSQL_PORT=${MYSQL_PORT_RESOLVED}" /home/seafile/*.sh
sed -i "1a export MYSQL_USER=${MYSQL_USER_CONFIG}" /home/seafile/*.sh
sed -i "1a export MYSQL_USER_PASSWD=${MYSQL_USER_PASSWD_CONFIG}" /home/seafile/*.sh
sed -i "1a export MYSQL_ROOT_PASSWD=${MYSQL_ROOT_PASSWD_CONFIG}" /home/seafile/*.sh

# Fix wait_for_db.sh to pass username
sed -i 's|port=${MYSQL_PORT})|port=${MYSQL_PORT}, user="${MYSQL_USER}")|g' /home/seafile/wait_for_db.sh

# The MariaDB addon exposes a service user called "service"; Seafile's setup scripts
# expect a "root" user. Patch the setup scripts to use the configured user instead.
sed -i 's|user="root"|user="service"|g' /home/seafile/clean_db.sh
sed -i "s|'root'|'service'|g" /opt/seafile/*/setup-seafile-mysql.sh
sed -i "s|'root'|'service'|g" /opt/seafile/*/setup-seafile-mysql.py

bashio::log.info "MariaDB configured: ${MYSQL_USER}@${MYSQL_HOST_RESOLVED}:${MYSQL_PORT_RESOLVED}"
bashio::log.warning "This addon uses an external MariaDB database."
bashio::log.warning "Ensure the database is included in your Home Assistant backups."

##############
# LAUNCH APP #
##############

bashio::log.info "Starting app"
/./docker_entrypoint.sh launch
