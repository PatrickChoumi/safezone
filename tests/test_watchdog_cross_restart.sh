#!/bin/bash
# blocker-adulte — test : surveillance croisee des deux watchdogs
#
# Critere d'acceptation n°1 : arreter blocker-resolver.service seul doit
# provoquer sa relance automatique par blocker-guard.service en moins d'une
# minute, l'action etant visible dans journalctl.
#
# Ce test verifie les deux sens :
#   A. resolveur arrete   -> relance par la garde
#   B. garde arretee      -> relance par le resolveur
# puis il verifie que le retrait volontaire est bien respecte :
#   C. drapeau de desinstallation pose -> AUCUNE relance
#
# Ce test arrete reellement des services : la resolution DNS peut etre
# interrompue quelques secondes.
#
# sudo tests/test_watchdog_cross_restart.sh

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur (nft list,
# ps aux, journalctl...), et le pipeline renvoie 141 — le controle echouerait
# alors que la chose cherchee est bien la. Le code de production, lui, garde
# pipefail et capture ses sorties avant de les filtrer.
set -u
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe

# Ce test pilote reellement des unites systemd : sans systemd en PID 1, il n'a
# aucun sens. On l'ignore proprement plutot que de le faire echouer a tort.
if ! systemd_actif; then
    printf 'systemd n est pas le gestionnaire de services (PID 1). Test ignore.\n' >&2
    printf 'La surveillance croisee ne peut se verifier que sur une vraie machine.\n' >&2
    exit "${TEST_SKIP}"
fi

DELAI_MAX=60
FLAG=/run/blocker-adulte/uninstall-in-progress

# On note l'horodatage de depart pour ne lire que les lignes de journal
# produites par ce test.
DEPART="$(date '+%Y-%m-%d %H:%M:%S')"

attendre_actif() {
    local unite="$1" limite="$2" i=0
    while [ "${i}" -lt "${limite}" ]; do
        if systemctl is-active --quiet "${unite}"; then
            printf '%d' "${i}"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    printf '%d' "${i}"
    return 1
}

nettoyage() {
    rm -f "${FLAG}"
    systemctl start blocker-resolver.service >/dev/null 2>&1 || true
    systemctl start blocker-guard.service >/dev/null 2>&1 || true
}
trap nettoyage EXIT

titre "Etat initial"

if ! systemctl is-active --quiet blocker-resolver.service || \
   ! systemctl is-active --quiet blocker-guard.service; then
    warn "les deux services ne sont pas actifs au depart, demarrage"
    systemctl start blocker-resolver.service blocker-guard.service
    sleep 5
fi

verifier "blocker-resolver.service actif" systemctl is-active --quiet blocker-resolver.service
verifier "blocker-guard.service actif"    systemctl is-active --quiet blocker-guard.service

rm -f "${FLAG}"

# ---------------------------------------------------------------------------
titre "A. Arret du resolveur seul -> relance par la garde"
# ---------------------------------------------------------------------------

info "systemctl stop blocker-resolver.service"
systemctl stop blocker-resolver.service
sleep 1

if systemctl is-active --quiet blocker-resolver.service; then
    warn "le resolveur etait deja reparti en moins d'une seconde"
fi

info "attente de la relance (maximum ${DELAI_MAX} s)..."
if delai="$(attendre_actif blocker-resolver.service "${DELAI_MAX}")"; then
    ok "resolveur relance apres ${delai} s (limite : ${DELAI_MAX} s)"
else
    ko "resolveur toujours arrete apres ${DELAI_MAX} s"
    info "journalctl -u blocker-guard -n 30"
fi

# L'action doit etre tracee : un watchdog silencieux est explicitement exclu.
if journalctl -u blocker-guard.service --since "${DEPART}" --no-pager 2>/dev/null \
   | grep -qE '(REPARATION|REPAIR).*resolver'; then
    ok "la relance est journalisee par blocker-guard (ligne « REPARATION »)"
else
    ko "aucune ligne « REPARATION » dans le journal de blocker-guard"
    info "journalctl -u blocker-guard --since '${DEPART}'"
fi

sleep 3

# ---------------------------------------------------------------------------
titre "B. Arret de la garde seule -> relance par le resolveur"
# ---------------------------------------------------------------------------

DEPART_B="$(date '+%Y-%m-%d %H:%M:%S')"

info "systemctl stop blocker-guard.service"
systemctl stop blocker-guard.service
sleep 1

info "attente de la relance (maximum ${DELAI_MAX} s)..."
if delai="$(attendre_actif blocker-guard.service "${DELAI_MAX}")"; then
    ok "garde relancee apres ${delai} s (limite : ${DELAI_MAX} s)"
else
    ko "garde toujours arretee apres ${DELAI_MAX} s"
    info "journalctl -u blocker-resolver -n 30"
fi

if journalctl -u blocker-resolver.service --since "${DEPART_B}" --no-pager 2>/dev/null \
   | grep -qE '(REPARATION|REPAIR).*guard'; then
    ok "la relance est journalisee par blocker-resolver (ligne « REPARATION »)"
else
    warn "pas de ligne « REPARATION » cote resolveur — blocker-selfheal.timer a pu relancer la garde en premier"
fi

sleep 3

# ---------------------------------------------------------------------------
titre "C. Retrait volontaire -> aucune relance (ligne rouge)"
# ---------------------------------------------------------------------------

info "Ce controle verifie que l'outil ne combat PAS une desinstallation"
info "documentee : avec le drapeau pose, les watchdogs doivent rester passifs."

mkdir -p "$(dirname "${FLAG}")"
printf 'test_watchdog_cross_restart.sh %s\n' "$(date -Is)" > "${FLAG}"

# On laisse aux boucles le temps de voir le drapeau.
sleep 20

systemctl stop blocker-resolver.service
info "resolveur arrete avec le drapeau de retrait pose ; attente de 40 s..."
sleep 40

if systemctl is-active --quiet blocker-resolver.service; then
    ko "le resolveur a ete relance MALGRE le drapeau de retrait volontaire"
    info "c'est une violation de la ligne rouge du projet : la desinstallation"
    info "documentee ne doit jamais etre contrariee."
else
    ok "le resolveur est reste arrete : le retrait volontaire est respecte"
fi

if journalctl -u blocker-guard.service --since "${DEPART}" --no-pager 2>/dev/null \
   | grep -q 'retrait volontaire'; then
    ok "la mise en retrait est journalisee"
else
    warn "mise en retrait non trouvee dans le journal (la garde etait peut-etre deja arretee)"
fi

rm -f "${FLAG}"
info "drapeau retire, remise en route des services..."
systemctl start blocker-resolver.service blocker-guard.service
sleep 3

verifier "resolveur de nouveau actif apres le test" \
    systemctl is-active --quiet blocker-resolver.service
verifier "garde de nouveau active apres le test" \
    systemctl is-active --quiet blocker-guard.service

bilan
