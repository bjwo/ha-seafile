ARG BUILD_FROM
FROM $BUILD_FROM

ARG BASHIO_VERSION=1.29.1

##############
# S6 & Envs  #
##############

ENV S6_STAGE2_HOOK=/ha_entrypoint.sh \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_SERVICES_GRACETIME=3000 \
    LANG=C.UTF-8

################
# Install apps #
################

# Copy rootfs files
COPY rootfs /

# Install additional packages and bashio
RUN \
    # Create symlinks for shell compatibility
    ln -s /bin/bash /usr/bin/bash 2>/dev/null || true && \
    ln -s /bin/sh /usr/bin/sh 2>/dev/null || true && \
    # Download addon infrastructure modules
    curl -fsSL "https://raw.githubusercontent.com/alexbelgium/hassio-addons/master/.templates/ha_entrypoint.sh" \
        -o /ha_entrypoint.sh && chmod +x /ha_entrypoint.sh && \
    curl -fsSL "https://raw.githubusercontent.com/alexbelgium/hassio-addons/master/.templates/ha_entrypoint_helper.sh" \
        -o /ha_entrypoint_helper.sh && chmod +x /ha_entrypoint_helper.sh && \
    # Install bashio standalone
    mkdir -p /usr/lib/bashio && \
    curl -fsSL "https://github.com/hassio-addons/bashio/archive/refs/tags/v${BASHIO_VERSION}.tar.gz" \
        | tar -xzf - --strip-components=2 -C /usr/lib/bashio bashio-${BASHIO_VERSION}/lib && \
    ln -sf /usr/lib/bashio/bashio /usr/bin/bashio

##############
# Entrypoint #
##############

CMD ["/ha_entrypoint.sh"]

##################
# Labels         #
##################

ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION

LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION} \
    maintainer="bjwo" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
    org.opencontainers.image.vendor="bjwo ha-seafile" \
    org.opencontainers.image.authors="bjwo" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/bjwo/ha-seafile" \
    org.opencontainers.image.source="https://github.com/bjwo/ha-seafile" \
    org.opencontainers.image.documentation="https://github.com/bjwo/ha-seafile/blob/main/seafile/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}
