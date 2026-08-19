# shellcheck shell=bash
# blocker-adulte — bibliotheque partagee du volet Android
#
# Ce fichier tourne sur le PC, pas sur le telephone. Il ne parle a l'appareil
# que par adb.
#
# Il est volontairement autonome : quelqu'un peut vouloir proteger un telephone
# sans avoir installe le volet Linux sur sa machine. Il ne charge donc rien
# depuis /usr/lib/blocker-adulte, et redefinit les deux ou trois choses dont il
# a besoin (langue, presentation).

set -uo pipefail

# ---------------------------------------------------------------------------
# Francais / anglais
# ---------------------------------------------------------------------------
_langue() {
    local l
    case "${BLOCKER_LANG:-auto}" in
        fr|fr_*) printf 'fr\n'; return ;;
        en|en_*) printf 'en\n'; return ;;
    esac
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

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    VERT=$'\033[32m'; ROUGE=$'\033[31m'; JAUNE=$'\033[33m'
    GRAS=$'\033[1m'; GRIS=$'\033[90m'; Z=$'\033[0m'
else
    VERT=""; ROUGE=""; JAUNE=""; GRAS=""; GRIS=""; Z=""
fi

titre() { printf '\n%s%s%s\n' "${GRAS}" "$1" "${Z}"; }
ok()    { printf '  %s●%s %-34s %s\n' "${VERT}"  "${Z}" "$1" "${2:-}"; }
ko()    { printf '  %s●%s %-34s %s\n' "${ROUGE}" "${Z}" "$1" "${2:-}"; }
moyen() { printf '  %s●%s %-34s %s\n' "${JAUNE}" "${Z}" "$1" "${2:-}"; }
detail(){ printf '     %s%s%s\n' "${GRIS}" "$*" "${Z}"; }
note()  { printf '  %s\n' "$*"; }
erreur(){ printf '%s%s%s\n' "${ROUGE}" "$*" "${Z}" >&2; }

# ---------------------------------------------------------------------------
# Resolveurs DoT filtrants
# ---------------------------------------------------------------------------
# « Private DNS » d'Android n'accepte qu'un NOM D'HOTE DoT, jamais une adresse
# IP : c'est le nom qui sert a valider le certificat TLS. Un nom errone laisse
# donc le telephone sans DNS du tout — d'ou la verification obligatoire apres
# chaque changement, et le retour arriere automatique en cas d'echec.
#
# Format : <cle>|<hote DoT>|<ce qu'il filtre>
resolveurs_connus() {
    cat <<EOF
adguard|family.adguard-dns.com|$(m "adulte + publicites + traqueurs, SafeSearch force cote serveur" \
                                   "adult + ads + trackers, SafeSearch enforced server-side")
cleanbrowsing|family-filter-dns.cleanbrowsing.org|$(m "adulte + proxys, SafeSearch force" \
                                                      "adult + proxies, SafeSearch enforced")
EOF
}

BLOCKER_DOT_DEFAUT="family.adguard-dns.com"

# ---------------------------------------------------------------------------
# adb
# ---------------------------------------------------------------------------
ADB="${ADB:-adb}"
APPAREIL="${APPAREIL:-}"

adb_present() { command -v "${ADB}" >/dev/null 2>&1; }

# Un seul appareil, autorise, et sans ambiguite. Se tromper de telephone parce
# qu'un emulateur tournait est le genre d'erreur qu'on ne remarque pas.
adb_appareil_unique() {
    local lignes n
    lignes="$("${ADB}" devices 2>/dev/null | sed '1d' | grep -vE '^\s*$' || true)"
    n="$(printf '%s\n' "${lignes}" | grep -c . || true)"

    if [ "${n}" -eq 0 ]; then
        erreur "$(m "Aucun appareil vu par adb." "No device seen by adb.")"
        note "$(m "Verifier : cable branche, « Debogage USB » active dans les options" \
                  "Check: cable plugged in, « USB debugging » enabled in the developer")"
        note "$(m "pour developpeurs, et autorisation acceptee sur le telephone." \
                  "options, and the authorisation accepted on the phone.")"
        return 1
    fi

    if printf '%s\n' "${lignes}" | grep -q 'unauthorized'; then
        erreur "$(m "Appareil vu mais non autorise." "Device seen but not authorised.")"
        note "$(m "Deverrouiller le telephone et accepter la demande « Autoriser le debogage USB »." \
                  "Unlock the phone and accept the « Allow USB debugging » prompt.")"
        return 1
    fi

    if [ "${n}" -gt 1 ] && [ -z "${APPAREIL}" ]; then
        erreur "$(m "Plusieurs appareils connectes :" "Several devices connected:")"
        printf '%s\n' "${lignes}" | sed 's/^/    /'
        note "$(m "Preciser lequel : --appareil <numero de serie>" "Pick one: --device <serial>")"
        return 1
    fi
    return 0
}

