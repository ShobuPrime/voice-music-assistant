################################################################################
#
# nqptp
#
# Not Quite PTP - PTP timing helper daemon required by shairport-sync 4+
# for AirPlay 2 group synchronization. Listens on UDP 319/320 and writes
# shared memory consumed by shairport-sync.
#
################################################################################

NQPTP_VERSION = 1.2.7
NQPTP_SITE = $(call github,mikebrady,nqptp,$(NQPTP_VERSION))
NQPTP_LICENSE = GPL-2.0+
NQPTP_LICENSE_FILES = COPYING
NQPTP_AUTORECONF = YES

NQPTP_CONF_OPTS = \
	--with-systemd-startup=no

$(eval $(autotools-package))
