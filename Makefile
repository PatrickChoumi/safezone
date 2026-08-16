# blocker-adulte — placement des fichiers
#
# Ce Makefile est l'unique endroit qui decide OU va chaque fichier. install.sh et
# le paquet .deb l'utilisent tous les deux, ce qui garantit que les deux voies
# d'installation produisent exactement la meme arborescence.
#
#   make install DESTDIR=/            installation directe
#   make install DESTDIR=debian/tmp   construction du paquet
#
# Aucun fichier n'est place ailleurs que dans les chemins listes ci-dessous, et
# cette liste est reprise telle quelle dans le tableau du README.

SHELL    = /bin/sh
DESTDIR ?=

prefix      = /usr
libdir      = $(prefix)/lib/blocker-adulte
sharedir    = $(prefix)/share/blocker-adulte
docdir      = $(prefix)/share/doc/blocker-adulte
sbindir     = $(prefix)/sbin
unitdir     = /lib/systemd/system

INSTALL      = install
INSTALL_PROG = $(INSTALL) -m 0755
INSTALL_DATA = $(INSTALL) -m 0644
INSTALL_DIR  = $(INSTALL) -d -m 0755

.PHONY: all install uninstall check deb clean

all:
	@echo "Rien a compiler. Utiliser : make install DESTDIR=..."

install:
	# --- Executables et bibliotheque partagee -----------------------------
	$(INSTALL_DIR) $(DESTDIR)$(libdir)
	$(INSTALL_DATA) lib/blocker-common.sh        $(DESTDIR)$(libdir)/blocker-common.sh
	$(INSTALL_PROG) bin/blocker-configure        $(DESTDIR)$(libdir)/blocker-configure
	$(INSTALL_PROG) bin/blocker-guard            $(DESTDIR)$(libdir)/blocker-guard
	$(INSTALL_PROG) bin/blocker-resolver-run     $(DESTDIR)$(libdir)/blocker-resolver-run
	$(INSTALL_PROG) bin/blocker-selfheal         $(DESTDIR)$(libdir)/blocker-selfheal
	$(INSTALL_PROG) bin/blocker-list-update      $(DESTDIR)$(libdir)/blocker-list-update
	$(INSTALL_PROG) bin/blocker-safesearch       $(DESTDIR)$(libdir)/blocker-safesearch
	$(INSTALL_PROG) bin/blocker-upstream        $(DESTDIR)$(libdir)/blocker-upstream
	$(INSTALL_PROG) bin/blocker-doh-refresh     $(DESTDIR)$(libdir)/blocker-doh-refresh
	$(INSTALL_PROG) bin/blocker-apply-policies   $(DESTDIR)$(libdir)/blocker-apply-policies
	$(INSTALL_PROG) bin/blocker-apply-nftables   $(DESTDIR)$(libdir)/blocker-apply-nftables

	# --- Script de desinstallation, dans le PATH de root ------------------
	$(INSTALL_DIR) $(DESTDIR)$(sbindir)
	$(INSTALL_PROG) blocker-uninstall.sh         $(DESTDIR)$(sbindir)/blocker-uninstall
	$(INSTALL_PROG) bin/blocker-status           $(DESTDIR)$(sbindir)/blocker-status
	$(INSTALL_PROG) bin/blocker-update           $(DESTDIR)$(sbindir)/blocker-update

	# --- Unites systemd ----------------------------------------------------
	$(INSTALL_DIR) $(DESTDIR)$(unitdir)
	$(INSTALL_DATA) systemd/blocker-resolver.service     $(DESTDIR)$(unitdir)/
	$(INSTALL_DATA) systemd/blocker-guard.service        $(DESTDIR)$(unitdir)/
	$(INSTALL_DATA) systemd/blocker-selfheal.service     $(DESTDIR)$(unitdir)/
	$(INSTALL_DATA) systemd/blocker-selfheal.timer       $(DESTDIR)$(unitdir)/
	$(INSTALL_DATA) systemd/blocker-list-update.service  $(DESTDIR)$(unitdir)/
	$(INSTALL_DATA) systemd/blocker-list-update.timer    $(DESTDIR)$(unitdir)/

	# --- Modeles de configuration -----------------------------------------
	# Les fichiers reels dans /etc sont poses par blocker-configure, pas par
	# dpkg : cela evite qu'un fichier rendu immuable (chattr +i) bloque une
	# mise a jour ou une purge du paquet.
	$(INSTALL_DIR) $(DESTDIR)$(sharedir)/conf
	$(INSTALL_DATA) etc/dnsmasq.d/blocker-adulte.conf \
		$(DESTDIR)$(sharedir)/conf/dnsmasq-blocker-adulte.conf
	$(INSTALL_DATA) etc/nftables/blocker-adulte.nft \
		$(DESTDIR)$(sharedir)/conf/nftables-blocker-adulte.nft
	$(INSTALL_DATA) etc/nftables/blocker-adulte-tunnels.nft \
		$(DESTDIR)$(sharedir)/conf/nftables-blocker-adulte-tunnels.nft
	$(INSTALL_DATA) etc/systemd/resolved.conf.d/blocker-adulte.conf \
		$(DESTDIR)$(sharedir)/conf/resolved-blocker-adulte.conf
	$(INSTALL_PROG) etc/NetworkManager/dispatcher.d/90-blocker-adulte \
		$(DESTDIR)$(sharedir)/conf/90-blocker-adulte
	$(INSTALL_DATA) audit/blocker-adulte.rules \
		$(DESTDIR)$(sharedir)/conf/audit-blocker-adulte.rules
	$(INSTALL_DATA) share/conf/blocker.conf \
		$(DESTDIR)$(sharedir)/conf/blocker.conf

	# --- Modeles de policies navigateur ------------------------------------
	$(INSTALL_DIR) $(DESTDIR)$(sharedir)/policies
	$(INSTALL_DATA) etc/firefox-policies/policies.json \
		$(DESTDIR)$(sharedir)/policies/firefox-policies.json
	$(INSTALL_DATA) etc/chrome-policies/blocker-adulte.json \
		$(DESTDIR)$(sharedir)/policies/chrome-policies.json
	$(INSTALL_DATA) etc/chromium-policies/blocker-adulte.json \
		$(DESTDIR)$(sharedir)/policies/chromium-policies.json
	$(INSTALL_DATA) etc/brave-policies/blocker-adulte.json \
		$(DESTDIR)$(sharedir)/policies/brave-policies.json

	# --- Hooks initramfs (modeles ; poses dans /etc par blocker-configure) --
	$(INSTALL_DIR) $(DESTDIR)$(sharedir)/initramfs
	$(INSTALL_PROG) initramfs-hook/blocker-adulte-hook \
		$(DESTDIR)$(sharedir)/initramfs/blocker-adulte-hook
	$(INSTALL_PROG) initramfs-hook/blocker-adulte-init-bottom \
		$(DESTDIR)$(sharedir)/initramfs/blocker-adulte-init-bottom

	# --- Liste de blocage de base ------------------------------------------
	$(INSTALL_DIR) $(DESTDIR)$(sharedir)/blocklists
	$(INSTALL_DATA) share/blocklists/00-base.conf \
		$(DESTDIR)$(sharedir)/blocklists/00-base.conf

	# --- Tests --------------------------------------------------------------
	$(INSTALL_DIR) $(DESTDIR)$(sharedir)/tests
	$(INSTALL_PROG) tests/test_dns_leak.sh              $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_doh_blocked.sh           $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_watchdog_cross_restart.sh $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_browser_reinstall.sh     $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_recovery_mode_hook.sh    $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_no_hidden_files.sh       $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_safesearch.sh           $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/test_uninstall_phases.sh     $(DESTDIR)$(sharedir)/tests/
	$(INSTALL_PROG) tests/run_all.sh                    $(DESTDIR)$(sharedir)/tests/

	# --- Documentation ------------------------------------------------------
	# Le README est aussi la reference du test test_no_hidden_files.sh : il doit
	# etre installe sur la machine, pas seulement present dans le depot.
	$(INSTALL_DIR) $(DESTDIR)$(docdir)
	$(INSTALL_DATA) README.md $(DESTDIR)$(docdir)/README.md

