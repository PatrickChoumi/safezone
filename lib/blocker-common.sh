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
BLOCKER_LISTEN_ADDR="127.0.0.1"
BLOCKER_LISTEN_PORT="53"

# Zone d'etat. Tout ce qui s'y trouve est ecrit par l'outil, rendu immuable,
# et double d'une copie de reserve qui sert a detecter et a annuler une
# modification faite a la main (voir blocker_publier).
BLOCKER_LISTDIR="${BLOCKER_STATEDIR}/blocklists"
BLOCKER_NFTDIR="${BLOCKER_STATEDIR}/nft"
BLOCKER_DELAIDIR="${BLOCKER_STATEDIR}/delai"
BLOCKER_RESERVEDIR="${BLOCKER_STATEDIR}/reserve"
BLOCKER_RAPPORTDIR="${BLOCKER_STATEDIR}/rapports"
BLOCKER_QUARANTAINE="${BLOCKER_STATEDIR}/quarantaine"

# Configuration EN VIGUEUR. /etc/blocker-adulte/blocker.conf est l'endroit ou
# l'on PROPOSE un changement ; ce qui s'applique est la copie approuvee
# ci-dessous. Une proposition qui renforce la protection est approuvee a la
# passe de self-heal suivante, une proposition qui l'affaiblit attend le delai
# (voir blocker-delai.sh).
BLOCKER_CONF_EN_VIGUEUR="${BLOCKER_STATEDIR}/conf/blocker.conf"

# Exceptions approuvees (blocker-block --exception), un domaine par ligne.
BLOCKER_EXCEPTIONS="${BLOCKER_STATEDIR}/conf/exceptions.liste"

# Drapeau pose par blocker-uninstall.sh a la phase 1. Les watchdogs ne s'en
# ecartent que si une demande de desinstallation a passe le delai : un drapeau
# pose sans elle est retire (voir blocker_optout_active).
BLOCKER_OPTOUT_FLAG="${BLOCKER_RUNDIR}/uninstall-in-progress"

# Bibliotheques sans effet de bord : fonctions seulement. Elles sont chargees
# avant la configuration, dont blocker-delai.sh fournit les valeurs par defaut.
if [ -r "${BLOCKER_LIBDIR}/blocker-delai.sh" ]; then
    # shellcheck source=lib/blocker-delai.sh
    . "${BLOCKER_LIBDIR}/blocker-delai.sh"
fi
if [ -r "${BLOCKER_LIBDIR}/blocker-listes.sh" ]; then
    # shellcheck source=lib/blocker-listes.sh
    . "${BLOCKER_LIBDIR}/blocker-listes.sh"
fi

# Une valeur passee dans l'environnement doit survivre au chargement de
# blocker.conf : « BLOCKER_LANG=en sudo -E blocker-status » est documente, et
# blocker.conf contient « auto » par defaut — sans cette precaution, le fichier
# ecraserait le choix ponctuel de l'utilisateur a chaque fois.
_BLOCKER_LANG_ENV="${BLOCKER_LANG:-}"

# Valeurs par defaut, puis configuration en vigueur.
if command -v blocker_conf_defaut >/dev/null 2>&1; then
    for _v in ${BLOCKER_CONF_VARIABLES}; do
        printf -v "${_v}" '%s' "$(blocker_conf_defaut "${_v}")"
    done
    unset _v
fi

# Ordre de lecture : la copie approuvee ; a defaut sa reserve (la copie
# approuvee a ete supprimee, le self-heal la restaurera) ; a defaut, avant la
# toute premiere configuration seulement, le fichier de /etc.
if [ -r "${BLOCKER_CONF_EN_VIGUEUR}" ]; then
    # shellcheck disable=SC1090
    . "${BLOCKER_CONF_EN_VIGUEUR}"
elif [ -r "${BLOCKER_RESERVEDIR}/conf/blocker.conf" ]; then
    # shellcheck disable=SC1090
    . "${BLOCKER_RESERVEDIR}/conf/blocker.conf"
