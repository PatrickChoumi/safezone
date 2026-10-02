#!/bin/bash
# blocker-adulte — test : ce qu'une liste exterieure peut faire entrer
#
# Une liste telechargee ne doit fournir que des noms de domaine. Ce test
# verifie, sans rien installer ni toucher au reseau, que la conversion :
#   1. reconnait les formats hosts, dnsmasq, adblock et domaine nu ;
#   2. n'ecrit jamais que « address=/domaine/# » — la cible d'une ligne
#      « server= » tierce est ignoree, une liste ne peut pas rediriger ;
#   3. ecarte ce qui n'est pas un nom de domaine valide ;
#   4. respecte les exceptions approuvees ;
#   5. ne laisse passer dans les adresses DoH ni reseau prive ni prefixe large.
#
# tests/test_listes.sh   (root non requis)

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${DEPOT}/lib/blocker-listes.sh"
[ -r "${LIB}" ] || LIB=/usr/lib/blocker-adulte/blocker-listes.sh
[ -r "${LIB}" ] || { echo "blocker-listes.sh introuvable." >&2; exit "${TEST_SKIP}"; }
# shellcheck disable=SC1090
. "${LIB}"

BAC="$(mktemp -d)"
trap 'rm -rf "${BAC}"' EXIT

cat > "${BAC}/liste" <<'EOF'
# commentaire
! commentaire adblock
0.0.0.0 un.exemple.com
127.0.0.1 deux.exemple.com trois.exemple.com # fin de ligne
0.0.0.0 localhost
:: quatre.exemple.com
server=/redirige.exemple.net/203.0.113.7
local=/local.exemple.net/
address=/a.exemple.org/b.exemple.org/#
address=/cible.exemple.org/203.0.113.8
||adblock.exemple.io^
nu.exemple.fr
Majuscule.Exemple.FR.
mauvais_domaine.com
-tiret.exemple.com
1.2.3.4
<html><body>Not found</body></html>
exception.exemple.com
EOF
printf 'exception.exemple.com\n' > "${BAC}/exceptions"

blocker_convertir_liste "${BAC}/liste" "${BAC}/sortie" "${BAC}/exceptions"
rejets="$(blocker_conversion_rejets "${BAC}/sortie")"

titre "1. Formats reconnus"
for d in un.exemple.com deux.exemple.com trois.exemple.com quatre.exemple.com \
         redirige.exemple.net local.exemple.net a.exemple.org b.exemple.org \
         cible.exemple.org adblock.exemple.io nu.exemple.fr majuscule.exemple.fr; do
    if grep -qxF "address=/${d}/#" "${BAC}/sortie"; then
        ok "${d}"
    else
        ko "${d} absent de la sortie"
    fi
done

titre "2. Seules des directives de blocage sont produites"
autres="$(grep -vE '^address=/[a-z0-9.-]+/#$' "${BAC}/sortie" || true)"
if [ -z "${autres}" ]; then
    ok "uniquement des lignes « address=/domaine/# »"
else
    ko "lignes inattendues :"
    printf '%s\n' "${autres}" | sed 's/^/        /'
fi
if grep -q '203\.0\.113' "${BAC}/sortie"; then
    ko "la cible d une ligne server=/address= tierce a ete recopiee"
else
    ok "les cibles ecrites par la liste tierce sont ignorees"
fi

titre "3. Ce qui n'est pas un domaine est ecarte"
for d in localhost mauvais_domaine.com -tiret.exemple.com 1.2.3.4; do
    if grep -qF "/${d}/" "${BAC}/sortie"; then ko "${d} accepte"; else ok "${d} ecarte"; fi
done
[ "${rejets}" -ge 4 ] && ok "${rejets} lignes comptees comme rejetees" \
                      || ko "rejets comptes : ${rejets}, attendu au moins 4"
verifier "domaine valide accepte" blocker_domaine_valide "exemple.fr"
verifier_echec "adresse IP refusee comme domaine" blocker_domaine_valide "10.0.0.1"
verifier_echec "nom sans point refuse" blocker_domaine_valide "localhost"
verifier_echec "etiquette de 64 caracteres refusee" \
    blocker_domaine_valide "$(printf 'a%.0s' $(seq 1 64)).fr"

titre "4. Exceptions approuvees"
if grep -qF '/exception.exemple.com/' "${BAC}/sortie"; then
    ko "un domaine en exception est reste dans la sortie"
else
    ok "le domaine en exception est retire"
fi
blocker_convertir_liste "${BAC}/liste" "${BAC}/sortie2" /dev/null
blocker_conversion_rejets "${BAC}/sortie2" >/dev/null
if grep -qF '/exception.exemple.com/' "${BAC}/sortie2" && \
   [ "$(wc -l < "${BAC}/sortie2")" -gt "$(wc -l < "${BAC}/sortie")" ]; then
    ok "sans fichier d exceptions, rien n est retire (piege « FNR == NR » evite)"
else
    ko "un fichier d exceptions vide fausse la conversion"
fi

titre "5. Adresses DoH communautaires"
v4="$(printf '%s\n' '1.1.1.1  # cloudflare' '10.0.0.1' '192.168.1.1' '172.20.0.1' \
                   '127.0.0.1' '8.8.8.0/24' '8.0.0.0/8' '300.1.1.1' '2606:4700::1111' \
       | blocker_filtrer_ip 4 | tr '\n' ' ')"
v6="$(printf '%s\n' '2606:4700::1111 # x' 'fe80::1' '::1' 'fd00::1' '2001:db8::/16' '1.1.1.1' \
       | blocker_filtrer_ip 6 | tr '\n' ' ')"
[ "${v4}" = "1.1.1.1 8.8.8.0/24 " ] && ok "IPv4 : seules les adresses publiques et prefixes etroits restent" \
                                   || ko "IPv4 filtrees : « ${v4} »"
[ "${v6}" = "2606:4700::1111 " ] && ok "IPv6 : lien-local, bouclage, ULA et prefixes larges ecartes" \
                                 || ko "IPv6 filtrees : « ${v6} »"

titre "6. La sortie est une configuration dnsmasq valide"
if command -v dnsmasq >/dev/null 2>&1; then
    if dnsmasq --test --conf-file="${BAC}/sortie" >/dev/null 2>&1; then
        ok "dnsmasq --test accepte la sortie"
    else
        ko "dnsmasq --test rejette la sortie"
    fi
else
    warn "dnsmasq absent, controle ignore"
fi

bilan
