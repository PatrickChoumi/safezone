#!/bin/bash
# blocker-adulte — installation directe depuis le depot (idempotente)
#
# Usage :
#   sudo ./install.sh              installe et configure
#   sudo ./install.sh --dry-run    affiche ce qui serait fait
#   sudo ./install.sh --no-deps    n'installe aucun paquet
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
# Desinstallation : elle se fait en quatre phases, il n'y a pas de commande
# unique. Point de depart : sudo blocker-uninstall --etat

set -uo pipefail

DRY_RUN=0
NO_DEPS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-deps) NO_DEPS=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Argument inconnu / unknown argument : $1" >&2; exit 2 ;;
    esac
    shift
done

SRC="$(cd "$(dirname "$0")" && pwd)"

# Couche d'adaptation a la distribution et messages bilingues. Les deux sont
# lus depuis le depot : a ce stade rien n'est encore installe sur la machine.
BLOCKER_SHAREDIR="${SRC}/share"
# shellcheck source=lib/blocker-os.sh
. "${SRC}/lib/blocker-os.sh"
# shellcheck source=lib/blocker-i18n.sh
. "${SRC}/lib/blocker-i18n.sh"

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
    echo "$(m "install.sh : doit etre lance en root (sudo ./install.sh)." \
             "install.sh: must be run as root (sudo ./install.sh).")" >&2
    exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "$(m "MODE SIMULATION — aucune modification ne sera faite." \
             "DRY RUN — nothing will be modified.")"
fi

# ---------------------------------------------------------------------------
# 1. Verifications prealables
# ---------------------------------------------------------------------------
log "$(m "verifications prealables" "preliminary checks")"

# Deux exigences sans lesquelles il n'y a pas d'outil, quelle que soit la
# distribution. Elles sont verifiees ici et pas plus loin : mieux vaut refuser
# tout de suite que poser des fichiers inutilisables.
#
#   - systemd : les huit composants reposent sur des unites, des timers et le
#     watchdog systemd ; il n'existe pas d'equivalent portable ailleurs.
#   - nftables : le composant 2 est un jeu de regles nftables, et iptables ne
#     sait pas exprimer « meta skuid », dont depend l'exemption du resolveur.
if ! command -v systemctl >/dev/null 2>&1; then
    echo "$(m "systemd est requis : les huit composants reposent sur ses unites et son watchdog." \
             "systemd is required: all eight components rely on its units and watchdog.")" >&2
    exit 1
fi
if [ ! -d /run/systemd/system ]; then
    info "$(m "AVERTISSEMENT : systemd n'est pas le gestionnaire de services actif (conteneur ?)." \
              "WARNING: systemd is not the active service manager (container?).")"
    info "$(m "Les fichiers seront poses, mais aucun service ne pourra demarrer." \
              "Files will be installed, but no service will be able to start.")"
fi

info "$(m "distribution" "distribution") : ${BLOCKER_OS_NAME:-?} ($(m "famille" "family") ${BLOCKER_FAMILY})"
info "$(m "gestionnaire de paquets" "package manager") : ${BLOCKER_PKGMGR}"
info "$(m "generateur d'initramfs" "initramfs generator") : ${BLOCKER_INITRAMFS}"

if [ "${BLOCKER_FAMILY}" = "inconnue" ]; then
    info "$(m "AVERTISSEMENT : famille de distribution non reconnue. L'installation continue ;" \
              "WARNING: unrecognised distribution family. Installation continues;")"
    info "$(m "les composants qu'on ne saura pas configurer seront signales inactifs." \
              "components we cannot configure will be reported as inactive.")"
fi
if [ "${BLOCKER_PKGMGR}" = "aucun" ] && [ "${NO_DEPS}" -eq 0 ]; then
    info "$(m "AVERTISSEMENT : aucun gestionnaire de paquets reconnu — les dependances" \
              "WARNING: no package manager recognised — missing dependencies")"
    info "$(m "manquantes devront etre installees a la main." \
              "will have to be installed by hand.")"
