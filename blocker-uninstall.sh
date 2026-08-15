#!/bin/bash
# blocker-adulte — desinstallation complete
#
# Installe dans : /usr/sbin/blocker-uninstall
# Source        : blocker-uninstall.sh a la racine du depot
#
# Ce script execute, dans le bon ordre, les huit etapes decrites dans le README.
# Il est le pendant executable de la procedure manuelle : les deux menent au
# meme resultat, et suivre le README a la main donne exactement ce que fait ce
# script.
#
# Il n'est JAMAIS appele automatiquement. Il exige --confirm, non pas comme un
# delai de reflexion, mais pour eviter qu'un « rm -rf » ou un tab-completion
# malheureux laisse le systeme a moitie configure : sans DNS, ou avec des
# fichiers immuables que plus rien ne sait deverrouiller.
#
# Ordre des etapes : il compte. Les deux watchdogs se relancent mutuellement ;
# les desactiver dans le desordre ferait ressusciter celui qu'on vient d'arreter.
#
# Usage :
#   blocker-uninstall --dry-run     affiche ce qui serait fait, ne fait rien
#   blocker-uninstall --confirm     execute la desinstallation
#   blocker-uninstall --confirm --keep-package
#                                   tout retirer sauf le paquet .deb lui-meme

set -uo pipefail

CONFIRM=0
DRY_RUN=0
KEEP_PACKAGE=0

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --confirm)       CONFIRM=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --keep-package)  KEEP_PACKAGE=1 ;;
        -h|--help)       usage 0 ;;
        *) echo "Argument inconnu : $1" >&2; usage 2 ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "blocker-uninstall : doit etre lance en root (sudo)." >&2
    exit 1
fi

if [ "${CONFIRM}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
    cat >&2 <<'EOF'
blocker-uninstall : rien n'a ete fait.

Ce script retire integralement blocker-adulte : resolveur DNS local, regles
nftables, policies des quatre navigateurs, hook initramfs, triggers dpkg,
regles auditd, les deux watchdogs et les deux timers.

  blocker-uninstall --dry-run     voir la liste des actions, sans rien changer
  blocker-uninstall --confirm     executer

La procedure manuelle equivalente, etape par etape, est dans le README
(section « Desinstallation »).
EOF
    exit 1
fi

RUNDIR="/run/blocker-adulte"
OPTOUT_FLAG="${RUNDIR}/uninstall-in-progress"

etape=0
step() {
    etape=$((etape + 1))
    printf '\n=== Etape %d/8 : %s ===\n' "${etape}" "$1"
}

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    printf '  + %s\n' "$*"
    "$@" || printf '    (echec ignore, on continue)\n'
}

note() { printf '  %s\n' "$*"; }

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "MODE SIMULATION — aucune modification ne sera faite."
fi

# ---------------------------------------------------------------------------
# Etape 0 (prealable) : signaler le retrait volontaire
# ---------------------------------------------------------------------------
# Ce drapeau est lu par blocker-guard, blocker-resolver-run, blocker-selfheal et
# le dispatcher NetworkManager. Tant qu'il existe, aucun d'eux ne relance quoi
# que ce soit. C'est ce qui rend cette procedure fiable plutot qu'un bras de fer.
if [ "${DRY_RUN}" -eq 0 ]; then
    mkdir -p "${RUNDIR}"
    printf 'Desinstallation lancee le %s par %s\n' \
        "$(date -Is)" "${SUDO_USER:-root}" > "${OPTOUT_FLAG}"
    logger -t blocker-adulte -p daemon.notice -- \
        "desinstallation volontaire demarree par ${SUDO_USER:-root} : les watchdogs se mettent en retrait"
    echo "Drapeau de retrait volontaire pose : ${OPTOUT_FLAG}"
    echo "Les watchdogs cessent toute reparation dans les 15 secondes."
    sleep 16
else
    note "[dry-run] poserait ${OPTOUT_FLAG}"
fi

# ---------------------------------------------------------------------------
# Etape 1 : desactiver les deux watchdogs, dans l'ordre
# ---------------------------------------------------------------------------
step "desactivation des deux watchdogs a surveillance croisee"
note "Ordre impose : la garde d'abord (elle relance le resolveur), le resolveur ensuite."

# « disable » avant « stop » : une unite desactivee est consideree comme un
# retrait volontaire par le code de garde, qui n'essaiera donc pas de la relancer.
run systemctl disable blocker-guard.service
run systemctl stop blocker-guard.service
run systemctl disable blocker-resolver.service
run systemctl stop blocker-resolver.service

# ---------------------------------------------------------------------------
# Etape 2 : arreter les timers
# ---------------------------------------------------------------------------
step "arret du timer de self-heal et du timer de mise a jour des listes"
run systemctl disable blocker-selfheal.timer
run systemctl stop blocker-selfheal.timer
run systemctl disable blocker-list-update.timer
run systemctl stop blocker-list-update.timer
run systemctl stop blocker-selfheal.service
run systemctl stop blocker-list-update.service

