#!/bin/bash
# blocker-adulte — installation directe depuis le depot (idempotente)
#
# Usage :
#   sudo ./install.sh              installe et configure
#   sudo ./install.sh --dry-run    affiche ce qui serait fait
#   sudo ./install.sh --no-deps    n'installe aucun paquet apt
#
# Relancer ce script sur une machine deja configuree est sans effet de bord :
# les fichiers identiques ne sont pas reecrits, les services deja actifs ne sont
# pas redemarres inutilement.
#
# Deux voies d'installation existent et donnent le meme resultat :
#   - ce script, pour un usage direct depuis le depot ;
#   - le paquet .deb (« make deb » puis « apt install ./blocker-adulte_*.deb »),
#     dont le postinst appelle exactement le meme blocker-configure.
#
# Desinstallation : sudo blocker-uninstall --confirm
# (procedure manuelle equivalente detaillee dans le README).

set -uo pipefail

DRY_RUN=0
NO_DEPS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-deps) NO_DEPS=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Argument inconnu : $1" >&2; exit 2 ;;
    esac
    shift
done

SRC="$(cd "$(dirname "$0")" && pwd)"

log()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    printf '  + %s\n' "$*"
    "$@"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh : doit etre lance en root (sudo ./install.sh)." >&2
    exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "MODE SIMULATION — aucune modification ne sera faite."
fi

# ---------------------------------------------------------------------------
# 1. Verifications prealables
# ---------------------------------------------------------------------------
log "verifications prealables"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd est requis (Ubuntu 20.04 ou plus recent)." >&2
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    info "AVERTISSEMENT : /etc/os-release illisible, distribution non identifiee."
else
    # shellcheck disable=SC1091
    . /etc/os-release
    info "distribution : ${PRETTY_NAME:-inconnue}"
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *) info "AVERTISSEMENT : distribution non Debian/Ubuntu, les hooks dpkg et initramfs-tools peuvent ne pas s'appliquer." ;;
    esac
fi

# Systeme de fichiers racine : chattr +i n'existe pas partout.
FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || echo inconnu)"
case "${FSTYPE}" in
    ext2|ext3|ext4|xfs|btrfs) info "systeme de fichiers racine : ${FSTYPE} (chattr +i supporte)" ;;
    *) info "AVERTISSEMENT : systeme de fichiers racine ${FSTYPE} — chattr +i peut ne pas fonctionner." ;;
esac

# ---------------------------------------------------------------------------
# 2. Dependances
# ---------------------------------------------------------------------------
log "dependances"

DEPS="dnsmasq-base nftables systemd-resolved auditd curl e2fsprogs initramfs-tools"

manquants=""
for pkg in ${DEPS}; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
        manquants="${manquants} ${pkg}"
    fi
done

if [ -n "${manquants}" ]; then
    if [ "${NO_DEPS}" -eq 1 ]; then
        info "--no-deps : paquets manquants non installes :${manquants}"
        info "certains composants resteront inactifs."
    else
        info "paquets manquants :${manquants}"
        run env DEBIAN_FRONTEND=noninteractive apt-get update
        # shellcheck disable=SC2086
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y ${manquants}
    fi
else
    info "toutes les dependances sont deja installees."
fi

# Le service dnsmasq de la distribution, s'il existe, ecoute lui aussi sur le
# port 53 et entrerait en conflit avec blocker-resolver.service. On le desactive
# explicitement — sans le masquer ni le cacher : « systemctl status dnsmasq »
# montrera clairement qu'il est desactive.
if systemctl list-unit-files dnsmasq.service 2>/dev/null | grep -q dnsmasq; then
    if systemctl is-enabled --quiet dnsmasq.service 2>/dev/null; then
        info "le service dnsmasq de la distribution est actif : desactivation pour eviter"
        info "un conflit sur le port 53 (reactivable par « systemctl enable --now dnsmasq »)."
        run systemctl disable --now dnsmasq.service
    fi
fi

# ---------------------------------------------------------------------------
# 3. Pose des fichiers
# ---------------------------------------------------------------------------
log "pose des fichiers (make install)"
run make -C "${SRC}" install DESTDIR=/

# ---------------------------------------------------------------------------
# 4. Configuration
# ---------------------------------------------------------------------------
log "configuration"
if [ "${DRY_RUN}" -eq 1 ]; then
    info "[dry-run] lancerait /usr/lib/blocker-adulte/blocker-configure"
    info "[dry-run] MODE SIMULATION termine."
    exit 0
fi

/usr/lib/blocker-adulte/blocker-configure
rc=$?

# ---------------------------------------------------------------------------
# 5. Premiere mise a jour des listes
# ---------------------------------------------------------------------------
log "premiere mise a jour des listes de blocage"
info "la liste de base livree avec le paquet est deja active ;"
info "recuperation des listes completes en arriere-plan."
systemctl start --no-block blocker-list-update.service 2>/dev/null || \
    info "AVERTISSEMENT : lancement de la mise a jour des listes en echec (machine hors ligne ?)"

# ---------------------------------------------------------------------------
# 6. Bilan
# ---------------------------------------------------------------------------
log "bilan"

etat() {
    if systemctl is-active --quiet "$1"; then
        printf '  [actif]   %s\n' "$1"
    else
        printf '  [INACTIF] %s\n' "$1"
    fi
}

etat blocker-resolver.service
etat blocker-guard.service
etat blocker-selfheal.timer
etat blocker-list-update.timer

printf '\n'
printf 'Verifier le blocage :\n'
printf '  sudo %s/tests/run_all.sh\n' "${SRC}"
printf '\n'
printf 'Suivre les reparations automatiques :\n'
printf '  journalctl -f -u blocker-guard -u blocker-selfheal -u blocker-resolver\n'
printf '\n'
printf 'Desinstaller (procedure complete, huit etapes) :\n'
printf '  sudo blocker-uninstall --dry-run   # voir ce qui serait fait\n'
printf '  sudo blocker-uninstall --confirm   # executer\n'
printf '  La procedure manuelle equivalente est dans le README, section « Desinstallation ».\n'
printf '\n'

exit "${rc}"
