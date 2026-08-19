#!/bin/bash
# blocker-adulte — test : volet Android
#
# Aucun telephone n'est necessaire. Un adb simule (tests/faux-adb) tient lieu
# d'appareil : c'est ce qui permet d'eprouver les chemins qu'on ne peut pas
# provoquer a volonte sur un vrai telephone — en particulier celui ou le
# resolveur DoT ne repond pas et ou le script doit revenir en arriere tout seul
# pour ne pas laisser l'appareil sans DNS.
#
# CE QUE CE TEST NE PROUVE PAS
#
# Qu'un vrai telephone se comporte comme la simulation. Il verifie la logique
# du pilote : les commandes envoyees, les verdicts rendus, le retour arriere.
# Le comportement d'Android lui-meme ne se verifie qu'avec un appareil branche.
#
# tests/test_android.sh
#
# Pas de « pipefail » : ces tests enchainent des « commande | grep -q » de
# diagnostic, et un grep qui sort tot ferait recevoir un SIGPIPE au producteur.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
. "${DIR}/../../tests/lib.sh"

BLOCKER_ANDROID="${DIR}/../bin/blocker-android"
[ -x "${BLOCKER_ANDROID}" ] || { echo "blocker-android introuvable." >&2; exit "${TEST_SKIP}"; }

BAC="$(mktemp -d)"
trap 'rm -rf "${BAC}"' EXIT

mkdir -p "${BAC}/bin"
ln -sf "${DIR}/faux-adb" "${BAC}/bin/adb"

# Chaque scenario part d'un telephone neuf et d'un HOME neuf : l'etat retenu
# entre deux appels (le fichier « .avant ») ne doit jamais fuir d'un cas a
# l'autre, sinon le retour arriere serait teste avec la mauvaise reference.
lancer() {
    local etat="$1"; shift
    (
        PATH="${BAC}/bin:${PATH}"
        HOME="${BAC}/home"
        XDG_CONFIG_HOME="${BAC}/home/.config"
        FAUX_ETAT="${etat}"
        BLOCKER_LANG=fr
        export PATH HOME XDG_CONFIG_HOME FAUX_ETAT BLOCKER_LANG
        "${BLOCKER_ANDROID}" "$@" 2>&1
    )
}

neuf() {
    local f="${BAC}/tel-$1"
    printf 'private_dns_mode=opportunistic\nprivate_dns_specifier=null\n' > "${f}"
    printf '%s' "${f}"
}

mode_de()      { sed -n 's/^private_dns_mode=//p' "$1" | head -1; }
specifier_de() { sed -n 's/^private_dns_specifier=//p' "$1" | head -1; }

# ---------------------------------------------------------------------------
titre "1. Prealables : adb et appareil"
# ---------------------------------------------------------------------------
# On retire adb, pas coreutils : vider le PATH casserait le script lui-meme et
# le test ne prouverait plus rien sur son message d'erreur.
sortie="$(ADB=adb-qui-n-existe-pas "${BLOCKER_ANDROID}" --etat 2>&1)"
if printf '%s' "${sortie}" | grep -qi 'adb'; then
    ok "sans adb, l outil le dit au lieu d echouer obscurement"
else
    ko "sans adb, message inattendu : ${sortie}"
fi

t="$(neuf aucun)"
sortie="$(FAUX_APPAREILS="" lancer "${t}" --etat)"
if printf '%s' "${sortie}" | grep -qi 'aucun appareil'; then
    ok "aucun appareil branche : dit clairement"
else
    ko "aucun appareil : message inattendu"
fi

sortie="$(FAUX_APPAREILS="FAUXSERIE01	unauthorized" lancer "${t}" --etat)"
if printf '%s' "${sortie}" | grep -qi 'non autorise'; then
    ok "appareil non autorise : distingue de l absence d appareil"
else
    ko "appareil non autorise : non detecte"
fi

sortie="$(FAUX_APPAREILS="$(printf 'A\tdevice\nB\tdevice')" lancer "${t}" --etat)"
if printf '%s' "${sortie}" | grep -qi 'plusieurs appareils'; then
    ok "deux appareils : refuse de choisir a la place de l utilisateur"
else
    ko "deux appareils : n a pas refuse"
fi

# ---------------------------------------------------------------------------
titre "2. Android trop ancien : refus avant toute modification"
# ---------------------------------------------------------------------------
# Le DNS prive n'existe pas avant Android 9. Ecrire le reglage quand meme
# laisserait un telephone a moitie configure sans rien gagner.
t="$(neuf vieux)"
sortie="$(FAUX_SDK=25 lancer "${t}" --appliquer --oui)"
if printf '%s' "${sortie}" | grep -qi 'Android 9'; then
    ok "API 25 : refuse et explique pourquoi"