# ---------------------------------------------------------------------------
# Etape 3 : lever l'immuabilite (chattr -i)
# ---------------------------------------------------------------------------
step "levee de l'immuabilite sur chaque fichier protege"
note "Sans cette etape, ni apt ni rm ne peuvent supprimer ces fichiers."

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
# systeme, l'outil n'a fait que poser un attribut d'immuabilite dessus. Les
# oublier ici laisserait un /etc/hosts non modifiable apres la desinstallation.
A_DEVERROUILLER_SEULEMENT="
/etc/hosts
"

PROTEGES="${A_SUPPRIMER} ${A_DEVERROUILLER_SEULEMENT}"

for f in ${PROTEGES}; do
    if [ -e "${f}" ]; then
        run chattr -i "${f}"
    else
        note "(absent) ${f}"
    fi
done

# ---------------------------------------------------------------------------
# Etape 4 : retirer le paquet
# ---------------------------------------------------------------------------
step "retrait du paquet blocker-adulte"
if [ "${KEEP_PACKAGE}" -eq 1 ]; then
    note "--keep-package : le paquet est conserve, etape ignoree."
elif dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y blocker-adulte
else
    note "Paquet .deb non installe (installation via install.sh) : suppression manuelle des fichiers."
    run rm -rf /usr/lib/blocker-adulte
    run rm -rf /usr/share/blocker-adulte
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
    run rm -rf /var/lib/blocker-adulte
    run rm -rf /usr/share/doc/blocker-adulte
    # Ce script lui-meme. Sous Linux, supprimer un script en cours d'execution
    # est sans danger : l'inode reste vivant jusqu'a la fin du processus.
    run rm -f /usr/sbin/blocker-uninstall
fi