uninstall:
	@echo "Ne pas utiliser « make uninstall »."
	@echo "La desinstallation se fait en quatre phases :"
	@echo "  sudo blocker-uninstall --etat      # ou en est-on"
	@echo "  sudo blocker-uninstall --phase 1   # commencer"
	@echo "  sudo blocker-uninstall --manuel    # procedure manuelle equivalente"
	@exit 1

# Verification syntaxique de tous les scripts du depot.
check:
	@erreurs=0; \
	for f in install.sh blocker-uninstall.sh bin/* lib/*.sh tests/*.sh \
	         etc/NetworkManager/dispatcher.d/90-blocker-adulte \
	         initramfs-hook/* debian/postinst debian/prerm debian/postrm; do \
		[ -f "$$f" ] || continue; \
		if head -1 "$$f" | grep -q 'bin/sh'; then sh -n "$$f" || erreurs=1; \
		else bash -n "$$f" || erreurs=1; fi; \
	done; \
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -S warning -e SC2034 \
			install.sh blocker-uninstall.sh bin/* lib/*.sh tests/*.sh \
			etc/NetworkManager/dispatcher.d/90-blocker-adulte \
			|| erreurs=1; \
		shellcheck -S warning -e SC2034 -s sh \
			initramfs-hook/* debian/postinst debian/prerm debian/postrm \
			|| erreurs=1; \
	else \
		echo "shellcheck absent : analyse statique ignoree (apt install shellcheck)."; \
	fi; \
	if command -v python3 >/dev/null 2>&1; then \
		for f in etc/*-policies/*.json; do \
			python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$$f" || erreurs=1; \
		done; \
	else \
		echo "python3 absent : validation JSON ignoree."; \
	fi; \
	if [ "$$erreurs" -eq 0 ]; then echo "OK : syntaxe des scripts et des JSON valide."; \
	else echo "ECHEC : voir les erreurs ci-dessus."; exit 1; fi

# Construction du paquet .deb (composant 5). Le paquet produit est depose dans
# le repertoire parent, comme le veut la convention Debian.
deb:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { \
		echo "dpkg-buildpackage absent : sudo apt install build-essential debhelper devscripts"; \
		exit 1; }
	dpkg-buildpackage -us -uc -b
	@echo
	@echo "Paquet construit dans le repertoire parent. Installation :"
	@echo "  sudo apt install ../blocker-adulte_*.deb"

clean:
	rm -rf debian/tmp debian/blocker-adulte debian/.debhelper \
	       debian/files debian/*.substvars debian/*.debhelper.log