else
    ko "API 25 : n a pas refuse"
fi
if [ "$(mode_de "${t}")" = "opportunistic" ]; then
    ok "aucun reglage n a ete ecrit sur l appareil"
else
    ko "l appareil a ete modifie malgre le refus : $(mode_de "${t}")"
fi

# ---------------------------------------------------------------------------
titre "3. Application nominale"
# ---------------------------------------------------------------------------
t="$(neuf ok)"
sortie="$(lancer "${t}" --appliquer --oui)"

if [ "$(mode_de "${t}")" = "hostname" ]; then
    ok "private_dns_mode passe a « hostname »"
else
    ko "private_dns_mode vaut $(mode_de "${t}")"
fi
if [ "$(specifier_de "${t}")" = "family.adguard-dns.com" ]; then
    ok "le resolveur par defaut est ecrit : $(specifier_de "${t}")"
else
    ko "resolveur ecrit : $(specifier_de "${t}")"
fi
if printf '%s' "${sortie}" | grep -qi 'DNS prive actif'; then
    ok "la validation reelle est confirmee avant de conclure"
else
    ko "aucune confirmation de validation"
fi
# Le message qui compte le plus : ne pas laisser croire a une protection forte.
if printf '%s' "${sortie}" | grep -qi 'trois touches'; then
    ok "la faiblesse du dispositif est dite au moment de l appliquer"
else
    ko "l outil ne previent pas que trois touches suffisent a le retirer"
fi

# ---------------------------------------------------------------------------
titre "4. Sondes : le filtrage est constate, pas suppose"
# ---------------------------------------------------------------------------
sortie="$(lancer "${t}" --sonde)"
if printf '%s' "${sortie}" | grep -q 'pornhub.com.*bloque'; then
    ok "un domaine adulte est vu bloque"
else
    ko "le domaine adulte n est pas vu bloque"
fi
if printf '%s' "${sortie}" | grep -q '216.239.38'; then
    ok "SafeSearch constate par l adresse renvoyee (216.239.38.x)"
else
    ko "SafeSearch non constate"
fi
if printf '%s' "${sortie}" | grep -q 'wikipedia.org.*accessible'; then
    ok "un service legitime reste accessible"
else
    ko "un service legitime est signale casse"
fi

# ---------------------------------------------------------------------------
titre "5. Le chemin dangereux : resolveur qui ne repond pas"
# ---------------------------------------------------------------------------
# C'est le controle le plus important du fichier. Un nom d'hote DoT errone
# laisse un vrai telephone SANS AUCUN DNS, et l'utilisateur ne fait pas
# forcement le lien avec ce qu'il vient de faire. Le script doit s'en rendre
# compte tout seul et revenir en arriere.
t="$(neuf mauvais)"
sortie="$(lancer "${t}" --appliquer --oui --hote dot.inexistant.invalid)"

if printf '%s' "${sortie}" | grep -qi 'aucune resolution'; then
    ok "l absence de resolution est detectee"
else
    ko "l echec de resolution n est pas detecte"
fi
if [ "$(mode_de "${t}")" = "opportunistic" ]; then
    ok "retour arriere automatique : le telephone n est pas laisse sans DNS"
else
    ko "le telephone reste en $(mode_de "${t}") avec un resolveur mort"
fi
if printf '%s' "${sortie}" | grep -qi 'etat precedent retabli'; then
    ok "le retour arriere est verifie, pas seulement tente"
else
    ko "le retour arriere n est pas verifie"
fi
if printf '%s' "${sortie}" | grep -qi '853'; then
    ok "les causes probables sont donnees (port 853, nom errone, hors ligne)"
else
    ko "aucune piste de diagnostic"
fi

# ---------------------------------------------------------------------------
titre "6. Retrait"
# ---------------------------------------------------------------------------
# On repart d'un telephone qui avait deja un DNS prive a lui : le retrait doit
# lui rendre CE reglage, pas un reglage par defaut choisi par nous.
t="$(neuf perso)"
printf 'private_dns_mode=hostname\nprivate_dns_specifier=dns.exemple.test\n' > "${t}"
lancer "${t}" --appliquer --oui --hote family.adguard-dns.com >/dev/null
sortie="$(lancer "${t}" --retirer)"

if [ "$(specifier_de "${t}")" = "dns.exemple.test" ]; then
    ok "le resolveur d origine est rendu, pas un defaut a nous"
