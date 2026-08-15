#!/bin/bash
# blocker-adulte — lanceur de l'ensemble des tests
#
# sudo tests/run_all.sh              tous les tests sauf ceux marques intrusifs
# sudo tests/run_all.sh --tout       y compris test_watchdog_cross_restart.sh,
#                                    qui arrete reellement des services
#
# Codes de sortie : 0 si tout passe, 1 sinon. Un test ignore (77) n'est pas
# compte comme un echec.

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur (nft list,
# ps aux, journalctl...), et le pipeline renvoie 141 — le controle echouerait
# alors que la chose cherchee est bien la. Le code de production, lui, garde
# pipefail et capture ses sorties avant de les filtrer.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
TOUT=0
[ "${1:-}" = "--tout" ] && TOUT=1

if [ "$(id -u)" -ne 0 ]; then
    echo "Les tests doivent etre lances en root : sudo $0" >&2
    exit 1
fi

# test_watchdog_cross_restart.sh coupe le DNS quelques secondes : il n'est pas
# dans la liste par defaut pour ne pas surprendre.
TESTS="test_no_hidden_files.sh
test_dns_leak.sh
test_doh_blocked.sh
test_safesearch.sh
test_uninstall_phases.sh
test_browser_reinstall.sh
test_recovery_mode_hook.sh"

if [ "${TOUT}" -eq 1 ]; then
    TESTS="${TESTS}
test_watchdog_cross_restart.sh"
fi

reussis=0; echoues=0; ignores=0
liste_echecs=""

for t in ${TESTS}; do
    [ -x "${DIR}/${t}" ] || { echo "Test introuvable : ${DIR}/${t}"; continue; }

    printf '\n'
    printf '========================================================================\n'
    printf ' %s\n' "${t}"
    printf '========================================================================\n'

    "${DIR}/${t}"
    rc=$?

    case "${rc}" in
        0)  reussis=$((reussis + 1)) ;;
        77) ignores=$((ignores + 1)) ;;
        *)  echoues=$((echoues + 1)); liste_echecs="${liste_echecs} ${t}" ;;
    esac
done

printf '\n'
printf '========================================================================\n'
printf ' Bilan general\n'
printf '========================================================================\n'
printf '  reussis : %d\n' "${reussis}"
printf '  echoues : %d\n' "${echoues}"
printf '  ignores : %d\n' "${ignores}"

if [ "${TOUT}" -eq 0 ]; then
    printf '\n  test_watchdog_cross_restart.sh non execute (interrompt le DNS).\n'
    printf '  Pour l inclure : sudo %s --tout\n' "$0"
fi

if [ "${echoues}" -gt 0 ]; then
    printf '\n  En echec :%s\n' "${liste_echecs}"
    exit 1
fi

printf '\n  Tout est conforme.\n'
exit 0
