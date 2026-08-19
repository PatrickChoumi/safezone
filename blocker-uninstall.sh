#!/bin/bash
# blocker-adulte — desinstallation en quatre phases
#
# Installe dans : /usr/sbin/blocker-uninstall
#
# IL N'Y A PAS DE COMMANDE UNIQUE QUI TOUT RETIRE. C'est deliberé.
#
# Le retrait se fait en quatre phases, chacune demandant deux commandes : une
# pour voir ce qu'elle va faire et obtenir un jeton, une pour l'executer avec ce
# jeton. Soit huit commandes au total, et il faut lire l'ecran a chaque fois
# puisque le jeton est tire au hasard a chaque affichage.
#
# CE QUE CE DECOUPAGE N'EST PAS
#
#   - Ce n'est pas une minuterie. Aucune phase ne fait attendre. Qui veut aller
#     au bout y va tout de suite, il faut simplement le vouloir huit fois.
#   - Ce n'est pas un piege. Chaque phase fonctionne, dans l'ordre, jusqu'au
#     retrait complet. La procedure manuelle equivalente est dans le README et
#     donne exactement le meme resultat sans jamais passer par ce script.
#   - Il n'y a aucun etat cache. L'avancement est deduit de l'etat reel du
#     systeme, pas d'un fichier compteur : rebooter, sauter une phase ou en
#     refaire une deja faite ne peut pas coincer la desinstallation.
#
# Le but est d'empecher le « sudo blocker-uninstall --confirm » tape sur un coup
# de tete a 2 h du matin. Pas d'empecher quelqu'un de decider, a froid, qu'il ne
# veut plus de cet outil.
#
# Usage :
#   blocker-uninstall --etat              ou est-on, que reste-t-il
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

# Fichiers que le projet a poses et qui doivent disparaitre.
A_SUPPRIMER="
/etc/nftables/blocker-adulte.nft
/etc/dnsmasq.d/blocker-adulte.conf
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
/etc/firefox/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json
"

# Fichiers a deverrouiller mais qui DOIVENT rester : ils appartiennent au
# systeme, l'outil n'a fait que poser un attribut d'immuabilite dessus.
A_DEVERROUILLER_SEULEMENT="/etc/hosts"

PROTEGES="${A_SUPPRIMER} ${A_DEVERROUILLER_SEULEMENT}"

UNITES="blocker-guard.service blocker-resolver.service
blocker-selfheal.timer blocker-list-update.timer
blocker-policies.path"

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
    return 1
}