else
    ko "resolveur apres retrait : $(specifier_de "${t}")"
fi
if printf '%s' "${sortie}" | grep -qi 'desactivees par --desactiver'; then
    ok "le retrait dit ce qu il ne defait PAS"
else
    ko "le retrait ne mentionne pas les applications desactivees"
fi

t="$(neuf sansmemoire)"
printf 'private_dns_mode=hostname\nprivate_dns_specifier=family.adguard-dns.com\n' > "${t}"
sortie="$(lancer "${t}" --retirer)"
if [ "$(mode_de "${t}")" = "opportunistic" ]; then
    ok "sans etat memorise, retour au mode automatique d Android"
else
    ko "sans etat memorise, l appareil reste en $(mode_de "${t}")"
fi

# ---------------------------------------------------------------------------
titre "7. Etat et honnetete du rapport"
# ---------------------------------------------------------------------------
t="$(neuf etat)"
lancer "${t}" --appliquer --oui >/dev/null
sortie="$(lancer "${t}" --etat)"

if printf '%s' "${sortie}" | grep -q 'family.adguard-dns.com'; then
    ok "le resolveur applique est affiche"
else
    ko "le resolveur applique n est pas affiche"
fi
if printf '%s' "${sortie}" | grep -qi 'com.android.chrome'; then
    ok "les applications capables de contourner sont nommees"
else
    ko "aucune application a risque signalee alors que Chrome est installe"
fi
for attendu in 'Ce qui ne protege pas' 'trois touches' 'adresse IP'; do
    if printf '%s' "${sortie}" | grep -qi "${attendu}"; then
        ok "le rapport dit ce qui ne protege pas : ${attendu}"
    else
        ko "le rapport omet : ${attendu}"
    fi
done

# Android ecrit « Device Owner » meme quand il n'y en a pas : la detection doit
# se fonder sur le composant, pas sur la presence des mots. On verifie donc les
# deux sens.
if printf '%s' "${sortie}" | grep -qi "le reglage reste modifiable"; then
    ok "sans device owner : l outil ne s en attribue pas un"
else
    ko "sans device owner, l outil croit pourtant en voir un"
fi
sortie="$(FAUX_DEVICE_OWNER="com.exemple.dpc/.Recepteur" lancer "${t}" --etat)"
if printf '%s' "${sortie}" | grep -qi "device owner est en place"; then
    ok "avec device owner : il est bien reconnu"
else
    ko "un device owner en place n est pas reconnu"
fi

# ---------------------------------------------------------------------------
titre "8. Applications a risque"
# ---------------------------------------------------------------------------
sortie="$(lancer "${t}" --desactiver com.android.chrome)"
if printf '%s' "${sortie}" | grep -qi 'disabled-user'; then
    ok "une application installee se desactive"
else
    ko "la desactivation n a pas abouti"
fi
sortie="$(lancer "${t}" --desactiver com.pas.installe)"
if printf '%s' "${sortie}" | grep -qi 'non installe'; then
    ok "une application absente est refusee proprement"
else
    ko "une application absente n est pas detectee"
fi

# ---------------------------------------------------------------------------
titre "9. Verrous : ce qui n est pas promis"
# ---------------------------------------------------------------------------
sortie="$(lancer "${t}" --verrous)"
for attendu in 'device owner' 'remise a zero' 'setGlobalPrivateDnsModeSpecifiedHost'; do
    if printf '%s' "${sortie}" | grep -qi -- "${attendu}"; then
        ok "--verrous explique : ${attendu}"
    else
        ko "--verrous omet : ${attendu}"
    fi
done
if printf '%s' "${sortie}" | grep -qi 'pas fournie par ce depot'; then
    ok "l application device owner est annoncee comme absente du depot"
else
    ko "l outil laisse croire que le device owner est livre"
fi

# ---------------------------------------------------------------------------
titre "10. Les deux langues"
# ---------------------------------------------------------------------------
t="$(neuf langue)"
fr="$(BLOCKER_LANG=fr lancer "${t}" --verrous | head -3 | tail -1)"
en="$(
    PATH="${BAC}/bin:${PATH}" HOME="${BAC}/home" XDG_CONFIG_HOME="${BAC}/home/.config" \
    FAUX_ETAT="${t}" BLOCKER_LANG=en "${BLOCKER_ANDROID}" --verrous 2>&1 | head -3 | tail -1
)"
if [ -n "${fr}" ] && [ -n "${en}" ] && [ "${fr}" != "${en}" ]; then
    ok "le volet Android parle bien deux langues"
else
    ko "meme sortie dans les deux langues"
fi

bilan