# Toutes les commandes passent par ici : un seul endroit qui sait s'il faut
# ajouter « -s <serie> », et un seul endroit ou tracer ce qui est envoye.
and() {
    if [ -n "${APPAREIL}" ]; then
        "${ADB}" -s "${APPAREIL}" "$@"
    else
        "${ADB}" "$@"
    fi
}

# La sortie d'« adb shell » se termine par un retour chariot (le shell distant
# est en mode terminal) : sans ce nettoyage, toute comparaison de chaine echoue
# de facon incomprehensible.
and_shell() { and shell "$@" 2>/dev/null | tr -d '\r'; }

and_prop()  { and_shell "getprop $1"; }

and_setting_get() { and_shell "settings get global $1"; }
and_setting_put() { and_shell "settings put global $1 '$2'" >/dev/null; }

# Version d'Android, en niveau d'API : c'est ce qui decide de ce qui est
# possible. Private DNS demande 28 (Android 9).
and_sdk() {
    local v
    v="$(and_prop ro.build.version.sdk)"
    case "${v}" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "${v}" ;; esac
}

and_modele() {
    printf '%s %s (Android %s, API %s)\n' \
        "$(and_prop ro.product.manufacturer)" "$(and_prop ro.product.model)" \
        "$(and_prop ro.build.version.release)" "$(and_sdk)"
}

# ---------------------------------------------------------------------------
# Etat du DNS prive
# ---------------------------------------------------------------------------
dns_mode()      { and_setting_get private_dns_mode; }
dns_hote()      { and_setting_get private_dns_specifier; }

# Android ne considere le DNS prive comme actif que s'il a valide la connexion
# TLS au resolveur. Tant qu'il ne l'a pas fait, le telephone n'a pas de DNS.
# C'est l'information qui compte, et elle n'est pas dans « settings ».
dns_valide() {
    local sortie
    sortie="$(and_shell 'dumpsys connectivity' | grep -iE 'private *dns' | head -5)"
    printf '%s\n' "${sortie}"
}

# ---------------------------------------------------------------------------
# Sonde DNS reelle, executee sur le telephone
# ---------------------------------------------------------------------------
# On ne se fie pas a la configuration : on demande au telephone de resoudre un
# nom et on regarde ce qu'il obtient. « ping » est present sur tout Android
# (toybox) et affiche l'adresse resolue des sa premiere ligne, meme quand le
# paquet ne passe pas — ce qui est justement le cas d'un domaine bloque.
sonde_ip() {
    local domaine="$1" ligne
    ligne="$(and_shell "ping -c 1 -W 2 ${domaine}" | head -1)"
    printf '%s' "${ligne}" | sed -n 's/.*(\([0-9.]\{7,15\}\)).*/\1/p' | head -1
}

# 0 = bloque, 1 = resout normalement, 3 = pas de reponse.
# Meme raisonnement que du cote Linux : une absence de reponse n'est pas une
# preuve de blocage, et la confondre avec un blocage donnerait un faux vert.
sonde_bloque() {
    local ip
    ip="$(sonde_ip "$1")"
    case "${ip}" in
        "")                   return 3 ;;
        0.0.0.0|127.0.0.1)    return 0 ;;
        *)                    return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Navigateurs et applications a risque connus
# ---------------------------------------------------------------------------
# Ces applications embarquent leur propre VPN, leur propre proxy ou leur propre
# resolveur DoH : le DNS prive du systeme ne les voit pas passer. Les nommer
# vaut mieux que de laisser croire que tout est couvert.
paquets_a_risque() {
    cat <<EOF
com.opera.browser|$(m "VPN integre, gratuit et active en deux touches" "built-in VPN, free, two taps")
com.opera.mini.native|$(m "VPN integre" "built-in VPN")
org.torproject.torbrowser|$(m "Tor : sort par des relais, DNS inclus" "Tor: exits through relays, DNS included")
com.brave.browser|$(m "onglet Tor prive intégré" "built-in private Tor tab")
com.duckduckgo.mobile.android|$(m "VPN maison sur les versions recentes" "own VPN in recent versions")
org.mozilla.firefox|$(m "DoH activable dans les parametres, contourne le DNS prive" \
                        "DoH can be switched on in settings, bypasses Private DNS")
com.android.chrome|$(m "« DNS securise » activable, contourne le DNS prive" \
                       "« Secure DNS » can be switched on, bypasses Private DNS")
EOF
}

paquet_installe() {
    and_shell "pm list packages $1" | grep -qx "package:$1"
}