# Liens d'activation systemd laisses par « systemctl enable ». Si l'unite a
# disparu avant que « systemctl disable » n'ait pu s'executer (systemd
# injoignable, purge interrompue), ces liens restent pendants et systemd les
# affiche comme des unites « not-found » : c'est exactement le service fantome
# que la procedure doit eviter.
for lien in /etc/systemd/system/*.target.wants/blocker-*.service \
            /etc/systemd/system/*.target.wants/blocker-*.timer; do
    [ -e "${lien}" ] || [ -L "${lien}" ] || continue
    run rm -f "${lien}"
done

# ---------------------------------------------------------------------------
# Etape 5 : policies navigateur
# ---------------------------------------------------------------------------
step "suppression des fichiers de policies navigateur"
note "Ces fichiers ne sont pas tous supprimes par apt purge : /etc/firefox/policies"
note "et /etc/chromium/policies appartiennent aux paquets des navigateurs."

run rm -f /etc/firefox/policies/policies.json
run rm -f /etc/opt/chrome/policies/managed/blocker-adulte.json
run rm -f /etc/chromium/policies/managed/blocker-adulte.json
run rm -f /etc/opt/chromium/policies/managed/blocker-adulte.json
run rm -f /etc/brave/policies/managed/blocker-adulte.json

# Repertoires laisses en place s'ils contiennent autre chose.
for d in /etc/firefox/policies /etc/opt/chrome/policies/managed \
         /etc/chromium/policies/managed /etc/opt/chromium/policies/managed \
         /etc/brave/policies/managed; do
    if [ -d "${d}" ] && [ -z "$(ls -A "${d}" 2>/dev/null)" ]; then
        run rmdir "${d}"
    fi
done

# ---------------------------------------------------------------------------
# Etape 6 : hook initramfs
# ---------------------------------------------------------------------------
step "retrait du hook initramfs et regeneration de l'image"
note "Sans update-initramfs -u, les regles de base resteraient chargees a chaque boot."

run rm -f /etc/initramfs-tools/hooks/blocker-adulte
run rm -f /etc/initramfs-tools/scripts/init-bottom/blocker-adulte

if command -v update-initramfs >/dev/null 2>&1; then
    run update-initramfs -u
else
    note "update-initramfs absent : rien a regenerer."
fi

# ---------------------------------------------------------------------------
# Etape 7 : nftables, resolved, auditd
# ---------------------------------------------------------------------------
step "retrait des regles nftables, du drop-in resolved et des regles auditd"

# Ligne d'inclusion ajoutee a /etc/nftables.conf par install.sh.
if [ -e /etc/nftables.conf ] && grep -qF 'blocker-adulte.nft' /etc/nftables.conf; then
    if [ "${DRY_RUN}" -eq 1 ]; then
        note "[dry-run] retirerait la ligne d'inclusion de /etc/nftables.conf"
    else
        cp -a /etc/nftables.conf /etc/nftables.conf.avant-blocker-adulte
        sed -i '/blocker-adulte/d' /etc/nftables.conf
        note "+ ligne d'inclusion retiree de /etc/nftables.conf (sauvegarde : /etc/nftables.conf.avant-blocker-adulte)"
    fi
fi

# Tables chargees en memoire : elles survivent a la suppression des fichiers.
for t in "ip blocker_adulte_nat" "ip6 blocker_adulte_nat" "inet blocker_adulte" \
         "ip blocker_adulte_base_nat" "inet blocker_adulte_base"; do
    # shellcheck disable=SC2086
    if nft list table ${t} >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        run nft delete table ${t}
    fi
done

run rm -f /etc/audit/rules.d/blocker-adulte.rules
if command -v augenrules >/dev/null 2>&1; then
    run augenrules --load
fi

run systemctl daemon-reload
run systemctl reset-failed
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    run systemctl restart systemd-resolved.service
fi

# ---------------------------------------------------------------------------
# Etape 8 : utilisateur systeme, verification finale
# ---------------------------------------------------------------------------
step "retrait de l'utilisateur systeme et verification finale"

if getent passwd blocker-adulte >/dev/null 2>&1; then
    run deluser --system blocker-adulte
fi

# Le repertoire d'execution nous appartient entierement : il contient le
# drapeau de retrait et le fichier PID de dnsmasq. « rmdir » seul echouerait
# sur ce dernier et laisserait un repertoire fantome.
run rm -rf "${RUNDIR}"

if [ "${DRY_RUN}" -eq 1 ]; then
    printf '\nMODE SIMULATION termine — rien n a ete modifie.\n'
    exit 0
fi

printf '\n=== Verification ===\n'

restes=0

verifier_absent() {
    if [ -e "$1" ]; then
        printf '  RESTE : %s\n' "$1"
        restes=$((restes + 1))
    fi
}

for f in ${A_SUPPRIMER} /usr/lib/blocker-adulte /usr/share/blocker-adulte \
         /usr/share/doc/blocker-adulte /usr/sbin/blocker-uninstall \
         /var/lib/blocker-adulte /etc/blocker-adulte /run/blocker-adulte \
         /etc/initramfs-tools/hooks/blocker-adulte \
         /etc/initramfs-tools/scripts/init-bottom/blocker-adulte \
         /etc/audit/rules.d/blocker-adulte.rules; do
    verifier_absent "${f}"
done

# Liens d'activation pendants (unites fantomes).
for lien in /etc/systemd/system/*.target.wants/blocker-*; do
    if [ -e "${lien}" ] || [ -L "${lien}" ]; then
        printf '  RESTE : lien d activation systemd %s\n' "${lien}"
        restes=$((restes + 1))
    fi
done

# Ligne d'inclusion dans un fichier qui ne nous appartient pas.
if [ -e /etc/nftables.conf ] && grep -qF 'blocker-adulte' /etc/nftables.conf; then
    printf '  RESTE : /etc/nftables.conf contient encore une reference a blocker-adulte\n'
    restes=$((restes + 1))
fi

for u in blocker-resolver.service blocker-guard.service \
         blocker-selfheal.timer blocker-list-update.timer; do
    if systemctl list-unit-files "${u}" >/dev/null 2>&1 && \
       [ -n "$(systemctl list-unit-files "${u}" --no-legend 2>/dev/null)" ]; then
        printf '  RESTE : unite systemd %s\n' "${u}"
        restes=$((restes + 1))
    fi
done

if nft list ruleset 2>/dev/null | grep -q 'blocker_adulte'; then
    printf '  RESTE : des tables nftables blocker_adulte sont encore chargees\n'
    restes=$((restes + 1))
fi

printf '\n'
if [ "${restes}" -eq 0 ]; then
    if [ -e /etc/nftables.conf.avant-blocker-adulte ]; then
        cat <<'EOF'
Un fichier a ete laisse volontairement :
  /etc/nftables.conf.avant-blocker-adulte
C'est la sauvegarde de votre /etc/nftables.conf faite avant le retrait de la
ligne d'inclusion. La supprimer une fois le fichier courant verifie :
  sudo rm /etc/nftables.conf.avant-blocker-adulte

EOF
    fi
    cat <<'EOF'
Desinstallation complete. Aucun residu detecte.

Verification independante recommandee :
  sudo find / -xdev -name '*blocker-adulte*' 2>/dev/null
  systemctl list-units --all 'blocker-*'
  sudo nft list ruleset | grep blocker
  resolvectl status

Le fichier /usr/sbin/blocker-uninstall que vous venez d'executer peut avoir ete
supprime avec le paquet ; c'est normal.
EOF
    exit 0
else
    printf '%d residu(s) detecte(s) ci-dessus. Les traiter a la main, puis relancer\n' "${restes}"
    printf 'ce script pour re-verifier.\n'
    exit 1
fi