fi
if [ "${BLOCKER_INITRAMFS}" = "aucun" ]; then
    info "$(m "AVERTISSEMENT : ni initramfs-tools, ni dracut, ni mkinitcpio — composant 4 inactif." \
              "WARNING: no initramfs-tools, dracut or mkinitcpio — component 4 inactive.")"
fi

# Systeme de fichiers racine : chattr +i n'existe pas partout.
FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || echo inconnu)"
case "${FSTYPE}" in
    ext2|ext3|ext4|xfs|btrfs)
        info "$(m "systeme de fichiers racine" "root filesystem") : ${FSTYPE} ($(m "chattr +i supporte" "chattr +i supported"))" ;;
    *)
        info "$(m "AVERTISSEMENT : systeme de fichiers racine" "WARNING: root filesystem") ${FSTYPE} — $(m "chattr +i peut ne pas fonctionner." "chattr +i may not work.")" ;;
esac

# ---------------------------------------------------------------------------
# 2. Dependances
# ---------------------------------------------------------------------------
log "$(m "dependances" "dependencies")"

# On raisonne en ROLES, pas en noms de paquets : « le paquet qui fournit dig »
# s'appelle bind9-dnsutils sur Debian recent, dnsutils avant, bind-utils sur
# Fedora, bind sur Arch, bind-tools sur Alpine. blocker-os.sh tient cette
# correspondance et retient, pour chaque role, le premier nom que le
# gestionnaire de paquets connait reellement — ce qui survit aux renommages
# sans table par version de distribution.
#
# « dig » n'est pas une commodite de debogage : blocker-safesearch s'en sert
# pour resoudre les hotes stricts, blocker-guard et blocker-selfheal pour
# verifier que le resolveur repond, « blocker-status --sonde » pour toutes ses
# sondes, et la moitie des tests refusent de demarrer sans lui.
ROLES="dnsmasq nftables resolved auditd curl dig chattr initramfs"

DEPS=""
for role in ${ROLES}; do
    pkg="$(blocker_pkg_pour_role "${role}")"
    # Une reponse vide est une reponse valable : le role est deja couvert par le
    # systeme de base (systemd-resolved fait partie de systemd sur Arch).
    [ -n "${pkg}" ] && DEPS="${DEPS} ${pkg}"
done

manquants=""
for pkg in ${DEPS}; do
    blocker_pkg_installe "${pkg}" || manquants="${manquants} ${pkg}"
done

if [ -n "${manquants}" ]; then
    if [ "${NO_DEPS}" -eq 1 ]; then
        info "--no-deps : $(m "paquets manquants non installes" "missing packages not installed") :${manquants}"
        info "$(m "certains composants resteront inactifs." "some components will stay inactive.")"
    elif [ "${BLOCKER_PKGMGR}" = "aucun" ]; then
        info "$(m "paquets manquants" "missing packages") :${manquants}"
        info "$(m "aucun gestionnaire de paquets reconnu : les installer a la main." \
                  "no package manager recognised: install them by hand.")"
    else
        info "$(m "paquets manquants" "missing packages") :${manquants}"
        run blocker_pkg_maj_index
        # shellcheck disable=SC2086
        run blocker_pkg_installer ${manquants}
    fi
else
    info "$(m "toutes les dependances sont deja installees." "all dependencies are already installed.")"
fi

# Le service dnsmasq de la distribution, s'il existe, ecoute lui aussi sur le
# port 53 et entrerait en conflit avec blocker-resolver.service. On le desactive
# explicitement — sans le masquer ni le cacher : « systemctl status dnsmasq »
# montrera clairement qu'il est desactive.
if systemctl list-unit-files dnsmasq.service 2>/dev/null | grep -q dnsmasq; then
    if systemctl is-enabled --quiet dnsmasq.service 2>/dev/null; then
        info "$(m "le service dnsmasq de la distribution est actif : desactivation pour eviter" \
                  "the distribution dnsmasq service is active: disabling it to avoid")"
        info "$(m "un conflit sur le port 53 (reactivable par « systemctl enable --now dnsmasq »)." \
                  "a conflict on port 53 (re-enable with « systemctl enable --now dnsmasq »).")"
        run systemctl disable --now dnsmasq.service
    fi
