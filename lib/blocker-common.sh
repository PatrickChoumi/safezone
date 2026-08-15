# shellcheck shell=bash
# blocker-adulte — bibliotheque partagee
#
# Installee dans /usr/lib/blocker-adulte/blocker-common.sh
#
# Toutes les fonctions de ce fichier journalisent en clair. Aucune fonction ici
# ne masque un fichier, un processus ou une entree dpkg, et aucune ne se recopie
# ailleurs que dans les emplacements listes dans le README.

BLOCKER_NAME="blocker-adulte"
BLOCKER_LIBDIR="/usr/lib/blocker-adulte"
BLOCKER_SHAREDIR="/usr/share/blocker-adulte"
BLOCKER_STATEDIR="/var/lib/blocker-adulte"
BLOCKER_RUNDIR="/run/blocker-adulte"
BLOCKER_CONFDIR="/etc/blocker-adulte"
BLOCKER_CONF="${BLOCKER_CONFDIR}/blocker.conf"
BLOCKER_USER="blocker-adulte"

# Drapeau pose par blocker-uninstall.sh AVANT toute autre action. Tant qu'il
# existe, les watchdogs se mettent en retrait : la desinstallation documentee
# n'est jamais combattue.
BLOCKER_OPTOUT_FLAG="${BLOCKER_RUNDIR}/uninstall-in-progress"

# Valeurs par defaut, surchargeables par ${BLOCKER_CONF}.
BLOCKER_UPSTREAM_1="1.1.1.3"          # Cloudflare for Families (filtrant)
BLOCKER_UPSTREAM_2="1.0.0.3"
BLOCKER_LISTEN_ADDR="127.0.0.1"
BLOCKER_LISTEN_PORT="53"
BLOCKER_GUARD_INTERVAL="15"           # secondes entre deux passes de watchdog
BLOCKER_LOCK_HOSTS="auto"             # rendre /etc/hosts immuable : oui/non/auto
BLOCKER_LIST_URLS="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/doh-vpn-proxy-bypass.txt"

if [ -r "${BLOCKER_CONF}" ]; then
    # shellcheck disable=SC1090
    . "${BLOCKER_CONF}"
fi

# ---------------------------------------------------------------------------
# Journalisation
# ---------------------------------------------------------------------------

# Sous systemd, stdout/stderr partent deja dans le journal : on evite le double.
# Hors systemd (execution manuelle), on ecrit dans le journal via logger ET sur
# le terminal, pour qu'une reparation ne soit jamais silencieuse.
_blocker_emit() {
    local level="$1"; shift
    local msg="$*"
    printf '[%s] %s: %s\n' "${BLOCKER_NAME}" "${level}" "${msg}" >&2
    if [ -z "${INVOCATION_ID:-}" ] && command -v logger >/dev/null 2>&1; then
        logger -t "${BLOCKER_NAME}" -p "daemon.${level}" -- "${msg}" || true
    fi
}

blocker_info()   { _blocker_emit info "$*"; }
blocker_notice() { _blocker_emit notice "$*"; }
blocker_warn()   { _blocker_emit warning "$*"; }
blocker_err()    { _blocker_emit err "$*"; }

# Toute action corrective passe par ici : une reparation automatique est
# toujours tracee, jamais silencieuse (exigence de la ligne rouge).
blocker_repair() { _blocker_emit notice "REPARATION: $*"; }

# ---------------------------------------------------------------------------
# Retrait volontaire
# ---------------------------------------------------------------------------

# Vrai si l'utilisateur a lance la procedure de desinstallation documentee, ou
# si l'unite de garde a ete desactivee de facon persistante (systemctl disable).
# Dans ces deux cas les watchdogs n'entreprennent AUCUNE reparation.
blocker_optout_active() {
    if [ -e "${BLOCKER_OPTOUT_FLAG}" ]; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        case "$(systemctl is-enabled blocker-guard.service 2>/dev/null)" in
            disabled|masked)
                # Choix explicite de l'utilisateur.
                return 0
                ;;
            not-found|"")
                # systemd n'a pas su repondre. Deux causes tres differentes :
                # l'unite a ete supprimee (retrait en cours), ou le gestionnaire
                # est simplement injoignable (conteneur, chroot, boot en cours).
                # On ne conclut au retrait que si le fichier d'unite a
                # reellement disparu du disque.
                if [ ! -e /lib/systemd/system/blocker-guard.service ] && \
                   [ ! -e /usr/lib/systemd/system/blocker-guard.service ] && \
                   [ ! -e /etc/systemd/system/blocker-guard.service ]; then
                    return 0
                fi
                ;;
        esac
    fi
    return 1
}

