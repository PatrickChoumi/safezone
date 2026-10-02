#!/bin/bash
# blocker-adulte — desinstallation en quatre phases
#
# Installe dans : /usr/sbin/blocker-uninstall
#
# IL N'Y A PAS DE COMMANDE UNIQUE QUI TOUT RETIRE. C'est deliberé.
#
# Le retrait commence par une DEMANDE (« --demander »), qui n'ouvre la phase 1
# qu'apres le delai fixe dans blocker.conf (48 h par defaut, 24 h au minimum),
# puis pendant sept jours. Viennent ensuite quatre phases, chacune demandant
# deux commandes : une pour voir ce qu'elle va faire et obtenir un jeton, une
# pour l'executer avec ce jeton.
#
# POURQUOI UN DELAI
#
# La complexite seule ne retient pas l'auteur de l'outil, qui sait ou sont les
# choses. Un delai, si : une envie dure vingt minutes, pas deux jours. Qui veut
# vraiment retirer l'outil le peut toujours — deux jours plus tard.
#
# CE QUE CE DECOUPAGE N'EST PAS
#
#   - Ce n'est pas un piege. Chaque phase fonctionne, dans l'ordre, jusqu'au
#     retrait complet. La procedure manuelle equivalente (« --manuel ») donne
#     le meme resultat sans passer par ce script.
#   - Il n'y a aucun etat cache. L'avancement est deduit de l'etat reel du
#     systeme ; la demande est un fichier lisible, son echeance est affichee.
#
# Usage :
#   blocker-uninstall --etat              ou est-on, que reste-t-il
#   blocker-uninstall --demander          deposer la demande de desinstallation
#   blocker-uninstall --phase N           ce que la phase fera + son jeton
#   blocker-uninstall --phase N --jeton X executer la phase N
#   blocker-uninstall --manuel            afficher la procedure manuelle

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "blocker-uninstall : doit etre lance en root / must be run as root (sudo)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Francais ou anglais, en autonomie complete
# ---------------------------------------------------------------------------
# Meme raison que pour le bloc d'adaptation a la distribution ci-dessous : la
# phase 3 supprime /usr/lib/blocker-adulte, et la phase 4 s'execute apres. Ce
# script ne peut donc dependre d'aucun fichier du projet. Les quelques lignes
# qui suivent reproduisent lib/blocker-i18n.sh.
_langue() {
    local l
    case "${BLOCKER_LANG:-auto}" in fr|fr_*) printf 'fr\n'; return ;; en|en_*) printf 'en\n'; return ;; esac
    l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    case "${l}" in
        ''|C|C.*|POSIX)
            l="$(sed -n 's/^[[:space:]]*LANG=//p' /etc/locale.conf /etc/default/locale 2>/dev/null \
                 | head -1 | tr -d '"')" ;;
    esac
    case "${l}" in fr*|FR*) printf 'fr\n' ;; *) printf 'en\n' ;; esac
}
BLOCKER_LANGUE="$(_langue)"
m() { if [ "${BLOCKER_LANGUE}" = "en" ]; then printf '%s' "${2-$1}"; else printf '%s' "$1"; fi; }

RUNDIR="/run/blocker-adulte"
OPTOUT_FLAG="${RUNDIR}/uninstall-in-progress"
JETONDIR="${RUNDIR}/jetons"

# Policies navigateur poses par le projet (une par repertoire de navigateur).
POLICIES="
/etc/firefox/policies/policies.json
/etc/firefox-esr/policies/policies.json
/etc/librewolf/policies/policies.json
/etc/waterfox/policies/policies.json
/etc/floorp/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/chromium-browser/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json
/etc/opt/edge/policies/managed/blocker-adulte.json
/etc/vivaldi/policies/managed/blocker-adulte.json
"

# Fichiers que le projet a poses et qui doivent disparaitre.
A_SUPPRIMER="
/etc/nftables/blocker-adulte.nft
/etc/nftables/blocker-adulte-tunnels.nft
/etc/dnsmasq.d/blocker-adulte.conf
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
${POLICIES}"

# Commandes posees dans /usr/sbin. blocker-uninstall lui-meme part en dernier,
# a la phase 4.
SBIN="/usr/sbin/blocker-status /usr/sbin/blocker-update /usr/sbin/blocker-block /usr/sbin/blocker-delai"

# Tables nftables du projet.
TABLES="ip:blocker_adulte_nat ip6:blocker_adulte_nat inet:blocker_adulte
ip:blocker_adulte_base_nat inet:blocker_adulte_base inet:blocker_adulte_tunnels"

# Fichiers a deverrouiller mais qui DOIVENT rester : ils appartiennent au
# systeme, l'outil n'a fait que poser un attribut d'immuabilite dessus.
A_DEVERROUILLER_SEULEMENT="/etc/hosts"

PROTEGES="${A_SUPPRIMER} ${A_DEVERROUILLER_SEULEMENT}"

UNITES="blocker-guard.service blocker-resolver.service
blocker-selfheal.timer blocker-list-update.timer
blocker-policies.path blocker-rapport.timer"

# ---------------------------------------------------------------------------
# Demande de desinstallation et delai
# ---------------------------------------------------------------------------
# Meme format et meme calcul que /usr/lib/blocker-adulte/blocker-delai.sh,
# refaits ici pour la meme raison que le reste : ce script doit fonctionner
# quand la bibliotheque n'est plus la. tests/test_coherence.sh verifie que les
# deux restent d'accord (plancher de 24 h, fenetre de 168 h).
#
# L'age d'une demande se lit sur le ctime de son fichier, que le noyau tient a
# jour et qu'aucune commande ordinaire ne peut antidater.
DEMANDES="/var/lib/blocker-adulte/delai/demandes"
VALIDITE_HEURES=168

delai_heures() {
    local h
    h="$(sed -n "s/^BLOCKER_DELAI_HEURES=[\"']\{0,1\}\([0-9][0-9]*\).*/\1/p" \
         /var/lib/blocker-adulte/conf/blocker.conf 2>/dev/null | tail -1)"
    case "${h}" in ''|*[!0-9]*) h=48 ;; esac
    [ "${h}" -lt 24 ] && h=24
    printf '%s' "${h}"
}

ctime() { stat -c %Z "$1" 2>/dev/null || printf '0'; }