elif [ -r "${BLOCKER_CONF}" ]; then
    # shellcheck disable=SC1090
    . "${BLOCKER_CONF}"
fi

# Le delai a un plancher : en dessous de 24 heures, il ne couvrirait plus une
# nuit de sommeil.
case "${BLOCKER_DELAI_HEURES:-48}" in
    ''|*[!0-9]*) BLOCKER_DELAI_HEURES=48 ;;
esac
[ "${BLOCKER_DELAI_HEURES}" -lt 24 ] && BLOCKER_DELAI_HEURES=24

# blocker.conf ne l'emporte que s'il nomme une langue ; « auto » laisse la main
# a l'environnement, puis a la locale du systeme.
case "${BLOCKER_LANG:-auto}" in
    auto|"") [ -n "${_BLOCKER_LANG_ENV}" ] && BLOCKER_LANG="${_BLOCKER_LANG_ENV}" ;;
esac

# Adaptation a la distribution et messages traduits. Les deux fichiers sont
# charges apres blocker.conf : ils lisent BLOCKER_LANG, que l'utilisateur peut
# y avoir fixe. Ils sont facultatifs — une installation partielle doit encore
# pouvoir se desinstaller, ce qui interdit de faire echouer le chargement de
# cette bibliotheque parce qu'un fichier annexe manque.
if [ -r "${BLOCKER_LIBDIR}/blocker-os.sh" ]; then
    # shellcheck source=lib/blocker-os.sh
    . "${BLOCKER_LIBDIR}/blocker-os.sh"
fi
if [ -r "${BLOCKER_LIBDIR}/blocker-i18n.sh" ]; then
    # shellcheck source=lib/blocker-i18n.sh
    . "${BLOCKER_LIBDIR}/blocker-i18n.sh"
else
    # Repli : sans le fichier de traduction, on parle francais. Le script ne
    # doit pas s'arreter sur une commande introuvable.
    m() { printf '%s' "$1"; }
    BLOCKER_LANGUE="fr"
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
# Le mot-cle est traduit lui aussi : c'est ce que l'utilisateur cherchera dans
# « journalctl | grep ». Les tests acceptent les deux formes.
blocker_repair() { _blocker_emit notice "$(m REPARATION REPAIR): $*"; }

# ---------------------------------------------------------------------------
# Retrait volontaire
# ---------------------------------------------------------------------------

# Unites que l'outil maintient activees. Les quatre dernieres sont celles que
# personne ne surveillait : desarmer le self-heal ou la mise a jour des listes
# passait inapercu.
blocker_unites_surveillees() {
    printf '%s\n' blocker-resolver.service blocker-guard.service \
        blocker-selfheal.timer blocker-list-update.timer \
        blocker-policies.path blocker-rapport.timer
}

# Vrai si les watchdogs doivent se mettre en retrait : une desinstallation a ete
# demandee, le delai est passe (blocker_retrait_autorise), ET elle a commence —
# drapeau pose par la phase 1, unite de garde desactivee ou supprimee.
#
# Sans demande arrivee a echeance, ni le drapeau ni un « systemctl disable »
# ne suffisent plus : c'est tout l'objet du delai. La desinstallation n'est
# jamais combattue, elle est differee, et l'echeance est affichee.
blocker_optout_active() {
    command -v blocker_retrait_autorise >/dev/null 2>&1 || return 1
    blocker_retrait_autorise || return 1
    if [ -e "${BLOCKER_OPTOUT_FLAG}" ]; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        case "$(systemctl is-enabled blocker-guard.service 2>/dev/null)" in
            disabled|masked)
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
        blocker_notice "$(m "desinstallation demandee et arrivee a echeance : aucune reparation, mise en retrait" \
                           "uninstall requested and past its delay: no repair, standing down")"
        return 0
    fi
    return 1
}