fi

# ---------------------------------------------------------------------------
# 3. Pose des fichiers
# ---------------------------------------------------------------------------
log "$(m "pose des fichiers (make install)" "installing files (make install)")"
run make -C "${SRC}" install DESTDIR=/

# ---------------------------------------------------------------------------
# 4. Configuration
# ---------------------------------------------------------------------------
log "configuration"
if [ "${DRY_RUN}" -eq 1 ]; then
    info "[dry-run] $(m "lancerait" "would run") /usr/lib/blocker-adulte/blocker-configure"
    info "[dry-run] $(m "MODE SIMULATION termine." "DRY RUN finished.")"
    exit 0
fi

/usr/lib/blocker-adulte/blocker-configure
rc=$?

# On memorise d'ou vient l'installation : « blocker-update » n'a alors plus
# besoin qu'on lui rappelle ou le depot a ete clone.
if [ -d "${SRC}/.git" ]; then
    install -d -m 0755 /etc/blocker-adulte
    printf '%s\n' "${SRC}" > /etc/blocker-adulte/source
    chmod 0644 /etc/blocker-adulte/source
    info "$(m "depot memorise pour les mises a jour" "repository recorded for updates") : ${SRC}"
    info "$(m "mettre a jour plus tard" "update later") : sudo blocker-update"
fi

# ---------------------------------------------------------------------------
# 5. Premiere mise a jour des listes
# ---------------------------------------------------------------------------
log "$(m "premiere mise a jour des listes de blocage" "first blocklist update")"
info "$(m "la liste de base livree avec le paquet est deja active ;" \
          "the base list shipped with the package is already active;")"
info "$(m "recuperation des listes completes en arriere-plan." \
          "fetching the full lists in the background.")"
systemctl start --no-block blocker-list-update.service 2>/dev/null || \
    info "$(m "AVERTISSEMENT : lancement de la mise a jour des listes en echec (machine hors ligne ?)" \
              "WARNING: could not start the list update (machine offline?)")"

# ---------------------------------------------------------------------------
# 6. Bilan
# ---------------------------------------------------------------------------
log "$(m "bilan" "summary")"

etat() {
    if systemctl is-active --quiet "$1"; then
        printf '  [%s] %s\n' "$(m "actif  " "active ")" "$1"
    else
        printf '  [%s] %s\n' "$(m "INACTIF" "STOPPED")" "$1"
    fi
}

etat blocker-resolver.service
etat blocker-guard.service
etat blocker-selfheal.timer
etat blocker-list-update.timer
etat blocker-policies.path

printf '\n'
printf '%s\n' "$(m "Verifier le blocage :" "Check the blocking:")"
printf '  sudo %s/tests/run_all.sh\n' "${SRC}"
printf '\n'
printf '%s\n' "$(m "Suivre les reparations automatiques :" "Follow automatic repairs:")"
printf '  journalctl -f -u blocker-guard -u blocker-selfheal -u blocker-resolver\n'
printf '\n'
printf '%s\n' "$(m "Mettre a jour depuis le depot git :" "Update from the git repository:")"
printf '  sudo blocker-update --verifier   # %s\n' "$(m "voir s il y a du nouveau" "see whether anything is new")"
printf '  sudo blocker-update              # %s\n' "$(m "relire les changements puis appliquer" "review the changes, then apply")"
printf '\n'
printf '%s\n' "$(m "Desinstaller — quatre phases, pas de commande unique :" "Uninstall — four phases, no single command:")"
printf '  sudo blocker-uninstall --etat      # %s\n' "$(m "ou en est-on" "where we stand")"
printf '  sudo blocker-uninstall --phase 1   # %s\n' "$(m "commencer" "start")"
printf '  sudo blocker-uninstall --manuel    # %s\n' "$(m "procedure manuelle equivalente" "equivalent manual procedure")"
printf '\n'

exit "${rc}"
