

.PHONY: install
install:
	make -C Auth install
	install -D -m 0644 AccessControl.pm ${DESTDIR}${PERLDIR}/PVE/AccessControl.pm
	install -D -m 0644 RPCEnvironment.pm ${DESTDIR}${PERLDIR}/PVE/RPCEnvironment.pm
	install -D -m 0644 DuoSecurity.pm ${DESTDIR}${PERLDIR}/PVE/DuoSecurity.pm
	make -C API2 install