# Un retrait commence SANS demande arrivee a echeance : drapeau pose a la main,
# unite desactivee ou masquee, timer arrete. On remet en place, en le disant,
# et en rappelant le seul chemin qui aboutit. Renvoie 0 si quelque chose a ete
# corrige.
blocker_reparer_retrait_non_autorise() {
    local corrige=1 u etat
    if command -v blocker_retrait_autorise >/dev/null 2>&1 && blocker_retrait_autorise; then
        return 1
    fi
    if [ -e "${BLOCKER_OPTOUT_FLAG}" ]; then
        rm -f "${BLOCKER_OPTOUT_FLAG}"
        blocker_repair "$(m "drapeau de retrait pose sans demande de desinstallation arrivee a echeance : retire" \
                           "removal flag set without an uninstall request past its delay: removed")"
        corrige=0
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        while IFS= read -r u; do
            etat="$(systemctl is-enabled "${u}" 2>/dev/null)"
            case "${etat}" in
                masked|masked-runtime)
                    systemctl unmask "${u}" >/dev/null 2>&1
                    systemctl enable "${u}" >/dev/null 2>&1
                    blocker_repair "${u} $(m "masque sans demande arrivee a echeance : demasque et reactive" \
                                             "masked without a request past its delay: unmasked and re-enabled")"
                    corrige=0 ;;
                disabled)
                    systemctl enable "${u}" >/dev/null 2>&1
                    blocker_repair "${u} $(m "desactive sans demande arrivee a echeance : reactive" \
                                             "disabled without a request past its delay: re-enabled")"
                    corrige=0 ;;
            esac
            case "${u}" in
                *.timer|*.path)
                    if ! systemctl is-active --quiet "${u}" 2>/dev/null; then
                        systemctl start "${u}" >/dev/null 2>&1
                        blocker_repair "${u} $(m "arrete, relance" "stopped, restarted")"
                        corrige=0
                    fi ;;
            esac
        done < <(blocker_unites_surveillees)
    fi
    if [ "${corrige}" -eq 0 ]; then
        blocker_notice "$(m "pour retirer l'outil : sudo blocker-uninstall --demander (delai de" \
                           "to remove the tool: sudo blocker-uninstall --request (delay of") ${BLOCKER_DELAI_HEURES} h)"
    fi
    return "${corrige}"
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

# Repertoires de policies navigateur : <repertoire cible>|<fichier>|<famille>
#
# Chromium est ecrit a trois endroits : la disposition varie selon l'origine
# du paquet (Debian, ancien deb Ubuntu, snap — ce dernier lit
# /etc/chromium-browser). Les derives de Firefox lisent /etc/<nom>/policies.
blocker_browser_targets() {
    cat <<'EOF'
/etc/firefox/policies|policies.json|firefox
/etc/firefox-esr/policies|policies.json|firefox-esr
/etc/librewolf/policies|policies.json|librewolf
/etc/waterfox/policies|policies.json|waterfox
/etc/floorp/policies|policies.json|floorp
/etc/opt/chrome/policies/managed|blocker-adulte.json|chrome
/etc/chromium/policies/managed|blocker-adulte.json|chromium
/etc/chromium-browser/policies/managed|blocker-adulte.json|chromium
/etc/opt/chromium/policies/managed|blocker-adulte.json|chromium
/etc/brave/policies/managed|blocker-adulte.json|brave
/etc/opt/edge/policies/managed|blocker-adulte.json|edge
/etc/vivaldi/policies/managed|blocker-adulte.json|vivaldi
EOF
}

# Fichiers rendus immuables (chattr +i) par le self-heal.
# Volontairement limite aux fichiers dont le projet est proprietaire : rendre
# immuable un fichier appartenant a un autre paquet casserait ses mises a jour.
#
# /etc/hosts est un cas a part, traite par blocker_hosts_verrouillable() : il
# ne nous appartient pas et d'autres logiciels l'ecrivent legitimement.
#
# Les fichiers de la zone d'etat (/var/lib/blocker-adulte) sont verrouilles a
# part, par blocker_publier : ils changent au fil des mises a jour.
blocker_protected_files() {
    local dir fichier _f
    if blocker_hosts_verrouillable; then
        printf '/etc/hosts\n'
    fi
    cat <<'EOF'
/etc/nftables/blocker-adulte.nft
/etc/nftables/blocker-adulte-tunnels.nft
/etc/dnsmasq.d/blocker-adulte.conf
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
EOF
    while IFS='|' read -r dir fichier _f; do
        [ -n "${dir}" ] && printf '%s/%s\n' "${dir}" "${fichier}"
    done < <(blocker_browser_targets)
}

