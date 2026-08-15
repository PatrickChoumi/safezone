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
    echo "blocker-uninstall : doit etre lance en root (sudo)." >&2
    exit 1
fi

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
blocker-selfheal.timer blocker-list-update.timer"

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
    "$@" || printf '    %s(echec ignore, on continue)%s\n' "${J}" "${Z}"
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
    dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null \
        | grep -q 'install ok installed' && return 0
    local f
    for f in ${A_SUPPRIMER}; do [ -e "${f}" ] && return 0; done
    return 1
}

traces_encore_la() {
    [ -e /etc/initramfs-tools/hooks/blocker-adulte ] && return 0
    [ -e /etc/audit/rules.d/blocker-adulte.rules ] && return 0
    [ -d /var/lib/blocker-adulte ] && return 0
    getent passwd blocker-adulte >/dev/null 2>&1 && return 0
    command -v nft >/dev/null 2>&1 && \
        nft list ruleset 2>/dev/null | grep -q blocker_adulte && return 0
    [ -e /etc/nftables.conf ] && grep -qF blocker-adulte /etc/nftables.conf 2>/dev/null && return 0
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
        note "Drapeau de retrait volontaire pose : ${OPTOUT_FLAG}"
        note "Les watchdogs cessent toute reparation dans les 15 secondes."
    fi
}

# ---------------------------------------------------------------------------
# Etat
# ---------------------------------------------------------------------------
afficher_etat() {
    titre "Etat de la desinstallation"

    local restantes=0 n
    for n in 1 2 3 4; do
        local libelle
        case "${n}" in
            1) libelle="Phase 1 — arret des watchdogs et des timers" ;;
            2) libelle="Phase 2 — levee de l'immuabilite des fichiers" ;;
            3) libelle="Phase 3 — retrait du paquet et des policies navigateur" ;;
            4) libelle="Phase 4 — initramfs, nftables, auditd, utilisateur systeme" ;;
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
        printf '  %sblocker-adulte est entierement retire.%s\n' "${G}" "${Z}"
        if [ -e /etc/nftables.conf.avant-blocker-adulte ]; then
            printf '\n  Un fichier a ete laisse volontairement :\n'
            printf '    /etc/nftables.conf.avant-blocker-adulte\n'
            printf '  C est la sauvegarde de votre /etc/nftables.conf. La supprimer\n'
            printf '  une fois le fichier courant verifie.\n'
        fi
        return 0
    fi

    local suivante=0
    for n in 1 2 3 4; do
        if ! phase_faite "${n}"; then suivante="${n}"; break; fi
    done

    printf '  %d phase(s) restante(s). Prochaine etape :\n\n' "${restantes}"
    printf '    sudo blocker-uninstall --phase %d\n\n' "${suivante}"
    printf '  Procedure manuelle equivalente : sudo blocker-uninstall --manuel\n'
    return 0
}

# ---------------------------------------------------------------------------
# Description des phases
# ---------------------------------------------------------------------------
decrire_phase() {
    case "$1" in
        1)
            titre "Phase 1 sur 4 — arret des watchdogs et des timers"
            note "Pose le drapeau de retrait volontaire, puis desactive et arrete,"
            note "dans cet ordre imposé :"
            note "  1. blocker-guard.service    (c'est elle qui relance le resolveur)"
            note "  2. blocker-resolver.service"
            note "  3. blocker-selfheal.timer et blocker-list-update.timer"
            printf '\n'
            note "APRES CETTE PHASE : le filtrage DNS s'arrete. Les regles nftables"
            note "restent chargees et redirigent vers un resolveur eteint, donc la"
            note "resolution DNS sera cassee jusqu'a la phase 4. C'est normal et"
            note "temporaire — allez au bout, ou relancez les services pour annuler."
            ;;
        2)
            titre "Phase 2 sur 4 — levee de l'immuabilite"
            note "Retire l'attribut chattr +i de chaque fichier protege :"
            local f
            for f in ${PROTEGES}; do
                [ -e "${f}" ] && note "    ${f}"
            done
            printf '\n'
            note "Sans cette phase, ni apt ni rm ne peuvent supprimer ces fichiers."
            note "/etc/hosts est deverrouille mais JAMAIS supprime : il appartient"
            note "au systeme, l'outil n'a fait qu'y poser un attribut."
            ;;
        3)
            titre "Phase 3 sur 4 — paquet et policies navigateur"
            if dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
                note "apt purge blocker-adulte"
            else
                note "Suppression manuelle (installation par install.sh) :"
                note "  /usr/lib/blocker-adulte, /usr/share/blocker-adulte,"
                note "  /usr/share/doc/blocker-adulte, /etc/blocker-adulte,"
                note "  les unites systemd et les fichiers de configuration."
            fi
            printf '\n'
            note "Puis les quatre fichiers de policies navigateur, qu'apt purge ne"
            note "retire pas (leurs repertoires appartiennent aux navigateurs), et"
            note "les liens d'activation systemd restes pendants."
            ;;
        4)
            titre "Phase 4 sur 4 — initramfs, nftables, auditd, utilisateur"
            note "  - retrait du hook initramfs puis update-initramfs -u"
            note "    (sans quoi les regles de base seraient rechargees a chaque boot)"
            note "  - suppression des tables nftables chargees en memoire"
            note "    (les fichiers ne suffisent pas : ce sont des objets du noyau)"
            note "  - retrait de la ligne d'inclusion de /etc/nftables.conf, avec"
            note "    sauvegarde dans /etc/nftables.conf.avant-blocker-adulte"
            note "  - retrait des regles auditd et de l'utilisateur systeme"
            printf '\n'
            note "APRES CETTE PHASE : la resolution DNS redevient normale."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Execution des phases
