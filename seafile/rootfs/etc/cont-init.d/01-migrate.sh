#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -e

# Migration: move Seafile conf directory from $DATA_LOCATION/conf (old, not backed up)
# to /config/conf (addon_config mount, included in HA Supervisor backups).
# A symlink $DATA_LOCATION/conf -> /config/conf is left in place so the upstream
# Seafile scripts continue to find their config without any further patching.
#
# Idempotency guard: we only act when DATA_LOCATION/conf is a real directory,
# not already a symlink. On success it is renamed to conf_migrated.

DATA_LOCATION="$(bashio::config 'data_location')"
OLD_CONF="${DATA_LOCATION}/conf"
NEW_CONF="/config/conf"
MIGRATED_MARKER="${DATA_LOCATION}/conf_migrated"

_has_seafile_conf() {
    local dir="$1"
    [[ -f "${dir}/seafile.conf" ]] \
        || [[ -f "${dir}/seahub_settings.py" ]] \
        || [[ -f "${dir}/ccnet.conf" ]]
}

if [[ -d "${OLD_CONF}" && ! -L "${OLD_CONF}" ]] && _has_seafile_conf "${OLD_CONF}"; then

    bashio::log.warning "======================================================"
    bashio::log.warning " SEAFILE CONFIG MIGRATION"
    bashio::log.warning "======================================================"
    bashio::log.warning "Moving ${OLD_CONF} -> ${NEW_CONF}"
    bashio::log.warning "A symlink will be left in place for the upstream service."
    bashio::log.warning "Old directory preserved as: ${MIGRATED_MARKER}"
    bashio::log.warning "======================================================"

    mkdir -p "${NEW_CONF}"

    if ! cp -an "${OLD_CONF}/." "${NEW_CONF}/"; then
        bashio::log.fatal "Migration copy failed. ${OLD_CONF} is untouched."
        bashio::exit.nok "Failed to migrate conf from ${OLD_CONF} to ${NEW_CONF}"
    fi

    mv "${OLD_CONF}" "${MIGRATED_MARKER}"
    ln -s "${NEW_CONF}" "${OLD_CONF}"

    bashio::log.info "Migration complete. Restarting addon."
    sleep 3
    bashio::addon.restart

elif [[ -L "${OLD_CONF}" ]]; then
    bashio::log.info "Config symlink already in place (${OLD_CONF} -> ${NEW_CONF}), no migration needed."

elif [[ ! -d "${OLD_CONF}" ]]; then
    # Fresh install — symlink will be created by 99-run.sh before first use.
    bashio::log.info "No existing conf directory found, fresh install."
fi