paquet_encore_la() {
    [ -d /usr/lib/blocker-adulte ] && return 0
    paquet_gere && return 0
    local f
    for f in ${A_SUPPRIMER}; do [ -e "${f}" ] && return 0; done
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
            note "  3. blocker-selfheal.timer $(m "et" "and") blocker-list-update.timer"
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
            note "$(m "Puis les quatre fichiers de policies navigateur, que le retrait du" \
                      "Then the four browser policy files, which removing the package")"
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
            note "$(m "  - suppression des tables nftables chargees en memoire" \
                      "  - delete the nftables tables loaded in memory")"
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
    poser_drapeau_retrait
    titre "$(m "Execution de la phase 1" "Running phase 1")"

    # « disable » avant « stop » : une unite desactivee est traitee comme un
    # retrait volontaire par le code de garde, qui n'essaiera pas de la relancer.
    for u in blocker-guard.service blocker-resolver.service \
             blocker-selfheal.timer blocker-list-update.timer; do
        run systemctl disable "${u}"
        run systemctl stop "${u}"
    done
    run systemctl stop blocker-selfheal.service
    run systemctl stop blocker-list-update.service

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
    titre "Execution de la phase 2"
    for f in ${PROTEGES}; do
        if [ -e "${f}" ]; then
            run chattr -i "${f}"
        else
            note "(absent) ${f}"
        fi
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
                      "${d}/blocker-policies.service"
        done <<EOF
$(unitdirs)
EOF
        run rm -f /etc/dnsmasq.d/blocker-adulte.conf
        run rm -f /etc/nftables/blocker-adulte.nft
        run rm -f /etc/nftables/blocker-adulte-tunnels.nft
        run rm -f /etc/systemd/resolved.conf.d/blocker-adulte.conf
        run rm -f /etc/NetworkManager/dispatcher.d/90-blocker-adulte
        run rm -f /etc/pacman.d/hooks/95-blocker-adulte.hook
        run rm -rf /etc/blocker-adulte
    fi

    note "$(m "Policies navigateur :" "Browser policies:")"
    run rm -f /etc/firefox/policies/policies.json
    run rm -f /etc/opt/chrome/policies/managed/blocker-adulte.json
    run rm -f /etc/chromium/policies/managed/blocker-adulte.json
    run rm -f /etc/opt/chromium/policies/managed/blocker-adulte.json
    run rm -f /etc/brave/policies/managed/blocker-adulte.json

    for d in /etc/firefox/policies /etc/opt/chrome/policies/managed \
             /etc/chromium/policies/managed /etc/opt/chromium/policies/managed \
             /etc/brave/policies/managed; do
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
        for t in "ip blocker_adulte_nat" "ip6 blocker_adulte_nat" "inet blocker_adulte" \
                 "ip blocker_adulte_base_nat" "inet blocker_adulte_base"; do
            # shellcheck disable=SC2086
            if nft list table ${t} >/dev/null 2>&1; then
                # shellcheck disable=SC2086
                run nft delete table ${t}
            fi
        done
    fi

    note "auditd :"
    run rm -f /etc/audit/rules.d/blocker-adulte.rules
    command -v augenrules >/dev/null 2>&1 && run augenrules --load

    note "$(m "Etat et utilisateur systeme :" "State and system user:")"
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

  @P1@
    sudo mkdir -p /run/blocker-adulte
    echo manuel | sudo tee /run/blocker-adulte/uninstall-in-progress
    sudo systemctl disable --now blocker-guard.service
    sudo systemctl disable --now blocker-resolver.service
    sudo systemctl disable --now blocker-selfheal.timer blocker-list-update.timer

  @P2@
    sudo chattr -i /etc/hosts /etc/nftables/blocker-adulte.nft \
        /etc/dnsmasq.d/blocker-adulte.conf \
        /etc/systemd/resolved.conf.d/blocker-adulte.conf \
        /etc/NetworkManager/dispatcher.d/90-blocker-adulte \
        /etc/firefox/policies/policies.json \
        /etc/opt/chrome/policies/managed/blocker-adulte.json \
        /etc/chromium/policies/managed/blocker-adulte.json \
        /etc/opt/chromium/policies/managed/blocker-adulte.json \
        /etc/brave/policies/managed/blocker-adulte.json

  @P3@
    sudo @PURGE@        # @P3C@
    sudo rm -f /etc/firefox/policies/policies.json \
        /etc/opt/chrome/policies/managed/blocker-adulte.json \
        /etc/chromium/policies/managed/blocker-adulte.json \
        /etc/opt/chromium/policies/managed/blocker-adulte.json \
        /etc/brave/policies/managed/blocker-adulte.json
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
    sudo nft delete table ip blocker_adulte_base_nat
    sudo nft delete table inet blocker_adulte_base
    sudo rm -f /etc/audit/rules.d/blocker-adulte.rules && sudo augenrules --load
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

There is no single command that removes everything: removal happens in four
phases, each one taking two commands. This is deliberate, and it is neither a
timer nor a trap — see « --manual » for the equivalent procedure without this
script.

  sudo blocker-uninstall --status     where we stand
  sudo blocker-uninstall --phase 1    start
  sudo blocker-uninstall --manual     equivalent manual procedure
EOF
    else
        cat <<'EOF'
blocker-adulte — desinstallation

Il n'y a pas de commande unique qui tout retire : le retrait se fait en quatre
phases, chacune demandant deux commandes. C'est delibere, et ce n'est ni une
minuterie ni un piege — voir « --manuel » pour la procedure equivalente sans ce
script.

  sudo blocker-uninstall --etat       ou en est-on
  sudo blocker-uninstall --phase 1    commencer
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
        --phase) PHASE="${2:-}"; shift ;;
        --jeton|--token) JETON="${2:-}"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --confirm)
            if [ "${BLOCKER_LANGUE}" = "en" ]; then
                cat >&2 <<'EOF'
« --confirm » no longer exists.

A single command can no longer remove everything: that is the point. Removal
now happens in four phases.

  sudo blocker-uninstall --status     see where we stand
  sudo blocker-uninstall --phase 1    start
EOF
            else
                cat >&2 <<'EOF'
« --confirm » n'existe plus.

Une seule commande ne peut plus tout retirer : c'est le but. Le retrait se fait
maintenant en quatre phases.

  sudo blocker-uninstall --etat       voir ou on en est
  sudo blocker-uninstall --phase 1    commencer
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
    for f in ${A_SUPPRIMER} /usr/lib/blocker-adulte /usr/share/blocker-adulte \
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