# Modele a copier pour chaque famille de navigateur. Les derives de Firefox
# partagent la policy de Firefox, qu'ils comprennent tels quels.
blocker_policy_source() {
    case "$1" in
        firefox|firefox-esr|librewolf|waterfox|floorp) printf '%s\n' "${BLOCKER_SHAREDIR}/policies/firefox-policies.json" ;;
        chrome)   printf '%s\n' "${BLOCKER_SHAREDIR}/policies/chrome-policies.json" ;;
        chromium) printf '%s\n' "${BLOCKER_SHAREDIR}/policies/chromium-policies.json" ;;
        brave)    printf '%s\n' "${BLOCKER_SHAREDIR}/policies/brave-policies.json" ;;
        edge)     printf '%s\n' "${BLOCKER_SHAREDIR}/policies/edge-policies.json" ;;
        vivaldi)  printf '%s\n' "${BLOCKER_SHAREDIR}/policies/vivaldi-policies.json" ;;
        *)        return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Immuabilite
# ---------------------------------------------------------------------------

# blocker_lock_file <fichier> [silencieux]
# Sans second argument, un attribut retrouve absent est une REPARATION, et
# journalise comme telle. « silencieux » sert juste apres une ecriture legitime.
blocker_lock_file() {
    local f="$1" silencieux="${2:-}"
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
        [ -n "${silencieux}" ] || blocker_repair "$(m "immuabilite (chattr +i) reappliquee sur" "immutability (chattr +i) re-applied on") $f"
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
    blocker_repair "$(m "fichier reecrit depuis le modele" "file rewritten from the template") : $dst"
    blocker_lock_file "$dst" silencieux
}

# ---------------------------------------------------------------------------
# Fichiers d'etat geres
# ---------------------------------------------------------------------------
# Les listes, les jeux d'adresses nftables et la configuration en vigueur
# changent au fil des mises a jour : on ne peut pas les comparer a un modele
# fige. Chaque ecriture legitime passe donc par blocker_publier, qui pose le
# fichier, le rend immuable, et en garde une copie de reserve sous
# ${BLOCKER_RESERVEDIR}. Le self-heal compare ensuite chaque fichier a sa
# reserve : une difference est une modification faite a la main, un fichier
# sans reserve est un fichier inconnu.
#
# Le repertoire des listes lui-meme est immuable : on ne peut y deposer un
# fichier qu'en passant par ici.

_blocker_reserve_de() { printf '%s/%s' "${BLOCKER_RESERVEDIR}" "${1#"${BLOCKER_STATEDIR}"/}"; }

blocker_lock_dir()   { command -v chattr >/dev/null 2>&1 && [ -d "$1" ] && chattr +i "$1" 2>/dev/null; return 0; }
blocker_unlock_dir() { command -v chattr >/dev/null 2>&1 && [ -d "$1" ] && chattr -i "$1" 2>/dev/null; return 0; }

# blocker_publier <source> <destination dans la zone d'etat>
blocker_publier() {
    local src="$1" dst="$2" res dir copie="" rc
    res="$(_blocker_reserve_de "${dst}")"
    dir="$(dirname "${dst}")"
    # Republier un fichier tel qu'il est (creation de sa reserve) : install
    # refuse une source et une destination identiques.
    if [ "$(readlink -f "${src}")" = "$(readlink -f "${dst}")" ]; then
        copie="$(mktemp)" || return 1
        cp "${src}" "${copie}"
        _blocker_publier "${copie}" "${dst}" "${res}" "${dir}"; rc=$?
        rm -f "${copie}"
        return "${rc}"
    fi
    _blocker_publier "${src}" "${dst}" "${res}" "${dir}"
}

