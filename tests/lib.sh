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

# Un domaine est-il bloque par le resolveur local ?
#
# dnsmasq peut bloquer de deux facons selon la directive de la liste :
#   - « address=/domaine/# »  -> repond 0.0.0.0 (et :: en IPv6), status NOERROR
#   - « server=/domaine/ »    -> repond NXDOMAIN, donc une reponse vide
# Les listes au format hosts (StevenBlack) sont converties vers la premiere
# forme, c'est donc 0.0.0.0 que l'on rencontre en pratique. Les deux comptent
# comme un blocage : dans les deux cas le navigateur ne joint rien.
#
# Renvoie 0 si bloque, 1 sinon. Affiche l'adresse obtenue sur la sortie.
dns_bloque() {
    local domaine="$1" serveur="${2:-127.0.0.1}" reponse
    reponse="$(dig +short +time=3 +tries=1 "@${serveur}" "${domaine}" 2>/dev/null \
               | grep -vE '^$' | head -3 | tr '\n' ' ' | sed 's/ $//')"
    printf '%s' "${reponse}"
    case "${reponse}" in
        ""|"0.0.0.0"|"::"|"0.0.0.0 ::"|"127.0.0.1") return 0 ;;
        *) return 1 ;;
    esac
}

# verifier_bloque "domaine" — controle de blocage lisible dans les tests.
verifier_bloque() {
    local domaine="$1" reponse rc
    reponse="$(dns_bloque "${domaine}")"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "${domaine} bloque (${reponse:-NXDOMAIN})"
    else
        ko "${domaine} resout vers ${reponse} — non bloque"
    fi
    return "${rc}"
}

# systemd est-il reellement le gestionnaire de services (PID 1) ?
# Dans un conteneur, un chroot ou une image cloud en construction, les unites
# existent sur le disque mais ne peuvent ni etre activees ni interrogees. Les
# controles de service doivent alors se rabattre sur le processus lui-meme
# plutot que d'echouer a tort.
systemd_actif() {
    [ -d /run/systemd/system ]
}

# verifier_service "unite" "motif de processus"
# Sous systemd : controle l'unite. Sinon : controle le processus, en le disant.
verifier_service() {
    local unite="$1" motif="$2"
    if systemd_actif; then
        if systemctl is-active --quiet "${unite}"; then
            ok "${unite} est actif"
        else
            ko "${unite} n'est pas actif"
        fi
        return
    fi

    if pgrep -x "${motif}" >/dev/null 2>&1 || pgrep -f "${motif}" >/dev/null 2>&1; then
        ok "processus « ${motif} » en cours (systemd absent : unite non interrogeable)"
    else
        ko "ni ${unite} ni le processus « ${motif} » ne tournent"
    fi
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