# ---------------------------------------------------------------------------
executer_phase_1() {
    poser_drapeau_retrait
    titre "Execution de la phase 1"

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
        note "systemd absent : arret direct du processus dnsmasq"
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
    titre "Execution de la phase 3"

    if dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
        run env DEBIAN_FRONTEND=noninteractive apt-get purge -y blocker-adulte
    else
        note "Paquet .deb non installe : suppression manuelle des fichiers."
        run rm -rf /usr/lib/blocker-adulte
        run rm -rf /usr/share/blocker-adulte
        run rm -rf /usr/share/doc/blocker-adulte
        run rm -f /lib/systemd/system/blocker-resolver.service
        run rm -f /lib/systemd/system/blocker-guard.service
        run rm -f /lib/systemd/system/blocker-selfheal.service
        run rm -f /lib/systemd/system/blocker-selfheal.timer
        run rm -f /lib/systemd/system/blocker-list-update.service
        run rm -f /lib/systemd/system/blocker-list-update.timer
        run rm -f /etc/dnsmasq.d/blocker-adulte.conf
        run rm -f /etc/nftables/blocker-adulte.nft
        run rm -f /etc/systemd/resolved.conf.d/blocker-adulte.conf
        run rm -f /etc/NetworkManager/dispatcher.d/90-blocker-adulte
        run rm -rf /etc/blocker-adulte
    fi

    note "Policies navigateur :"
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
    titre "Execution de la phase 4"

    note "Hook initramfs :"
    run rm -f /etc/initramfs-tools/hooks/blocker-adulte
    run rm -f /etc/initramfs-tools/scripts/init-bottom/blocker-adulte
    if command -v update-initramfs >/dev/null 2>&1 && [ -d /etc/initramfs-tools ]; then
        run update-initramfs -u
    else
        note "update-initramfs absent : rien a regenerer."
    fi

    note "Regles nftables :"
    if [ -e /etc/nftables.conf ] && grep -qF 'blocker-adulte' /etc/nftables.conf; then
        cp -a /etc/nftables.conf /etc/nftables.conf.avant-blocker-adulte
        sed -i '/blocker-adulte/d' /etc/nftables.conf
        note "+ ligne d'inclusion retiree (sauvegarde : /etc/nftables.conf.avant-blocker-adulte)"
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

    note "Etat et utilisateur systeme :"
    run rm -rf /var/lib/blocker-adulte
    getent passwd blocker-adulte >/dev/null 2>&1 && run deluser --system blocker-adulte
    getent group blocker-adulte >/dev/null 2>&1 && run delgroup --system blocker-adulte

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
    titre "Procedure manuelle equivalente"
    cat <<'EOF'
  Ce script n'est pas indispensable : les commandes ci-dessous font exactement
  la meme chose. Elles sont aussi dans le README, section « Desinstallation ».

  Phase 1 — watchdogs et timers (la garde d'abord, elle relance le resolveur)
    sudo mkdir -p /run/blocker-adulte
    echo manuel | sudo tee /run/blocker-adulte/uninstall-in-progress
    sudo systemctl disable --now blocker-guard.service
    sudo systemctl disable --now blocker-resolver.service
    sudo systemctl disable --now blocker-selfheal.timer blocker-list-update.timer

  Phase 2 — immuabilite
    sudo chattr -i /etc/hosts /etc/nftables/blocker-adulte.nft \
        /etc/dnsmasq.d/blocker-adulte.conf \
        /etc/systemd/resolved.conf.d/blocker-adulte.conf \
        /etc/NetworkManager/dispatcher.d/90-blocker-adulte \
        /etc/firefox/policies/policies.json \
        /etc/opt/chrome/policies/managed/blocker-adulte.json \
        /etc/chromium/policies/managed/blocker-adulte.json \
        /etc/opt/chromium/policies/managed/blocker-adulte.json \
        /etc/brave/policies/managed/blocker-adulte.json

  Phase 3 — paquet et policies
    sudo apt purge blocker-adulte        # ou suppression manuelle, voir README
    sudo rm -f /etc/firefox/policies/policies.json \
        /etc/opt/chrome/policies/managed/blocker-adulte.json \
        /etc/chromium/policies/managed/blocker-adulte.json \
        /etc/opt/chromium/policies/managed/blocker-adulte.json \
        /etc/brave/policies/managed/blocker-adulte.json
    sudo rm -f /etc/systemd/system/*.target.wants/blocker-*

  Phase 4 — initramfs, nftables, auditd, utilisateur
    sudo rm -f /etc/initramfs-tools/hooks/blocker-adulte \
               /etc/initramfs-tools/scripts/init-bottom/blocker-adulte
    sudo update-initramfs -u
    sudo sed -i '/blocker-adulte/d' /etc/nftables.conf
    sudo nft delete table ip blocker_adulte_nat
    sudo nft delete table ip6 blocker_adulte_nat
    sudo nft delete table inet blocker_adulte
    sudo nft delete table ip blocker_adulte_base_nat
    sudo nft delete table inet blocker_adulte_base
    sudo rm -f /etc/audit/rules.d/blocker-adulte.rules && sudo augenrules --load
    sudo rm -rf /var/lib/blocker-adulte /run/blocker-adulte
    sudo deluser --system blocker-adulte
    sudo systemctl daemon-reload && sudo systemctl restart systemd-resolved

  Verification finale
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
    cat <<EOF
blocker-adulte — desinstallation

Il n'y a pas de commande unique qui tout retire : le retrait se fait en quatre
phases, chacune demandant deux commandes. C'est deliberé, et ce n'est ni une
minuterie ni un piege — voir « --manuel » pour la procedure equivalente sans ce
script.

  sudo blocker-uninstall --etat       ou en est-on
  sudo blocker-uninstall --phase 1    commencer
  sudo blocker-uninstall --manuel     procedure manuelle equivalente
EOF
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
            cat >&2 <<'EOF'
« --confirm » n'existe plus.

Une seule commande ne peut plus tout retirer : c'est le but. Le retrait se fait
maintenant en quatre phases.

  sudo blocker-uninstall --etat       voir ou on en est
  sudo blocker-uninstall --phase 1    commencer
EOF
            exit 2
            ;;
        *) echo "Argument inconnu : $1" >&2; exit 2 ;;
    esac
    shift
done

case "${PHASE}" in
    1|2|3|4) ;;
    *) echo "Phase invalide : « ${PHASE} ». Attendu 1, 2, 3 ou 4." >&2; exit 2 ;;
esac

# --- Phase deja faite ? -----------------------------------------------------
if phase_faite "${PHASE}"; then
    printf '\n  %sLa phase %s est deja faite.%s\n' "${G}" "${PHASE}" "${Z}"
    afficher_etat
    exit 0
fi

# --- Les phases precedentes sont-elles faites ? -----------------------------
n=1
while [ "${n}" -lt "${PHASE}" ]; do
    if ! phase_faite "${n}"; then
        printf '\n  %sLa phase %d doit etre faite avant la phase %s.%s\n' \
            "${R}" "${n}" "${PHASE}" "${Z}"
        printf '  L ordre compte : les watchdogs se relancent mutuellement, et les\n'
        printf '  fichiers immuables ne peuvent pas etre supprimes.\n\n'
        printf '    sudo blocker-uninstall --phase %d\n' "${n}"
        exit 1
    fi
    n=$((n + 1))
done

# --- Sans jeton : on decrit et on en delivre un -----------------------------
if [ -z "${JETON}" ]; then
    decrire_phase "${PHASE}"
    jeton="$(nouveau_jeton "${PHASE}")"
    printf '\n  Pour executer cette phase :\n\n'
    printf '    %ssudo blocker-uninstall --phase %s --jeton %s%s\n\n' \
        "${B}" "${PHASE}" "${jeton}" "${Z}"
    printf '  Ce jeton est tire au hasard et change a chaque affichage.\n'
    printf '  Rien ne presse : il reste valable tant que la machine n a pas redemarre.\n'
    exit 0
fi

# --- Avec jeton : on verifie et on execute ----------------------------------
if ! jeton_valide "${PHASE}" "${JETON}"; then
    printf '\n  %sJeton invalide ou expire pour la phase %s.%s\n\n' "${R}" "${PHASE}" "${Z}"
    printf '  Obtenir un nouveau jeton :\n\n'
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
    printf '  %sPhase %s terminee.%s\n' "${G}" "${PHASE}" "${Z}"
else
    printf '  %sPhase %s executee, mais l etat attendu n est pas atteint.%s\n' \
        "${J}" "${PHASE}" "${Z}"
    printf '  Relancer la phase, ou suivre la procedure manuelle : --manuel\n'
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