_blocker_publier() {
    local src="$1" dst="$2" res="$3" dir="$4"
    if [ -e "${dst}" ] && cmp -s "${src}" "${dst}" && cmp -s "${src}" "${res}"; then
        blocker_lock_file "${dst}" silencieux
        blocker_lock_file "${res}" silencieux
        return 0
    fi
    blocker_unlock_dir "${dir}"
    install -d -m 0755 "${dir}" "$(dirname "${res}")" || { blocker_lock_dir "${dir}"; return 1; }
    blocker_unlock_file "${dst}"
    blocker_unlock_file "${res}"
    if ! install -m 0644 "${src}" "${dst}" || ! install -m 0644 "${src}" "${res}"; then
        blocker_lock_dir "${dir}"
        blocker_err "$(m "ecriture impossible" "cannot write") : ${dst}"
        return 1
    fi
    blocker_lock_file "${dst}" silencieux
    blocker_lock_file "${res}" silencieux
    [ "${dir}" = "${BLOCKER_LISTDIR}" ] && blocker_lock_dir "${dir}"
    return 0
}

# blocker_retirer_gere <destination> — retire un fichier gere et sa reserve.
blocker_retirer_gere() {
    local dst="$1" res dir
    res="$(_blocker_reserve_de "${dst}")"
    dir="$(dirname "${dst}")"
    blocker_unlock_dir "${dir}"
    blocker_unlock_file "${dst}"
    blocker_unlock_file "${res}"
    rm -f "${dst}" "${res}"
    [ "${dir}" = "${BLOCKER_LISTDIR}" ] && blocker_lock_dir "${dir}"
    return 0
}