# A appeler au debut de chaque passe de watchdog / self-heal.
blocker_stand_down_if_optout() {
    if blocker_optout_active; then
        blocker_notice "retrait volontaire detecte (${BLOCKER_OPTOUT_FLAG} ou unite desactivee) : aucune reparation, arret de la boucle"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Inventaire des fichiers proteges
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cas particulier de /etc/hosts
# ---------------------------------------------------------------------------
#
# Une seule ligne dans /etc/hosts suffit a contourner entierement le resolveur :
# la resolution systeme (NSS) lit ce fichier AVANT d'interroger le DNS. C'est le
# contournement le plus simple qui existe contre un filtrage DNS, et « no-hosts »
# cote dnsmasq n'y change rien puisque le fichier est lu par la glibc.
#
# On peut le rendre immuable, mais c'est le seul fichier protege qui appartient
# a un autre paquet et que d'autres logiciels reecrivent legitimement :
# Docker y ajoute ses conteneurs, cloud-init et les outils de virtualisation
# aussi. Le verrouiller a l'aveugle casserait ces outils de facon opaque.
#
# Regle retenue : on verrouille par defaut sur une machine de bureau, et on
# s'abstient — en le disant dans le journal — des qu'un de ces logiciels est
# present. Reglable par BLOCKER_LOCK_HOSTS dans /etc/blocker-adulte/blocker.conf
# (« oui » / « non » / « auto », defaut « auto »).
blocker_hosts_verrouillable() {
    case "${BLOCKER_LOCK_HOSTS:-auto}" in
        non|no|0) return 1 ;;
        oui|yes|1) return 0 ;;
    esac

    # Mode « auto » : on s'efface devant les logiciels qui ecrivent /etc/hosts.
    for gene in /usr/bin/docker /usr/bin/podman /usr/bin/lxc /usr/bin/vagrant; do
        [ -x "${gene}" ] && return 1
    done
    [ -d /var/lib/docker ] && return 1
    [ -x /usr/bin/cloud-init ] && return 1

    return 0
}

# Fichiers rendus immuables (chattr +i) par le self-heal.
# Volontairement limite aux fichiers dont le projet est proprietaire : rendre
# immuable un fichier appartenant a un autre paquet casserait ses mises a jour.
#
# /etc/hosts est un cas a part, traite par blocker_hosts_verrouillable() : il
# ne nous appartient pas et d'autres logiciels l'ecrivent legitimement.
blocker_protected_files() {
    if blocker_hosts_verrouillable; then
        printf '/etc/hosts\n'
    fi
    cat <<'EOF'
/etc/nftables/blocker-adulte.nft
/etc/dnsmasq.d/blocker-adulte.conf
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
/etc/firefox/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json
EOF
}

# Repertoires de policies navigateur : <repertoire cible>|<fichier modele>|<marqueur de presence du navigateur>
# Le marqueur sert uniquement a decider si le navigateur est installe ; la
# policy est deployee des que le repertoire /etc correspondant est creable.
blocker_browser_targets() {
    cat <<'EOF'
/etc/firefox/policies|policies.json|firefox
/etc/opt/chrome/policies/managed|blocker-adulte.json|chrome
/etc/chromium/policies/managed|blocker-adulte.json|chromium
/etc/opt/chromium/policies/managed|blocker-adulte.json|chromium
/etc/brave/policies/managed|blocker-adulte.json|brave
EOF
}

