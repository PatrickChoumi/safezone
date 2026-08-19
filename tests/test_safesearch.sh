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
exiger_commande dig "bind9-dnsutils"

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
#
# « Pas de reponse » et « reponse 0.0.0.0 » ne veulent pas dire la meme chose et
# etaient auparavant confondus dans un meme echec. Un 0.0.0.0 est un blocage
# bien reel, a corriger. Un silence n'est pas une preuve : c'est une absence de
# preuve, et l'amont met parfois plus de trois secondes a repondre — surtout sur
# un resolveur qui vient d'etre redemarre, donc a cache froid. On separe donc
# les trois causes possibles au lieu d'accuser l'outil par defaut.
verifier_service_legitime() {
    local d="$1" r="" essai fichier amont r2

    for essai in 1 2 3; do
        r="$(dig +short +time=5 +tries=1 @127.0.0.1 "${d}" 2>/dev/null \
             | grep -E '^[0-9.]+$' | head -1)"
        [ -n "${r}" ] && break
        sleep 1
    done

    case "${r}" in
        0.0.0.0)
            ko "${d} est bloque (0.0.0.0) — service casse"
            fichier="$(grep -l "^address=/${d}/" \
                       "${BLOCKER_STATEDIR}"/blocklists/*.conf 2>/dev/null | head -1)"
            if [ -n "${fichier}" ]; then
                info "entree fautive dans ${fichier}"
            else
                info "aucune entree exacte : un domaine parent d une liste amont"
                info "l englobe probablement (« address=/X/ » couvre les sous-domaines)."
            fi
            ;;
        216.239.38.*)
            ko "${d} redirige vers le SafeSearch — service casse"
            info "verifier ${FS} : seuls les hotes de recherche doivent y figurer."
            ;;
        "")
            # Le resolveur local n'a rien renvoye en trois essais. Reste a savoir
            # si c'est lui ou l'amont : on interroge l'amont directement, sous
            # l'identite exemptee de la redirection nftables.
            amont=""
            if command -v runuser >/dev/null 2>&1 && \
               getent passwd "${BLOCKER_USER:-blocker-adulte}" >/dev/null 2>&1; then
                amont="$(runuser -u "${BLOCKER_USER:-blocker-adulte}" -- \
                         dig +short +time=5 +tries=2 -tA "@${BLOCKER_UPSTREAM_1}" "${d}" \
                         2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
            fi
            if [ -z "${amont}" ]; then
                warn "${d} : aucune reponse, de l amont ${BLOCKER_UPSTREAM_1} non plus"
                info "ni blocage ni redirection : amont lent ou injoignable a cet instant."
            else
                # L'amont a repondu : le nom existe et l'amont l'a maintenant en
                # cache. On redemande au resolveur local. S'il repond cette
                # fois, l'echec precedent etait un a-coup de la liaison vers
                # l'amont, pas une panne de notre cote — et un a-coup ne doit
                # pas etre rapporte comme une panne. Ce n'est qu'apres cette
                # contre-epreuve que l'on accuse le resolveur local.
                r2="$(dig +short +time=5 +tries=2 @127.0.0.1 "${d}" 2>/dev/null \
                      | grep -E '^[0-9.]+$' | head -1)"
                if [ -n "${r2}" ]; then
                    warn "${d} -> ${r2} (intact), mais n a repondu qu a la contre-epreuve"
                    info "l amont a mis plus de 15 s a repondre la premiere fois :"
                    info "lenteur passagere de la liaison, ni blocage ni panne locale."
                else
                    ko "${d} : l amont repond (${amont}) mais le resolveur local ne renvoie rien"
                    info "constate deux fois de suite : la panne est bien de notre cote."
                    info "journalctl -u blocker-resolver -n 30"
                fi
            fi
            ;;
        *) ok "${d} -> ${r} (intact)" ;;
    esac
}

for d in mail.google.com drive.google.com accounts.google.com calendar.google.com \
         docs.google.com photos.google.com; do
    verifier_service_legitime "${d}"
done

titre "5. Chaque entree est structurellement capable de forcer quelque chose"

# Une entree dont l'hote « strict » resout vers la MEME adresse que le domaine
# normal ne force rien du tout : le serveur ne peut pas distinguer les deux
# requetes autrement que par l'en-tete Host, que le DNS ne touche pas. Une telle
# entree donne une fausse assurance et peut casser le site vise.
#
# On interroge l'amont directement, sous l'identite blocker-adulte : passer par
# notre propre resolveur renverrait l'adresse deja reecrite et le controle
# n'aurait aucun sens.
#
# Une egalite d'adresses ne suffit cependant pas a conclure. Un amont filtrant
# — AdGuard Family, l'amont par defaut — applique lui-meme le SafeSearch cote
# serveur : il renvoie l'adresse stricte AUSSI pour le domaine normal, et les
# deux resolutions coincident tout a fait legitimement. Pour departager les deux
# situations on rejoue la resolution du domaine normal via un resolveur qui, lui,
# ne reecrit rien.
SRC=/usr/lib/blocker-adulte/blocker-safesearch
NEUTRES="1.1.1.1 8.8.8.8 9.9.9.10"

