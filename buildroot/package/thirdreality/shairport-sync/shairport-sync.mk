################################################################################
#
# shairport-sync
#
# AirPlay 2 audio receiver. Built with the PulseAudio backend so that
# AirPlay streams sequence with sendspin-client and the voice TTS layer
# on the same default sink. Requires the companion nqptp daemon for AP2
# group synchronization (see buildroot/package/thirdreality/nqptp).
#
# The runtime config (shairport-sync.conf) is owned by the integrator
# layer and shipped from this package directory; tunables there are
# documented in doc/airplay-cast-plan.md §6, §9.
#
################################################################################

SHAIRPORT_SYNC_VERSION = 5.0.4
SHAIRPORT_SYNC_SITE = $(call github,mikebrady,shairport-sync,$(SHAIRPORT_SYNC_VERSION))
SHAIRPORT_SYNC_LICENSE = GPL-2.0+
SHAIRPORT_SYNC_LICENSE_FILES = COPYING
SHAIRPORT_SYNC_AUTORECONF = YES

SHAIRPORT_SYNC_DEPENDENCIES = \
	pulseaudio \
	avahi \
	openssl \
	libsoxr \
	libplist \
	libsodium \
	popt \
	libgcrypt \
	nqptp

SHAIRPORT_SYNC_CONF_OPTS = \
	--with-pa \
	--with-avahi \
	--with-airplay-2 \
	--with-ssl=openssl \
	--with-soxr \
	--with-metadata \
	--with-systemd=no \
	--with-stdout=no \
	--with-pipe=no \
	--sysconfdir=/etc

# Install our runtime config (owned by the integrator) to /etc.
# Mirrors the SENDSPIN_CLIENT_INSTALL_AVAHI_SERVICE pattern.
define SHAIRPORT_SYNC_INSTALL_CONF
	$(INSTALL) -D -m 0644 $(SHAIRPORT_SYNC_PKGDIR)/shairport-sync.conf \
		$(TARGET_DIR)/etc/shairport-sync.conf
endef
SHAIRPORT_SYNC_POST_INSTALL_TARGET_HOOKS += SHAIRPORT_SYNC_INSTALL_CONF

$(eval $(autotools-package))