# Modele a copier pour chaque famille de navigateur.
blocker_policy_source() {
    case "$1" in
        firefox)  printf '%s\n' "${BLOCKER_SHAREDIR}/policies/firefox-policies.json" ;;
        chrome)   printf '%s\n' "${BLOCKER_SHAREDIR}/policies/chrome-policies.json" ;;
        chromium) printf '%s\n' "${BLOCKER_SHAREDIR}/policies/chromium-policies.json" ;;
        brave)    printf '%s\n' "${BLOCKER_SHAREDIR}/policies/brave-policies.json" ;;
        *)        return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Immuabilite
# ---------------------------------------------------------------------------

blocker_lock_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    command -v chattr >/dev/null 2>&1 || return 0
    # Sortie capturee plutot que filtree par un pipeline : sous « pipefail »,
    # un « grep -q » qui sort tot fait echouer tout le pipeline via SIGPIPE.
    local drapeaux
    drapeaux="$(lsattr -d "$f" 2>/dev/null)"
    drapeaux="${drapeaux%% *}"
    case "${drapeaux}" in
        *i*) return 0 ;;
    esac
    if chattr +i "$f" 2>/dev/null; then
        blocker_repair "immuabilite (chattr +i) reappliquee sur $f"
    else
        # Systemes de fichiers sans support des attributs etendus (overlayfs,
        # zfs, certains montages conteneurises) : ce n'est pas une erreur fatale.
        blocker_warn "chattr +i impossible sur $f (systeme de fichiers sans support ?)"
    fi
}

blocker_unlock_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    command -v chattr >/dev/null 2>&1 || return 0
    chattr -i "$f" 2>/dev/null || true
}

blocker_lock_all() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && blocker_lock_file "$f"
    done < <(blocker_protected_files)
}

blocker_unlock_all() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && blocker_unlock_file "$f"
    done < <(blocker_protected_files)
}

# Ecriture d'un fichier protege : deverrouille, ecrit, reverrouille.
#
# La comparaison a lieu AVANT le deverrouillage : chattr +i n'empeche pas la
# lecture, et deverrouiller systematiquement ferait journaliser une
# « REPARATION » a chaque passe de watchdog, meme quand rien n'a bouge. Le
# journal doit rester une trace des ecarts reels, pas un bruit de fond.
blocker_install_protected() {
    local src="$1" dst="$2" mode="${3:-0644}"
    [ -r "$src" ] || { blocker_err "modele introuvable : $src"; return 1; }
    mkdir -p "$(dirname "$dst")"

    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        # Contenu conforme. blocker_lock_file ne journalise que si l'attribut
        # d'immuabilite avait reellement disparu.
        blocker_lock_file "$dst"
        return 0
    fi

    blocker_unlock_file "$dst"
    install -m "$mode" "$src" "$dst"
    blocker_repair "fichier reecrit depuis le modele : $dst"
    blocker_lock_file "$dst"
}

# ---------------------------------------------------------------------------
# Divers
# ---------------------------------------------------------------------------

blocker_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        blocker_err "cette commande doit etre lancee en root"
        exit 1
    fi
}

blocker_unit_active() {
    systemctl is-active --quiet "$1"
}

blocker_ensure_rundir() {
    mkdir -p "${BLOCKER_RUNDIR}"
}

# Notification watchdog systemd (WatchdogSec). Sans effet hors systemd.
blocker_watchdog_ping() {
    if [ -n "${NOTIFY_SOCKET:-}" ] && command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify WATCHDOG=1 || true
    fi
}

blocker_notify_ready() {
    if [ -n "${NOTIFY_SOCKET:-}" ] && command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify --ready "STATUS=$*" || true
    fi
}

blocker_notify_status() {
    if [ -n "${NOTIFY_SOCKET:-}" ] && command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify "STATUS=$*" || true
    fi
}

# Pause interruptible par SIGTERM. Un « sleep » lance en avant-plan retarderait
# l'arret du service jusqu'a la fin de la temporisation ; en le mettant en
# arriere-plan et en l'attendant avec « wait », bash traite le signal tout de
# suite et « systemctl stop » rend la main immediatement.
blocker_sleep() {
    sleep "$1" &
    local pid=$!
    wait "${pid}" 2>/dev/null || true
}