resoudre_via() {
    local serveur="$1" nom="$2" sortie=""
    if command -v runuser >/dev/null 2>&1 && getent passwd blocker-adulte >/dev/null 2>&1; then
        sortie="$(runuser -u blocker-adulte -- dig +short +time=4 +tries=2 -tA \
                  "@${serveur}" "${nom}" 2>/dev/null)"
    fi
    printf '%s\n' "${sortie}" | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

resoudre_amont() { resoudre_via "${BLOCKER_UPSTREAM_1}" "$1"; }

# Premier resolveur neutre joignable, s'il y en a un. Les requetes partent sous
# l'identite blocker-adulte, la seule exemptee de la redirection nftables du
# port 53 : c'est bien un resolveur externe qui repond, pas le notre.
NEUTRE=""
for s in ${NEUTRES}; do
    if [ -n "$(resoudre_via "${s}" example.com)" ]; then NEUTRE="${s}"; break; fi
done

if [ ! -r "${SRC}" ]; then
    warn "${SRC} illisible, controle ignore"
else
    # On rejoue la table de correspondances du script lui-meme plutot que d'en
    # tenir une copie ici, qui divergerait a la premiere modification.
    entrees="$(sed -n '/^correspondances() {/,/^}/p' "${SRC}" | grep -E '^[a-z0-9.-]+\|')"

    if [ -z "${entrees}" ]; then
        ko "aucune entree extraite de correspondances() — le format a-t-il change ?"
    else
        nb_entrees=$(printf '%s\n' "${entrees}" | wc -l)
        ok "${nb_entrees} entrees extraites de correspondances()"

        if [ -n "${NEUTRE}" ]; then
            info "resolveur de comparaison non filtrant : ${NEUTRE}"
        else
            info "aucun resolveur non filtrant joignable : une egalite d'adresses"
            info "ne pourra pas etre departagee et sera signalee sans conclure."
        fi

        while IFS='|' read -r hote domaines; do
            [ -n "${hote}" ] || continue
            premier="$(printf '%s' "${domaines}" | awk '{print $1}')"

            ip_stricte="$(resoudre_amont "${hote}")"
            ip_normale="$(resoudre_amont "${premier}")"

            if [ -z "${ip_stricte}" ]; then
                ko "${hote} ne resout pas — entree inutilisable"
                continue
            fi
            if [ -z "${ip_normale}" ]; then
                warn "${premier} ne resout pas depuis cette machine, comparaison ignoree"
                continue
            fi

            if [ "${ip_stricte}" != "${ip_normale}" ]; then
                ok "${hote} : adresse dediee (${ip_stricte}) distincte de ${premier}"
                continue
            fi

            # Egalite. Deux explications possibles, opposees : soit l'entree ne
            # force rien du tout, soit l'amont applique deja le SafeSearch et
            # renvoie l'adresse stricte pour les deux noms. Le resolveur neutre
            # tranche ; sans lui, on ne conclut pas.
            if [ -z "${NEUTRE}" ]; then
                warn "${hote} : meme adresse que ${premier} (${ip_stricte}) — indepartageable"
                info "aucun resolveur non filtrant joignable pour verifier si c'est"
                info "l'amont ${BLOCKER_UPSTREAM_1} qui reecrit deja ${premier}."
                continue
            fi

            ip_neutre="$(resoudre_via "${NEUTRE}" "${premier}")"
            if [ -z "${ip_neutre}" ]; then
                warn "${premier} ne resout pas via ${NEUTRE}, comparaison ignoree"
            elif [ "${ip_neutre}" != "${ip_stricte}" ]; then
                ok "${hote} : adresse dediee (${ip_stricte}), l'amont force deja le SafeSearch"
                info "${premier} vaut ${ip_neutre} via ${NEUTRE} mais ${ip_stricte} via"
                info "${BLOCKER_UPSTREAM_1} : l'entree reste utile si l'amont change."
            else
                ko "${hote} : adresse IDENTIQUE a celle de ${premier} (${ip_stricte})"
                info "meme constat via ${NEUTRE}, qui ne filtre pas : cette entree ne peut"
                info "rien forcer — le serveur ne distingue les deux requetes que par"
                info "l'en-tete Host, hors de portee du DNS. Mecanisme probablement par"
                info "cookie ou parametre d'URL : a retirer."
            fi
        done <<< "${entrees}"
    fi
fi

titre "6. Le fichier se regenere apres suppression"

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

titre "7. Le fichier genere est une configuration dnsmasq valide"

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
