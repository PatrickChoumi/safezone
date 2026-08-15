#!/bin/bash
# blocker-adulte — test : SafeSearch force
#
# C'est le composant qui protege la ou une liste de blocage ne peut rien :
# Google Images, YouTube et Bing ne peuvent pas etre bloques sans rendre la
# machine inutilisable, mais ils peuvent etre forces en mode strict.
#
# Le test verifie les trois choses qui comptent :
#   1. les moteurs resolvent bien vers leur variante stricte ;
#   2. les services legitimes des memes fournisseurs ne sont PAS casses
#      (Gmail, Drive, Agenda) — une regression ici ferait tout desinstaller ;
#   3. le fichier genere est coherent et se regenere apres suppression.
#
# sudo tests/test_safesearch.sh

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur, et le
# pipeline renvoie 141 alors que la chose cherchee est bien la.
set -u
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe
exiger_commande dig "dnsutils"

FS=/var/lib/blocker-adulte/blocklists/05-safesearch.conf

# shellcheck disable=SC1091
. /usr/lib/blocker-adulte/blocker-common.sh

case "${BLOCKER_SAFESEARCH:-oui}" in
    non|no|0)
        printf 'SafeSearch desactive par configuration (BLOCKER_SAFESEARCH). Test ignore.\n' >&2
        exit "${TEST_SKIP}"
        ;;
esac

titre "1. Le fichier de redirections existe et est coherent"

if [ -s "${FS}" ]; then
    ok "fichier present : ${FS}"
    n=$(grep -c '^address=/' "${FS}" 2>/dev/null || true)
    info "${n} redirections"
    [ "${n}" -ge 20 ] && ok "nombre de redirections plausible (${n})" \
                      || ko "trop peu de redirections (${n})"
else
    ko "fichier absent : ${FS}"
    info "generer : sudo /usr/lib/blocker-adulte/blocker-safesearch"
    bilan; exit 1
fi

# Une erreur ici casserait Gmail : on verifie qu'aucun domaine nu n'est
# redirige. « address=/google.com/ » s'appliquerait a TOUS les sous-domaines.
titre "2. Aucun domaine nu redirige (protege Gmail, Drive, Agenda)"

dangereux=0
for nu in google.com googlemail.com live.com microsoft.com; do
    if grep -q "^address=/${nu}/" "${FS}" 2>/dev/null; then
        ko "domaine nu redirige : ${nu} — casserait tous ses sous-domaines"
        dangereux=$((dangereux + 1))
    fi
done
[ "${dangereux}" -eq 0 ] && ok "aucun domaine nu dangereux dans le fichier"

titre "3. Les moteurs resolvent vers leur variante stricte"

# On compare ce que renvoie le resolveur a ce que le fichier declare : plus
# robuste que des adresses ecrites en dur dans le test, qui vieilliraient.
verifier_moteur() {
    local domaine="$1" attendu obtenu
    attendu="$(grep "^address=/${domaine}/" "${FS}" 2>/dev/null \
               | sed 's|.*/||' | grep -E '^[0-9.]+$' | sort -u | head -1)"
    if [ -z "${attendu}" ]; then
        warn "${domaine} : absent du fichier, controle ignore"
        return
    fi
    obtenu="$(dig +short +time=3 +tries=1 @127.0.0.1 "${domaine}" 2>/dev/null \
              | grep -E '^[0-9.]+$' | sort -u | head -1)"
    if [ "${obtenu}" = "${attendu}" ]; then
        ok "${domaine} -> ${obtenu} (strict)"
    else
        ko "${domaine} -> ${obtenu:-rien}, attendu ${attendu}"
        info "le resolveur a-t-il ete redemarre depuis la generation du fichier ?"
        info "un SIGHUP ne suffit pas : sudo systemctl restart blocker-resolver"
    fi
}

for d in www.google.com www.google.fr www.youtube.com m.youtube.com \
         www.bing.com duckduckgo.com; do
    verifier_moteur "${d}"
done

titre "4. Les services legitimes ne sont pas casses"

# Une regression ici est bien plus grave qu'un filtre manquant : elle rend la
# machine penible et pousse a tout desinstaller.
for d in mail.google.com drive.google.com accounts.google.com calendar.google.com \
         docs.google.com photos.google.com; do
    r="$(dig +short +time=3 +tries=1 @127.0.0.1 "${d}" 2>/dev/null \
         | grep -E '^[0-9.]+$' | head -1)"
    case "${r}" in
        ""|0.0.0.0)  ko "${d} ne resout plus — service casse" ;;
        216.239.38.*) ko "${d} redirige vers le SafeSearch — service casse" ;;
        *)           ok "${d} -> ${r} (intact)" ;;
    esac
done

titre "5. Le fichier se regenere apres suppression"

sauvegarde="$(mktemp)"
cp "${FS}" "${sauvegarde}"
rm -f "${FS}"

if /usr/lib/blocker-adulte/blocker-safesearch >/dev/null 2>&1 && [ -s "${FS}" ]; then
    ok "fichier regenere par blocker-safesearch"
    n2=$(grep -c '^address=/' "${FS}" 2>/dev/null || true)
    if [ "${n2}" -ge "$(( n * 80 / 100 ))" ]; then
        ok "le fichier regenere est complet (${n2} redirections)"
    else
        ko "le fichier regenere est incomplet (${n2} contre ${n} avant)"
    fi
else
    ko "regeneration en echec, restauration de la sauvegarde"
    cp "${sauvegarde}" "${FS}"
fi
rm -f "${sauvegarde}"

titre "6. Le fichier genere est une configuration dnsmasq valide"

if command -v dnsmasq >/dev/null 2>&1; then
    if dnsmasq --test --conf-file="${FS}" >/dev/null 2>&1; then
        ok "dnsmasq --test accepte le fichier"
    else
        ko "dnsmasq --test rejette le fichier"
        dnsmasq --test --conf-file="${FS}" 2>&1 | sed 's/^/        /'
    fi
else
    warn "dnsmasq absent, controle ignore"
fi

bilan
