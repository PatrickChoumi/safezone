# shellcheck shell=bash
# blocker-adulte — fonctions communes aux tests
#
# Chaque test est autonome et executable seul :
#   sudo tests/test_dns_leak.sh
#
# Codes de sortie :
#   0  tous les controles passent
#   1  au moins un controle echoue
#   77 test ignore (prealable absent : outil manquant, composant non installe)
#      — convention Automake, comprise par la plupart des lanceurs de tests.

TEST_SKIP=77

_pass=0
_fail=0

_c_ok=""; _c_ko=""; _c_warn=""; _c_off=""
if [ -t 1 ]; then
    _c_ok=$'\033[32m'; _c_ko=$'\033[31m'; _c_warn=$'\033[33m'; _c_off=$'\033[0m'
fi

titre() {
    printf '\n%s\n' "$1"
    printf '%s\n' "$(printf '%.0s-' $(seq 1 ${#1}))"
}

ok()   { _pass=$((_pass + 1)); printf '  %sOK%s    %s\n' "${_c_ok}" "${_c_off}" "$*"; }
ko()   { _fail=$((_fail + 1)); printf '  %sECHEC%s %s\n' "${_c_ko}" "${_c_off}" "$*"; }
warn() { printf '  %sNOTE%s  %s\n' "${_c_warn}" "${_c_off}" "$*"; }
info() { printf '        %s\n' "$*"; }

# verifier "description" commande...
verifier() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; else ko "${desc}"; fi
}

# verifier_echec "description" commande...   (le test passe si la commande echoue)
verifier_echec() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ko "${desc}"; else ok "${desc}"; fi
}

exiger_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf 'Ce test doit etre lance en root : sudo %s\n' "$0" >&2
        exit "${TEST_SKIP}"
    fi
}

exiger_commande() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Prealable absent : la commande « %s » est introuvable.\n' "$1" >&2
        printf 'Test ignore. Installer : %s\n' "${2:-le paquet correspondant}" >&2
        exit "${TEST_SKIP}"
    fi
}

exiger_installe() {
    if [ ! -d /usr/lib/blocker-adulte ]; then
        printf 'blocker-adulte n est pas installe sur cette machine. Test ignore.\n' >&2
        exit "${TEST_SKIP}"
    fi
}

bilan() {
    printf '\nResultat : %d controle(s) reussi(s), %d en echec.\n' "${_pass}" "${_fail}"
    [ "${_fail}" -eq 0 ]
}