# Premiere passe avec la reserve (installation, ou mise a jour d'une version
# qui n'en avait pas) : les fichiers d'etat deja en place sont adoptes tels
# quels. Sans cette etape, tout ce qui existait serait pris pour un fichier
# inconnu et mis en quarantaine. Elle n'a lieu qu'une fois : ensuite, seul
# blocker_publier fait entrer un fichier dans la reserve.
blocker_adopter_etat() {
    local f
    [ -d "${BLOCKER_RESERVEDIR}/blocklists" ] && [ -e "${BLOCKER_RESERVEDIR}/conf/blocker.conf" ] && return 0
    blocker_info "$(m "premiere passe avec la reserve : adoption des fichiers d'etat en place" \
                      "first pass with the reserve: adopting the state files in place")"
    install -d -m 0755 "${BLOCKER_RESERVEDIR}/blocklists" "${BLOCKER_LISTDIR}"
    for f in "${BLOCKER_LISTDIR}"/*.conf "${BLOCKER_NFTDIR}"/*.nft "${BLOCKER_EXCEPTIONS}"; do
        [ -f "${f}" ] && blocker_publier "${f}" "${f}"
    done
    blocker_approuver_initiale
    return 0
}

# Configuration en vigueur initiale. L'installation est le moment ou l'on
# consent : le fichier de /etc est approuve tel quel s'il est lisible par
# l'analyseur strict. Sinon on n'en garde que les affectations valides — les
# reglages de l'utilisateur ne doivent pas disparaitre pour une ligne mal
# formee — et la proposition reste en place, signalee.
blocker_approuver_initiale() {
    local tmp
    if [ -e "${BLOCKER_CONF_EN_VIGUEUR}" ]; then
        [ -e "${BLOCKER_RESERVEDIR}/conf/blocker.conf" ] || \
            blocker_publier "${BLOCKER_CONF_EN_VIGUEUR}" "${BLOCKER_CONF_EN_VIGUEUR}"
        return 0
    fi
    if [ -e "${BLOCKER_RESERVEDIR}/conf/blocker.conf" ]; then
        blocker_publier "${BLOCKER_RESERVEDIR}/conf/blocker.conf" "${BLOCKER_CONF_EN_VIGUEUR}"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    if [ -r "${BLOCKER_CONF}" ] && blocker_conf_valide "${BLOCKER_CONF}"; then
        cp "${BLOCKER_CONF}" "${tmp}"
    elif [ -r "${BLOCKER_CONF}" ]; then
        {
            printf '# blocker-adulte — configuration en vigueur, reconstituee depuis %s\n' "${BLOCKER_CONF}"
            printf '# (lignes non reconnues ignorees)\n'
            blocker_conf_lire "${BLOCKER_CONF}" | grep -v '^ERREUR' | grep -v '"' \
                | while IFS="$(printf '\t')" read -r nom valeur; do
                      printf '%s="%s"\n' "${nom}" "${valeur}"
                  done
        } > "${tmp}"
        blocker_warn "$(m "lignes non reconnues dans" "unrecognised lines in") ${BLOCKER_CONF} : $(m "elles sont ignorees" "they are ignored")"
    else
        cp "${BLOCKER_SHAREDIR}/conf/blocker.conf" "${tmp}"
    fi
    blocker_publier "${tmp}" "${BLOCKER_CONF_EN_VIGUEUR}"
    rm -f "${tmp}"
    blocker_info "$(m "configuration en vigueur" "configuration in force") : ${BLOCKER_CONF_EN_VIGUEUR}"
}

# Regles auditd effectives : le modele, dont les lignes visant un chemin
# inexistant sont mises en commentaire. Le noyau refuse une surveillance dont
# le repertoire parent n'existe pas, et « auditctl -R » s'arrete a la premiere
# erreur : une seule regle sur /etc/brave, sans Brave installe, empechait le
# chargement de toutes les suivantes. Le self-heal regenere le fichier, ce qui
# active les regles d'un navigateur installe plus tard.
blocker_regles_audit() {
    local modele="${1:-${BLOCKER_SHAREDIR}/conf/audit-blocker-adulte.rules}" ligne chemin
    while IFS= read -r ligne; do
        chemin=""
        case "${ligne}" in
            "-w "*)
                chemin="${ligne#-w }"; chemin="${chemin%% *}"
                [ -e "${chemin}" ] || [ -d "$(dirname "${chemin}")" ] || chemin="!" ;;
            "-a "*"-F dir="*)
                chemin="${ligne#*-F dir=}"; chemin="${chemin%% *}"
                [ -d "${chemin}" ] || chemin="!" ;;
            "-a "*"-F path="*)
                chemin="${ligne#*-F path=}"; chemin="${chemin%% *}"
                [ -e "${chemin}" ] || chemin="!" ;;
        esac
        if [ "${chemin}" = "!" ]; then
            printf '# (chemin absent sur cette machine) %s\n' "${ligne}"
        else
            printf '%s\n' "${ligne}"
        fi
    done < "${modele}"
}

# Rechargement complet du resolveur. Un SIGHUP ne relit pas les « address= »
# d'un conf-dir : il faut un vrai redemarrage.
blocker_recharger_resolveur() {
    blocker_unit_active blocker-resolver.service 2>/dev/null || return 0
    systemctl restart blocker-resolver.service 2>/dev/null
}

# Un mot par ligne. Les listes d'URL de blocker.conf s'ecrivent sur plusieurs
# lignes, mais la configuration en vigueur peut les avoir ramenees sur une
# seule ; on decoupe donc sur tout espace, sans jamais developper de motif.
blocker_mots() { printf '%s\n' "$1" | tr -s '[:space:]' '\n' | sed '/^$/d'; }

# Avertit la personne de confiance (blocker-rapport --evenement), en arriere-
# plan : un envoi lent ou impossible ne doit jamais bloquer la commande.
blocker_notifier() {
    [ -x "${BLOCKER_LIBDIR}/blocker-rapport" ] || return 0
    ( timeout 120 "${BLOCKER_LIBDIR}/blocker-rapport" --evenement "$*" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
}

# Empreinte SHA-256 d'un fichier.
blocker_empreinte() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

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