# Demande de desinstallation la plus recente, ou rien.
demande_courante() {
    local f dernier=""
    for f in "${DEMANDES}"/*-desinstallation-*; do
        [ -f "${f}" ] || continue
        case "${f}" in *.*) continue ;; esac
        dernier="${f}"
    done
    printf '%s' "${dernier}"
}

echeance() { printf '%s' $(( $(ctime "$1") + $(delai_heures) * 3600 )); }

expiration() {
    local fin p
    fin=$(( $(echeance "$1") + VALIDITE_HEURES * 3600 ))
    if [ -e "$1.phase1" ]; then
        p=$(( $(ctime "$1.phase1") + VALIDITE_HEURES * 3600 ))
        [ "${p}" -gt "${fin}" ] && fin="${p}"
    fi
    printf '%s' "${fin}"
}

# absente | attente | mure | expiree
etat_demande() {
    local d maintenant
    d="$(demande_courante)"
    [ -n "${d}" ] || { printf 'absente'; return; }
    maintenant="$(date +%s)"
    if [ "${maintenant}" -lt "$(echeance "${d}")" ]; then printf 'attente'
    elif [ "${maintenant}" -gt "$(expiration "${d}")" ]; then printf 'expiree'
    else printf 'mure'
    fi
}

date_lisible() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"; }

notifier() {
    [ -x /usr/lib/blocker-adulte/blocker-rapport ] || return 0
    ( timeout 120 /usr/lib/blocker-adulte/blocker-rapport --evenement "$*" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
}

deposer_demande() {
    local d id
    d="$(demande_courante)"
    case "$(etat_demande)" in
        attente|mure)
            printf '  %s\n' "$(m "Une demande est deja en cours :" "A request is already pending:")"
            printf '    %s\n' "$(basename "${d}")"
            afficher_demande
            return 0 ;;
    esac
    install -d -m 0755 "${DEMANDES}" || return 1
    id="$(date '+%Y%m%d-%H%M%S')-desinstallation-$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    {
        printf 'type=desinstallation\n'
        printf 'objet=blocker-adulte\n'
        printf 'deposee=%s\n' "$(date -Is)"
        printf 'par=%s\n' "${SUDO_USER:-root}"
    } > "${DEMANDES}/${id}" || return 1
    chmod 0644 "${DEMANDES}/${id}"
    chattr +i "${DEMANDES}/${id}" 2>/dev/null || true
    if [ -d /var/lib/blocker-adulte/delai ]; then
        printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "deposee desinstallation blocker-adulte" "${id}" \
            >> /var/lib/blocker-adulte/delai/historique 2>/dev/null || true
    fi
    logger -t blocker-adulte -p daemon.notice -- \
        "demande de desinstallation deposee (${id}), phase 1 possible le $(date_lisible "$(echeance "${DEMANDES}/${id}")")" 2>/dev/null || true
    notifier "$(m "demande de desinstallation deposee, phase 1 possible le" "uninstall requested, phase 1 possible on") $(date_lisible "$(echeance "${DEMANDES}/${id}")")"
    printf '\n  %s\n' "$(m "Demande de desinstallation enregistree." "Uninstall request filed.")"
    afficher_demande
}

afficher_demande() {
    local d etat
    d="$(demande_courante)"
    etat="$(etat_demande)"
    case "${etat}" in
        absente)
            note "$(m "Aucune demande de desinstallation. La deposer :" "No uninstall request. File one:")"
            note "  sudo blocker-uninstall --demander"
            note "$(m "La phase 1 sera possible" "Phase 1 will be possible") $(delai_heures) h $(m "plus tard." "later.")" ;;
        attente)
            note "$(m "Phase 1 possible a partir du" "Phase 1 possible from") $(date_lisible "$(echeance "${d}")")."
            note "$(m "Annuler la demande :" "Cancel the request:") sudo blocker-delai --annuler $(basename "${d}")" ;;
        mure)
            note "$(m "Delai passe : phase 1 possible jusqu'au" "Delay over: phase 1 possible until") $(date_lisible "$(expiration "${d}")")." ;;
        expiree)
            note "$(m "La derniere demande a expire sans etre suivie : en deposer une nouvelle." \
                      "The last request expired unused: file a new one.")"
            note "  sudo blocker-uninstall --demander" ;;
    esac
}

# ---------------------------------------------------------------------------
# Adaptation a la distribution, en autonomie complete
# ---------------------------------------------------------------------------
# Ce script REFAIT ici, en petit, ce que /usr/lib/blocker-adulte/blocker-os.sh
# fait pour le reste du projet. C'est une duplication assumee, et c'est la
# seule du depot : la phase 3 supprime /usr/lib/blocker-adulte, et la phase 4
# s'execute apres, dans une invocation distincte. Un desinstalleur qui
# dependrait d'un fichier que lui-meme vient d'effacer serait cassé au moment
# ou l'on en a le plus besoin.

famille_os() {
    local id like
    [ -r /etc/os-release ] || { printf 'inconnue\n'; return; }
    id="$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')"
    like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -1 | tr -d '"')"
    case " ${id} ${like} " in
        *" debian "*|*" ubuntu "*)  printf 'debian\n' ;;
        *" rhel "*|*" fedora "*|*" centos "*) printf 'rhel\n' ;;
        *" arch "*|*" manjaro "*)   printf 'arch\n' ;;
        *" suse "*|*" opensuse "*)  printf 'suse\n' ;;
        *" alpine "*)               printf 'alpine\n' ;;
        *)                          printf 'inconnue\n' ;;
    esac
}

# Le paquet blocker-adulte est-il installe par un gestionnaire de paquets ?
# Une installation par install.sh n'en a pas : les fichiers sont alors retires
# un a un, ce qui est le cas le plus courant hors Debian.
paquet_gere() {
    command -v dpkg-query >/dev/null 2>&1 && \
        dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null \
        | grep -q 'install ok installed' && return 0
    command -v rpm >/dev/null 2>&1 && rpm -q blocker-adulte >/dev/null 2>&1 && return 0
    command -v pacman >/dev/null 2>&1 && pacman -Qi blocker-adulte >/dev/null 2>&1 && return 0
    command -v apk >/dev/null 2>&1 && apk info -e blocker-adulte >/dev/null 2>&1 && return 0
    return 1
}

commande_purge() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt purge blocker-adulte\n'
    elif command -v dnf >/dev/null 2>&1; then   printf 'dnf remove blocker-adulte\n'
    elif command -v pacman >/dev/null 2>&1; then printf 'pacman -Rns blocker-adulte\n'
    elif command -v zypper >/dev/null 2>&1; then printf 'zypper remove blocker-adulte\n'
    elif command -v apk >/dev/null 2>&1; then    printf 'apk del blocker-adulte\n'
    else                                         printf 'apt purge blocker-adulte\n'
    fi
}

purger_paquet() {
    if command -v apt-get >/dev/null 2>&1; then
        run env DEBIAN_FRONTEND=noninteractive apt-get purge -y blocker-adulte
    elif command -v dnf >/dev/null 2>&1; then
        run dnf remove -y blocker-adulte
    elif command -v pacman >/dev/null 2>&1; then
        run pacman -Rns --noconfirm blocker-adulte
    elif command -v zypper >/dev/null 2>&1; then
        run zypper --non-interactive remove blocker-adulte
    elif command -v apk >/dev/null 2>&1; then
        run apk del blocker-adulte
    fi
}

# Les deux emplacements possibles des unites systemd : /usr/lib/systemd/system
# sur une distribution usr-merge, /lib/systemd/system sur les plus anciennes.
# On nettoie les deux, l'un des deux etant en general un lien vers l'autre.
unitdirs() { printf '/usr/lib/systemd/system\n/lib/systemd/system\n'; }

# Fichier charge par nftables.service : /etc/nftables.conf sur Debian, Arch et
# openSUSE, /etc/sysconfig/nftables.conf sur Fedora et RHEL.
nft_persist_file() {
    local ligne f
    if command -v systemctl >/dev/null 2>&1; then
        ligne="$(systemctl cat nftables.service 2>/dev/null | sed -n 's/^ExecStart=.*-f *//p' | head -1)"
        f="$(printf '%s' "${ligne}" | awk '{print $1}')"
        case "${f}" in /*) printf '%s\n' "${f}"; return ;; esac
    fi
    case "$(famille_os)" in
        rhel) printf '/etc/sysconfig/nftables.conf\n' ;;
        *)    printf '/etc/nftables.conf\n' ;;
    esac
}

# Les trois generateurs d'images initramfs supportes. On retire les fichiers
# des trois sans se demander lequel est en service : ce qui n'existe pas n'est
# pas une erreur, et une machine peut en avoir change entre-temps.
initramfs_fichiers() {
    cat <<'LISTE'
/etc/initramfs-tools/hooks/blocker-adulte
/etc/initramfs-tools/scripts/init-bottom/blocker-adulte
/usr/lib/dracut/modules.d/99blocker-adulte
/etc/initcpio/install/blocker-adulte
/etc/initcpio/hooks/blocker-adulte
LISTE
}

initramfs_regenerer() {
    if [ -d /etc/initramfs-tools ] && command -v update-initramfs >/dev/null 2>&1; then
        run update-initramfs -u
    elif command -v dracut >/dev/null 2>&1; then
        run dracut --force --regenerate-all
    elif command -v mkinitcpio >/dev/null 2>&1; then
        run mkinitcpio -P
    else
        note "$(m "aucun generateur d'initramfs present : rien a regenerer." \
                  "no initramfs generator present: nothing to rebuild.")"
    fi
}

# Les valeurs injectees dans la procedure manuelle passent par sed : « & » y
# designe la chaine trouvee, et « | » y est le delimiteur. Une commande
# contenant « && » serait donc reecrite n'importe comment. On les protege.
echapper_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

initramfs_commande_manuelle() {
    if [ -d /etc/initramfs-tools ] && command -v update-initramfs >/dev/null 2>&1; then
        printf 'update-initramfs -u\n'
    elif command -v dracut >/dev/null 2>&1; then
        printf 'dracut --force --regenerate-all\n'
    elif command -v mkinitcpio >/dev/null 2>&1; then
        printf 'mkinitcpio -P\n'
    else
        printf 'true   # aucun generateur d initramfs sur cette machine\n'
    fi
}

userdel_commande_manuelle() {
    if command -v userdel >/dev/null 2>&1; then
        printf 'userdel blocker-adulte && sudo groupdel blocker-adulte\n'
    else
        printf 'deluser --system blocker-adulte\n'
    fi
}

supprimer_utilisateur() {
    if command -v userdel >/dev/null 2>&1; then
        getent passwd blocker-adulte >/dev/null 2>&1 && run userdel blocker-adulte
        getent group  blocker-adulte >/dev/null 2>&1 && run groupdel blocker-adulte
    elif command -v deluser >/dev/null 2>&1; then
        getent passwd blocker-adulte >/dev/null 2>&1 && run deluser --system blocker-adulte
        getent group  blocker-adulte >/dev/null 2>&1 && run delgroup --system blocker-adulte
    else
        note "$(m "ni userdel ni deluser : retirer l'utilisateur blocker-adulte a la main." \
                  "neither userdel nor deluser: remove the blocker-adulte user by hand.")"
    fi
}

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; J=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else
    G=""; R=""; J=""; B=""; Z=""
fi

titre() { printf '\n%s%s%s\n%s\n' "${B}" "$1" "${Z}" "$(printf '%.0s─' $(seq 1 ${#1}))"; }
note()  { printf '  %s\n' "$*"; }
fait()  { printf '  %s✔%s %s\n' "${G}" "${Z}" "$*"; }
reste() { printf '  %s•%s %s\n' "${J}" "${Z}" "$*"; }

run() {
    printf '  + %s\n' "$*"
    "$@" || printf '    %s(%s)%s\n' "${J}" \
        "$(m "echec ignore, on continue" "failure ignored, carrying on")" "${Z}"
}

# ---------------------------------------------------------------------------
# Detection de l'avancement, a partir de l'etat REEL du systeme
# ---------------------------------------------------------------------------
# Aucun fichier compteur : on regarde ce qui est vrai maintenant. Une phase deja
# faite est detectee comme telle meme apres un redemarrage, et la refaire est
# sans effet.

systemd_dispo() { [ -d /run/systemd/system ]; }

unite_encore_active() {
    local u
    for u in ${UNITES}; do
        if systemd_dispo; then
            systemctl is-active --quiet "${u}" 2>/dev/null && return 0
            case "$(systemctl is-enabled "${u}" 2>/dev/null)" in
                enabled|enabled-runtime) return 0 ;;
            esac
        fi
    done
    # Hors systemd : on regarde le processus du resolveur.
    pidof dnsmasq >/dev/null 2>&1 && return 0
    return 1
}

fichier_encore_immuable() {
    local f
    command -v lsattr >/dev/null 2>&1 || return 1
    for f in ${PROTEGES}; do
        [ -e "${f}" ] || continue
        local d; d="$(lsattr -d "${f}" 2>/dev/null)"; d="${d%% *}"
        case "${d}" in *i*) return 0 ;; esac
    done
    local d
    while IFS= read -r d; do
        if lsattr -R -a "${d}" 2>/dev/null | awk '{print $1}' | grep -q '[ia]'; then
            return 0
        fi
    done <<EOF
$(zone_etat_hors_demandes)
EOF
    return 1
}

paquet_encore_la() {
    [ -d /usr/lib/blocker-adulte ] && return 0
    paquet_gere && return 0
    local f
    for f in ${A_SUPPRIMER} ${SBIN}; do [ -e "${f}" ] && return 0; done
    return 1
}

traces_encore_la() {
    local f nftmain
    while IFS= read -r f; do
        [ -e "${f}" ] && return 0
    done <<EOF
$(initramfs_fichiers)
EOF
    [ -e /etc/audit/rules.d/blocker-adulte.rules ] && return 0
    [ -d /var/lib/blocker-adulte ] && return 0
    getent passwd blocker-adulte >/dev/null 2>&1 && return 0
    command -v nft >/dev/null 2>&1 && \
        nft list ruleset 2>/dev/null | grep -q blocker_adulte && return 0
    nftmain="$(nft_persist_file)"
    [ -e "${nftmain}" ] && grep -qF blocker-adulte "${nftmain}" 2>/dev/null && return 0
    return 1
}

phase_faite() {
    case "$1" in
        1) unite_encore_active       && return 1 || return 0 ;;
        2) fichier_encore_immuable   && return 1 || return 0 ;;
        3) paquet_encore_la          && return 1 || return 0 ;;
        4) traces_encore_la          && return 1 || return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Jetons
# ---------------------------------------------------------------------------
# Tire au hasard a chaque affichage, donc impossible a preparer d'avance dans un
# script : il faut lire la sortie de la phase pour pouvoir la lancer. C'est tout
# le mecanisme de friction, et il n'y en a pas d'autre.
nouveau_jeton() {
    local phase="$1" jeton
    install -d -m 0700 "${JETONDIR}"
    jeton="$(tr -dc 'A-HJ-NP-Z2-9' </dev/urandom | head -c 6)"
    printf '%s' "${jeton}" > "${JETONDIR}/phase${phase}"
    printf '%s' "${jeton}"
}

jeton_valide() {
    local phase="$1" fourni="$2" attendu
    [ -r "${JETONDIR}/phase${phase}" ] || return 1
    attendu="$(cat "${JETONDIR}/phase${phase}")"
    [ -n "${attendu}" ] && [ "${fourni}" = "${attendu}" ]
}

poser_drapeau_retrait() {
    # Pose des la premiere phase : tant qu'il existe, aucun watchdog ne repare
    # quoi que ce soit. C'est ce qui rend la suite fiable au lieu d'etre un bras
    # de fer avec les composants encore vivants.
    install -d -m 0755 "${RUNDIR}"
    if [ ! -e "${OPTOUT_FLAG}" ]; then
        printf 'Desinstallation lancee le %s par %s\n' \
            "$(date -Is)" "${SUDO_USER:-root}" > "${OPTOUT_FLAG}"
        logger -t blocker-adulte -p daemon.notice -- \
            "desinstallation volontaire : les watchdogs se mettent en retrait" 2>/dev/null || true
        note "$(m "Drapeau de retrait volontaire pose" "Voluntary-removal flag set") : ${OPTOUT_FLAG}"
        note "$(m "Les watchdogs cessent toute reparation dans les 15 secondes." \
                  "The watchdogs stop repairing anything within 15 seconds.")"
    fi
}

# ---------------------------------------------------------------------------
# Etat
# ---------------------------------------------------------------------------
afficher_etat() {
    titre "$(m "Etat de la desinstallation" "Uninstall progress")"

    if ! phase_faite 1; then
        afficher_demande
        printf '\n'
    fi

    local restantes=0 n
    for n in 1 2 3 4; do
        local libelle
        case "${n}" in
            1) libelle="$(m "Phase 1 — arret des watchdogs et des timers" \
                            "Phase 1 — stop the watchdogs and timers")" ;;
            2) libelle="$(m "Phase 2 — levee de l'immuabilite des fichiers" \
                            "Phase 2 — lift file immutability")" ;;
            3) libelle="$(m "Phase 3 — retrait du paquet et des policies navigateur" \
                            "Phase 3 — remove the package and the browser policies")" ;;
            4) libelle="$(m "Phase 4 — initramfs, nftables, auditd, utilisateur systeme" \
                            "Phase 4 — initramfs, nftables, auditd, system user")" ;;
        esac
        if phase_faite "${n}"; then
            fait "${libelle}"
        else
            reste "${libelle}"
            restantes=$((restantes + 1))
        fi
    done

    printf '\n'
    if [ "${restantes}" -eq 0 ]; then
        printf '  %s%s%s\n' "${G}" \
            "$(m "blocker-adulte est entierement retire." "blocker-adulte is fully removed.")" "${Z}"
        if [ -e "$(nft_persist_file).avant-blocker-adulte" ]; then
            printf '\n  %s\n' "$(m "Un fichier a ete laisse volontairement :" \
                                     "One file was left behind on purpose:")"
            printf '    %s.avant-blocker-adulte\n' "$(nft_persist_file)"
            printf '  %s %s.\n' \
                "$(m "C est la sauvegarde de votre" "This is the backup of your")" \
                "$(nft_persist_file)"
            printf '  %s\n' "$(m "La supprimer une fois le fichier courant verifie." \
                                 "Delete it once you have checked the current file.")"
        fi
        return 0
    fi

    local suivante=0
    for n in 1 2 3 4; do
        if ! phase_faite "${n}"; then suivante="${n}"; break; fi
    done

    printf '  %d %s\n\n' "${restantes}" \
        "$(m "phase(s) restante(s). Prochaine etape :" "phase(s) left. Next step:")"
    printf '    sudo blocker-uninstall --phase %d\n\n' "${suivante}"
    printf '  %s : sudo blocker-uninstall --manuel\n' \
        "$(m "Procedure manuelle equivalente" "Equivalent manual procedure")"
    return 0
}

# ---------------------------------------------------------------------------
# Description des phases
# ---------------------------------------------------------------------------
decrire_phase() {
    case "$1" in
        1)
            titre "$(m "Phase 1 sur 4 — arret des watchdogs et des timers" \
                       "Phase 1 of 4 — stop the watchdogs and timers")"
            note "$(m "Pose le drapeau de retrait volontaire, puis desactive et arrete," \
                      "Sets the voluntary-removal flag, then disables and stops,")"
            note "$(m "dans cet ordre impose :" "in this enforced order:")"
            note "  1. blocker-guard.service    $(m "(c'est elle qui relance le resolveur)" \
                                                    "(this is the one that restarts the resolver)")"
            note "  2. blocker-resolver.service"
            note "  3. $(m "les timers et l'unite path" "the timers and the path unit")"
            note "$(m "La personne de confiance en est prevenue, si un rapport est configure." \
                      "The trusted person is told, if a report is configured.")"
            printf '\n'
            note "$(m "APRES CETTE PHASE : le filtrage DNS s'arrete. Les regles nftables" \
                      "AFTER THIS PHASE: DNS filtering stops. The nftables rules stay")"
            note "$(m "restent chargees et redirigent vers un resolveur eteint, donc la" \
                      "loaded and redirect to a resolver that is down, so DNS resolution")"
            note "$(m "resolution DNS sera cassee jusqu'a la phase 4. C'est normal et" \
                      "will be broken until phase 4. This is normal and temporary —")"
            note "$(m "temporaire — allez au bout, ou relancez les services pour annuler." \
                      "go all the way, or restart the services to cancel.")"
            ;;
        2)
            titre "$(m "Phase 2 sur 4 — levee de l'immuabilite" \
                       "Phase 2 of 4 — lift immutability")"
            note "$(m "Retire l'attribut chattr +i de chaque fichier protege :" \
                      "Removes the chattr +i attribute from every protected file:")"
            local f
            for f in ${PROTEGES}; do
                [ -e "${f}" ] && note "    ${f}"
            done
            printf '\n'
            note "$(m "Sans cette phase, ni le gestionnaire de paquets ni rm ne peuvent" \
                      "Without this phase, neither the package manager nor rm can")"
            note "$(m "supprimer ces fichiers." "delete these files.")"
            note "$(m "/etc/hosts est deverrouille mais JAMAIS supprime : il appartient" \
                      "/etc/hosts is unlocked but NEVER deleted: it belongs to the")"
            note "$(m "au systeme, l'outil n'a fait qu'y poser un attribut." \
                      "system, the tool only set an attribute on it.")"
            ;;
        3)
            titre "$(m "Phase 3 sur 4 — paquet et policies navigateur" \
                       "Phase 3 of 4 — package and browser policies")"
            if paquet_gere; then
                note "$(commande_purge)"
            else
                note "$(m "Suppression manuelle (installation par install.sh) :" \
                          "Manual removal (installed by install.sh):")"
                note "  /usr/lib/blocker-adulte, /usr/share/blocker-adulte,"
                note "  /usr/share/doc/blocker-adulte, /etc/blocker-adulte,"
                note "$(m "  les unites systemd et les fichiers de configuration." \
                          "  the systemd units and the configuration files.")"
            fi
            printf '\n'
            note "$(m "Puis les fichiers de policies navigateur, que le retrait du" \
                      "Then the browser policy files, which removing the package")"
            note "$(m "paquet ne touche pas (leurs repertoires appartiennent aux" \
                      "does not touch (their directories belong to the browsers), and")"
            note "$(m "navigateurs), et les liens d'activation systemd restes pendants." \
                      "the systemd enablement links left dangling.")"
            ;;
        4)
            titre "$(m "Phase 4 sur 4 — initramfs, nftables, auditd, utilisateur" \
                       "Phase 4 of 4 — initramfs, nftables, auditd, user")"
            note "$(m "  - retrait du hook initramfs puis reconstruction de l'image" \
                      "  - remove the initramfs hook, then rebuild the image")"
            note "$(m "    (sans quoi les regles de base seraient rechargees a chaque boot)" \
                      "    (otherwise the base rules would reload at every boot)")"
            note "$(m "  - suppression des six tables nftables chargees en memoire" \
                      "  - delete the six nftables tables loaded in memory")"
            note "$(m "    (les fichiers ne suffisent pas : ce sont des objets du noyau)" \
                      "    (files are not enough: these are kernel objects)")"
            note "$(m "  - retrait de la ligne d'inclusion de" "  - remove the include line from") $(nft_persist_file),"
            note "$(m "    avec sauvegarde dans" "    with a backup in") $(nft_persist_file).avant-blocker-adulte"
            note "$(m "  - retrait des regles auditd et de l'utilisateur systeme" \
                      "  - remove the auditd rules and the system user")"
            printf '\n'
            note "$(m "APRES CETTE PHASE : la resolution DNS redevient normale." \
                      "AFTER THIS PHASE: DNS resolution goes back to normal.")"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Execution des phases
# ---------------------------------------------------------------------------
executer_phase_1() {
    local d
    d="$(demande_courante)"
    if [ -n "${d}" ] && [ ! -e "${d}.phase1" ]; then
        date -Is > "${d}.phase1" && chattr +i "${d}.phase1" 2>/dev/null
    fi
    poser_drapeau_retrait
    notifier "$(m "desinstallation : phase 1 executee (filtrage arrete)" "uninstall: phase 1 run (filtering stopped)")"
    titre "$(m "Execution de la phase 1" "Running phase 1")"

    # « disable » avant « stop » : une unite desactivee est traitee comme un
    # retrait volontaire par le code de garde, qui n'essaiera pas de la relancer.
    for u in blocker-guard.service blocker-resolver.service \
             blocker-selfheal.timer blocker-list-update.timer \
             blocker-policies.path blocker-rapport.timer; do
        run systemctl disable "${u}"
        run systemctl stop "${u}"
    done
    run systemctl stop blocker-selfheal.service
    run systemctl stop blocker-list-update.service
    run systemctl stop blocker-rapport.service

    # Hors systemd, le resolveur peut tourner en direct.
    if ! systemd_dispo && pidof dnsmasq >/dev/null 2>&1; then
        note "$(m "systemd absent : arret direct du processus dnsmasq" \
                  "systemd absent: stopping the dnsmasq process directly")"
        for p in $(pidof dnsmasq); do
            grep -qa 'blocker-adulte' "/proc/${p}/cmdline" 2>/dev/null && run kill "${p}"
        done
    fi
}

executer_phase_2() {
    poser_drapeau_retrait
    titre "$(m "Execution de la phase 2" "Running phase 2")"
    for f in ${PROTEGES}; do
        if [ -e "${f}" ]; then
            run chattr -i "${f}"
        fi
    done
    # Zone d'etat : listes, reserve, configuration en vigueur. PAS le
    # repertoire des demandes : changer un attribut change le ctime, qui date
    # la demande — le delai repartirait de zero et les phases suivantes
    # seraient refusees. Il est leve a la phase 4.
    zone_etat_hors_demandes | while IFS= read -r d; do
        run chattr -R -i -a "${d}"
    done
}

# Sous-repertoires de la zone d'etat, sauf celui des demandes.
zone_etat_hors_demandes() {
    local d
    [ -d /var/lib/blocker-adulte ] || return 0
    for d in /var/lib/blocker-adulte/*; do
        [ -e "${d}" ] || continue
        [ "${d}" = "/var/lib/blocker-adulte/delai" ] && continue
        printf '%s\n' "${d}"
    done
}

executer_phase_3() {
    poser_drapeau_retrait
    titre "$(m "Execution de la phase 3" "Running phase 3")"

    if paquet_gere; then
        purger_paquet
    else
        note "$(m "Aucun paquet gere par la distribution : suppression manuelle." \
                  "No distribution-managed package: removing the files manually.")"
        run rm -rf /usr/lib/blocker-adulte
        run rm -rf /usr/share/blocker-adulte
        run rm -rf /usr/share/doc/blocker-adulte
        while IFS= read -r d; do
            [ -d "${d}" ] || continue
            run rm -f "${d}/blocker-resolver.service" \
                      "${d}/blocker-guard.service" \
                      "${d}/blocker-selfheal.service" \
                      "${d}/blocker-selfheal.timer" \
                      "${d}/blocker-list-update.service" \
                      "${d}/blocker-list-update.timer" \
                      "${d}/blocker-policies.path" \
                      "${d}/blocker-policies.service" \
                      "${d}/blocker-rapport.service" \
                      "${d}/blocker-rapport.timer"
        done <<EOF
$(unitdirs)
EOF
        run rm -f ${SBIN}
        run rm -f /etc/dnsmasq.d/blocker-adulte.conf
        run rm -f /etc/nftables/blocker-adulte.nft
        run rm -f /etc/nftables/blocker-adulte-tunnels.nft
        run rm -f /etc/systemd/resolved.conf.d/blocker-adulte.conf
        run rm -f /etc/NetworkManager/dispatcher.d/90-blocker-adulte
        run rm -f /etc/pacman.d/hooks/95-blocker-adulte.hook
        run rm -rf /etc/blocker-adulte
    fi

    note "$(m "Policies navigateur :" "Browser policies:")"
    for f in ${POLICIES}; do
        [ -e "${f}" ] || continue
        run rm -f "${f}"
        d="$(dirname "${f}")"
        if [ -d "${d}" ] && [ -z "$(ls -A "${d}" 2>/dev/null)" ]; then
            run rmdir "${d}"
        fi
    done

    # Liens d'activation pendants : sans cela systemd affiche des unites
    # « not-found », exactement le service fantome que l'on veut eviter.
    note "Liens d'activation systemd :"
    for lien in /etc/systemd/system/*.target.wants/blocker-*; do
        [ -e "${lien}" ] || [ -L "${lien}" ] || continue
        run rm -f "${lien}"
    done
    run systemctl daemon-reload
}

executer_phase_4() {
    titre "$(m "Execution de la phase 4" "Running phase 4")"

    note "$(m "Hook initramfs :" "Initramfs hook:")"
    while IFS= read -r f; do
        [ -e "${f}" ] && run rm -rf "${f}"
    done <<EOF
$(initramfs_fichiers)
EOF
    # Arch : le hook n'est actif que s'il est liste dans HOOKS. La ligne a pu
    # etre ajoutee par blocker-configure ; on la retire avant de reconstruire,
    # sinon mkinitcpio refuserait de trouver le hook qu'on vient d'effacer.
    if [ -e /etc/mkinitcpio.conf ] && grep -qE '^HOOKS=.*blocker-adulte' /etc/mkinitcpio.conf; then
        cp -a /etc/mkinitcpio.conf /etc/mkinitcpio.conf.avant-blocker-adulte
        sed -i -E 's/^(HOOKS=.*)[[:space:]]+blocker-adulte/\1/' /etc/mkinitcpio.conf
        note "+ hook retire de HOOKS (sauvegarde : /etc/mkinitcpio.conf.avant-blocker-adulte)"
    fi
    initramfs_regenerer

    note "$(m "Regles nftables :" "nftables rules:")"
    NFTMAIN="$(nft_persist_file)"
    if [ -e "${NFTMAIN}" ] && grep -qF 'blocker-adulte' "${NFTMAIN}"; then
        cp -a "${NFTMAIN}" "${NFTMAIN}.avant-blocker-adulte"
        sed -i '/blocker-adulte/d' "${NFTMAIN}"
        note "+ ligne d'inclusion retiree (sauvegarde : ${NFTMAIN}.avant-blocker-adulte)"
    fi
    if command -v nft >/dev/null 2>&1; then
        for t in ${TABLES}; do
            if nft list table "${t%%:*}" "${t#*:}" >/dev/null 2>&1; then
                run nft delete table "${t%%:*}" "${t#*:}"
            fi
        done
    fi

    note "auditd :"
    run rm -f /etc/audit/rules.d/blocker-adulte.rules
    command -v augenrules >/dev/null 2>&1 && run augenrules --load

    note "$(m "Etat et utilisateur systeme :" "State and system user:")"
    chattr -R -i -a /var/lib/blocker-adulte 2>/dev/null || true
    run rm -rf /var/lib/blocker-adulte
    supprimer_utilisateur

    run systemctl daemon-reload
    run systemctl reset-failed
    systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 && \
        run systemctl restart systemd-resolved.service

    run rm -rf "${RUNDIR}"
    run rm -f /usr/sbin/blocker-uninstall
}

# ---------------------------------------------------------------------------
# Procedure manuelle
# ---------------------------------------------------------------------------
afficher_manuel() {
    titre "$(m "Procedure manuelle equivalente" "Equivalent manual procedure")"
    # Le texte est fige (heredoc protege), mais les commandes qui dependent de
    # la distribution y sont laissees en marqueurs et remplacees ici. La
    # procedure affichee est donc celle de LA machine, pas celle de Debian
    # recopiee partout : une procedure manuelle qui ne marche pas sur la
    # machine ou on la lit ne vaut rien.
    cat <<'EOF' | sed \
        -e "s|@PURGE@|$(echapper_sed "$(commande_purge)")|g" \
        -e "s|@NFTMAIN@|$(echapper_sed "$(nft_persist_file)")|g" \
        -e "s|@INITRAMFS@|$(echapper_sed "$(initramfs_commande_manuelle)")|g" \
        -e "s|@USERDEL@|$(echapper_sed "$(userdel_commande_manuelle)")|g" \
        -e "s|@INTRO@|$(echapper_sed "$(m \
            "Ce script n'est pas indispensable : les commandes ci-dessous font exactement la meme chose." \
            "This script is not required: the commands below do exactly the same thing.")")|g" \
        -e "s|@INTRO2@|$(echapper_sed "$(m \
            "Elles sont aussi dans le README, section « Desinstallation »." \
            "They are also in the README, section « Uninstalling ».")")|g" \
        -e "s|@P0@|$(echapper_sed "$(m \
            "Phase 0 — la demande, puis le delai" \
            "Phase 0 — the request, then the delay")")|g" \
        -e "s|@P0B@|$(echapper_sed "$(m \
            "# attendre le delai ($(delai_heures) h) : avant, les watchdogs remettent tout en place" \
            "# wait for the delay ($(delai_heures) h): before that, the watchdogs put everything back")")|g" \
        -e "s|@P1@|$(echapper_sed "$(m \
            "Phase 1 — watchdogs et timers (la garde d abord, elle relance le resolveur)" \
            "Phase 1 — watchdogs and timers (the guard first, it restarts the resolver)")")|g" \
        -e "s|@P2@|$(echapper_sed "$(m "Phase 2 — immuabilite" "Phase 2 — immutability")")|g" \
        -e "s|@P3@|$(echapper_sed "$(m "Phase 3 — paquet et policies" "Phase 3 — package and policies")")|g" \
        -e "s|@P3C@|$(echapper_sed "$(m "ou suppression manuelle, voir README" "or manual removal, see README")")|g" \
        -e "s|@P4@|$(echapper_sed "$(m \
            "Phase 4 — initramfs, nftables, auditd, utilisateur" \
            "Phase 4 — initramfs, nftables, auditd, user")")|g" \
        -e "s|@FIN@|$(echapper_sed "$(m "Verification finale" "Final check")")|g"
  @INTRO@
  @INTRO2@

  @P0@
    sudo blocker-uninstall --demander
    @P0B@

  @P1@
    sudo mkdir -p /run/blocker-adulte
    echo manuel | sudo tee /run/blocker-adulte/uninstall-in-progress
    sudo systemctl disable --now blocker-guard.service
    sudo systemctl disable --now blocker-resolver.service
    sudo systemctl disable --now blocker-selfheal.timer blocker-list-update.timer
    sudo systemctl disable --now blocker-policies.path blocker-rapport.timer

  @P2@
    sudo chattr -i /etc/hosts /etc/nftables/blocker-adulte.nft \
        /etc/nftables/blocker-adulte-tunnels.nft \
        /etc/dnsmasq.d/blocker-adulte.conf \
        /etc/systemd/resolved.conf.d/blocker-adulte.conf \
        /etc/NetworkManager/dispatcher.d/90-blocker-adulte
    sudo chattr -i /etc/*/policies/policies.json /etc/*/policies/managed/blocker-adulte.json \
        /etc/opt/*/policies/managed/blocker-adulte.json
    sudo chattr -R -i -a /var/lib/blocker-adulte/blocklists /var/lib/blocker-adulte/reserve \
        /var/lib/blocker-adulte/conf /var/lib/blocker-adulte/nft

  @P3@
    sudo @PURGE@        # @P3C@
    sudo rm -f /etc/*/policies/policies.json /etc/*/policies/managed/blocker-adulte.json \
        /etc/opt/*/policies/managed/blocker-adulte.json
    sudo rm -f /usr/sbin/blocker-status /usr/sbin/blocker-update \
        /usr/sbin/blocker-block /usr/sbin/blocker-delai
    sudo rm -f /etc/systemd/system/*.target.wants/blocker-*

  @P4@
    sudo rm -rf /etc/initramfs-tools/hooks/blocker-adulte \
               /etc/initramfs-tools/scripts/init-bottom/blocker-adulte \
               /usr/lib/dracut/modules.d/99blocker-adulte \
               /etc/initcpio/install/blocker-adulte \
               /etc/initcpio/hooks/blocker-adulte
    sudo @INITRAMFS@
    sudo sed -i '/blocker-adulte/d' @NFTMAIN@
    sudo nft delete table ip blocker_adulte_nat
    sudo nft delete table ip6 blocker_adulte_nat
    sudo nft delete table inet blocker_adulte
    sudo nft delete table inet blocker_adulte_tunnels
    sudo nft delete table ip blocker_adulte_base_nat
    sudo nft delete table inet blocker_adulte_base
    sudo rm -f /etc/audit/rules.d/blocker-adulte.rules && sudo augenrules --load
    sudo chattr -R -i -a /var/lib/blocker-adulte
    sudo rm -rf /var/lib/blocker-adulte /run/blocker-adulte
    sudo @USERDEL@
    sudo systemctl daemon-reload && sudo systemctl restart systemd-resolved

  @FIN@
    sudo find / -xdev -name '*blocker-adulte*'
    sudo nft list ruleset | grep blocker
    systemctl list-units --all 'blocker-*'
EOF
}

# ---------------------------------------------------------------------------
# Ligne de commande
# ---------------------------------------------------------------------------
PHASE=""
JETON=""

if [ $# -eq 0 ]; then
    if [ "${BLOCKER_LANGUE}" = "en" ]; then
        cat <<'EOF'
blocker-adulte — uninstalling

There is no single command that removes everything. Removal starts with a
request, which opens phase 1 only after the delay set in blocker.conf (48 h by
default). Then come four phases, each one taking two commands. This is
deliberate, and it is not a trap — see « --manual » for the equivalent
procedure.

  sudo blocker-uninstall --status     where we stand
  sudo blocker-uninstall --request    file the request
  sudo blocker-uninstall --phase 1    after the delay
  sudo blocker-uninstall --manual     equivalent manual procedure
EOF
    else
        cat <<'EOF'
blocker-adulte — desinstallation

Il n'y a pas de commande unique qui tout retire. Le retrait commence par une
demande, qui n'ouvre la phase 1 qu'apres le delai fixe dans blocker.conf (48 h
par defaut). Viennent ensuite quatre phases, chacune demandant deux commandes.
C'est delibere, et ce n'est pas un piege — voir « --manuel » pour la procedure
equivalente.

  sudo blocker-uninstall --etat       ou en est-on
  sudo blocker-uninstall --demander   deposer la demande
  sudo blocker-uninstall --phase 1    apres le delai
  sudo blocker-uninstall --manuel     procedure manuelle equivalente
EOF
    fi
    afficher_etat
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --etat|--status) afficher_etat; exit 0 ;;
        --manuel|--manual) afficher_manuel; exit 0 ;;
        --demander|--request) deposer_demande; exit $? ;;
        --phase) PHASE="${2:-}"; shift ;;
        --jeton|--token) JETON="${2:-}"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --confirm)
            if [ "${BLOCKER_LANGUE}" = "en" ]; then
                cat >&2 <<'EOF'
« --confirm » no longer exists.

A single command can no longer remove everything: that is the point. Removal
starts with a request, then waits for the delay.

  sudo blocker-uninstall --status     see where we stand
  sudo blocker-uninstall --request    file the request
EOF
            else
                cat >&2 <<'EOF'
« --confirm » n'existe plus.

Une seule commande ne peut plus tout retirer : c'est le but. Le retrait
commence par une demande, puis attend le delai.

  sudo blocker-uninstall --etat       voir ou on en est
  sudo blocker-uninstall --demander   deposer la demande
EOF
            fi
            exit 2
            ;;
        *) echo "Argument inconnu / unknown argument : $1" >&2; exit 2 ;;
    esac
    shift
done

case "${PHASE}" in
    1|2|3|4) ;;
    *) echo "$(m "Phase invalide" "Invalid phase") : « ${PHASE} ». $(m "Attendu 1, 2, 3 ou 4." "Expected 1, 2, 3 or 4.")" >&2; exit 2 ;;
esac

# --- Phase deja faite ? -----------------------------------------------------
if phase_faite "${PHASE}"; then
    printf '\n  %s%s %s %s%s\n' "${G}" "$(m "La phase" "Phase")" "${PHASE}" \
        "$(m "est deja faite." "is already done.")" "${Z}"
    afficher_etat
    exit 0
fi

# --- Les phases precedentes sont-elles faites ? -----------------------------
n=1
while [ "${n}" -lt "${PHASE}" ]; do
    if ! phase_faite "${n}"; then
        printf '\n  %s%s %d %s %s.%s\n' "${R}" \
            "$(m "La phase" "Phase")" "${n}" \
            "$(m "doit etre faite avant la phase" "must be done before phase")" "${PHASE}" "${Z}"
        printf '  %s\n' "$(m "L ordre compte : les watchdogs se relancent mutuellement, et les" \
                              "Order matters: the watchdogs restart each other, and immutable")"
        printf '  %s\n\n' "$(m "fichiers immuables ne peuvent pas etre supprimes." \
                                "files cannot be deleted.")"
        printf '    sudo blocker-uninstall --phase %d\n' "${n}"
        exit 1
    fi
    n=$((n + 1))
done

# --- Phases 1 a 3 : seulement apres le delai ---------------------------------
# Les trois phases qui retirent la protection exigent une demande arrivee a
# echeance — la phase 1 seule ne suffirait pas : des services arretes a la main
# la feraient passer pour faite. La phase 4, elle, rend a la machine un DNS
# normal : elle n'est jamais bloquee.
if [ "${PHASE}" != "4" ] && [ "$(etat_demande)" != "mure" ]; then
    titre "$(m "Phase" "Phase") ${PHASE} — $(m "pas encore" "not yet")"
    afficher_demande
    printf '\n'
    note "$(m "Toute desinstallation passe par une demande, puis un delai de" \
              "Every uninstall goes through a request, then a delay of") $(delai_heures) h."
    note "$(m "Une envie dure vingt minutes, pas deux jours." "A craving lasts twenty minutes, not two days.")"
    exit 1
fi

# --- Sans jeton : on decrit et on en delivre un -----------------------------
if [ -z "${JETON}" ]; then
    decrire_phase "${PHASE}"
    jeton="$(nouveau_jeton "${PHASE}")"
    printf '\n  %s\n\n' "$(m "Pour executer cette phase :" "To run this phase:")"
    printf '    %ssudo blocker-uninstall --phase %s %s %s%s\n\n' \
        "${B}" "${PHASE}" "$(m "--jeton" "--token")" "${jeton}" "${Z}"
    printf '  %s\n' "$(m "Ce jeton est tire au hasard et change a chaque affichage." \
                            "This token is drawn at random and changes every time it is shown.")"
    printf '  %s\n' "$(m "Rien ne presse : il reste valable tant que la machine n a pas redemarre." \
                          "No hurry: it stays valid until the machine reboots.")"
    exit 0
fi

# --- Avec jeton : on verifie et on execute ----------------------------------
if ! jeton_valide "${PHASE}" "${JETON}"; then
    printf '\n  %s%s %s.%s\n\n' "${R}" \
        "$(m "Jeton invalide ou expire pour la phase" "Invalid or expired token for phase")" \
        "${PHASE}" "${Z}"
    printf '  %s\n\n' "$(m "Obtenir un nouveau jeton :" "Get a new token:")"
    printf '    sudo blocker-uninstall --phase %s\n' "${PHASE}"
    exit 1
fi

rm -f "${JETONDIR}/phase${PHASE}"

case "${PHASE}" in
    1) executer_phase_1 ;;
    2) executer_phase_2 ;;
    3) executer_phase_3 ;;
    4) executer_phase_4 ;;
esac

printf '\n'
if phase_faite "${PHASE}"; then
    printf '  %s%s %s %s%s\n' "${G}" "$(m "Phase" "Phase")" "${PHASE}" \
        "$(m "terminee." "completed.")" "${Z}"
else
    printf '  %s%s %s %s%s\n' "${J}" "$(m "Phase" "Phase")" "${PHASE}" \
        "$(m "executee, mais l etat attendu n est pas atteint." \
             "ran, but the expected state was not reached.")" "${Z}"
    printf '  %s\n' "$(m "Relancer la phase, ou suivre la procedure manuelle : --manuel" \
                          "Run the phase again, or follow the manual procedure: --manual")"
fi

afficher_etat

# Verification finale apres la derniere phase.
if [ "${PHASE}" = "4" ]; then
    restes=0
    for f in ${A_SUPPRIMER} ${SBIN} /usr/lib/blocker-adulte /usr/share/blocker-adulte \
             /usr/share/doc/blocker-adulte /var/lib/blocker-adulte \
             /etc/blocker-adulte /run/blocker-adulte \
             /etc/initramfs-tools/hooks/blocker-adulte \
             /etc/audit/rules.d/blocker-adulte.rules; do
        if [ -e "${f}" ]; then printf '  RESTE : %s\n' "${f}"; restes=$((restes + 1)); fi
    done
    if [ "${restes}" -gt 0 ]; then
        printf '\n  %d residu(s). Les traiter a la main puis relancer --etat.\n' "${restes}"
        exit 1
    fi
fi

exit 0
