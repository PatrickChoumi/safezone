#!/bin/bash
# blocker-adulte — test : coherence entre les fichiers du depot
#
# Plusieurs listes vivent a plusieurs endroits, volontairement pour certaines
# (le desinstalleur doit rester autonome), par necessite pour d'autres (le
# paquet Debian, les regles auditd, l'unite path). Une liste qui derive ne
# casse rien tout de suite : elle laisse un fichier derriere a la
# desinstallation, ou un repertoire de policies sans surveillance. La table
# nftables des tunnels a ainsi longtemps survecu a la desinstallation.
#
# Ce test croise ces listes. Il tourne depuis le depot, sans rien installer.
#
# tests/test_coherence.sh   (root non requis)

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -r "${DEPOT}/lib/blocker-common.sh" ] || [ ! -r "${DEPOT}/Makefile" ]; then
    echo "Depot source absent : test ignore." >&2
    exit "${TEST_SKIP}"
fi

UNINST="${DEPOT}/blocker-uninstall.sh"
README="${DEPOT}/README.md"
POSTRM="${DEPOT}/debian/postrm"
AUDIT="${DEPOT}/audit/blocker-adulte.rules"
CHEMIN_UNIT="${DEPOT}/systemd/blocker-policies.path"
MAKEFILE="${DEPOT}/Makefile"

# Les cibles navigateur, telles que la bibliotheque les declare.
cibles() { sed -n '/^blocker_browser_targets() {/,/^}/p' "${DEPOT}/lib/blocker-common.sh" | grep -E '^/etc/'; }

titre "1. Chaque repertoire de policies est connu partout"
n=0
while IFS='|' read -r dir fichier _famille; do
    n=$((n + 1))
    chemin="${dir}/${fichier}"
    manque=""
    grep -qF "${chemin}" "${README}"      || manque="${manque} README"
    grep -qF "${chemin}" "${UNINST}"      || manque="${manque} desinstalleur"
    grep -qF "${chemin}" "${POSTRM}"      || manque="${manque} postrm"
    grep -qF "${dir} " "${AUDIT}"         || manque="${manque} auditd"
    grep -qxF "PathChanged=${dir}" "${CHEMIN_UNIT}" || manque="${manque} unite-path"
    if [ -z "${manque}" ]; then ok "${chemin}"; else ko "${chemin} absent de :${manque}"; fi
done < <(cibles)
[ "${n}" -gt 0 ] || ko "aucune cible navigateur extraite de blocker-common.sh"

titre "2. Chaque famille de navigateur a un modele de policy installe"
for famille in $(cibles | cut -d'|' -f3 | sort -u); do
    modele="$(sed -n '/^blocker_policy_source() {/,/^}/p' "${DEPOT}/lib/blocker-common.sh" \
              | grep -E "(^|[|[:space:]])${famille}([|)])" | grep -oE 'policies/[a-z]+-policies\.json' | head -1)"
    if [ -z "${modele}" ]; then
        ko "${famille} : aucun modele dans blocker_policy_source"
    elif grep -qF "\$(sharedir)/${modele}" "${MAKEFILE}"; then
        ok "${famille} -> ${modele}"
    else
        ko "${famille} : ${modele} n est pas installe par le Makefile"
    fi
done

titre "3. Chaque unite systemd est installee, declaree et retiree"
for u in "${DEPOT}"/systemd/*; do
    nom="$(basename "${u}")"
    manque=""
    grep -qF "systemd/${nom}" "${MAKEFILE}" || manque="${manque} Makefile"
    grep -qF "/${nom}" "${README}"          || manque="${manque} README"
    grep -qF "${nom}" "${UNINST}"           || manque="${manque} desinstalleur"
    if [ -z "${manque}" ]; then ok "${nom}"; else ko "${nom} absent de :${manque}"; fi
done

titre "4. Chaque table nftables est dechargee a la desinstallation"
for t in $(grep -hoE '^table (ip|ip6|inet) blocker_adulte[a-z_]*' "${DEPOT}"/etc/nftables/*.nft | awk '{print $2 ":" $3}' | sort -u); do
    famille="${t%%:*}"; nom="${t#*:}"
    manque=""
    grep -qE "${famille}:${nom}([[:space:]]|\"|$)" "${UNINST}" || manque="${manque} desinstalleur"
    grep -qE "nft delete table ${famille} ${nom}( |$)" "${UNINST}" || manque="${manque} procedure-manuelle"
    grep -qE "nft delete table ${famille} ${nom}( |$)" "${POSTRM}" || manque="${manque} postrm"
    if [ -z "${manque}" ]; then ok "${famille} ${nom}"; else ko "${famille} ${nom} absent de :${manque}"; fi
done

titre "5. Chaque executable est installe"
for f in "${DEPOT}"/bin/*; do
    nom="$(basename "${f}")"
    if grep -qE "bin/${nom}[[:space:]]" "${MAKEFILE}"; then ok "${nom}"; else ko "${nom} non installe par le Makefile"; fi
done
for f in "${DEPOT}"/lib/*.sh; do
    nom="$(basename "${f}")"
    grep -qF "lib/${nom}" "${MAKEFILE}" && ok "${nom}" || ko "${nom} non installe par le Makefile"
done

titre "6. Le desinstalleur calcule le delai comme la bibliotheque"
# Il le recalcule chez lui pour rester autonome ; les deux doivent s'accorder.
grep -qE '^BLOCKER_DELAI_VALIDITE_HEURES=168$' "${DEPOT}/lib/blocker-delai.sh" && \
grep -qE '^VALIDITE_HEURES=168$' "${UNINST}" \
    && ok "fenetre de confirmation : 168 h des deux cotes" \
    || ko "fenetres de confirmation differentes"
grep -q '\[ "${h}" -lt 24 \] && h=24' "${DEPOT}/lib/blocker-delai.sh" && \
grep -q '\[ "${h}" -lt 24 \] && h=24' "${UNINST}" \
    && ok "plancher de 24 h des deux cotes" \
    || ko "planchers differents"
grep -q 'demandes' "${UNINST}" && grep -q '_blocker_demandes_dir() { printf .%s/demandes.' "${DEPOT}/lib/blocker-delai.sh" \
    && ok "meme repertoire de demandes" || ko "repertoires de demandes differents"

titre "7. Le modele de blocker.conf et les valeurs par defaut s'accordent"
# shellcheck disable=SC1091
. "${DEPOT}/lib/blocker-delai.sh"
for v in ${BLOCKER_CONF_VARIABLES}; do
    dans_modele="$(blocker_conf_valeur "${DEPOT}/share/conf/blocker.conf" "${v}")"
    defaut="$(blocker_conf_defaut "${v}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if ! grep -qE "^${v}=" "${DEPOT}/share/conf/blocker.conf"; then
        ko "${v} n est pas documentee dans le modele"
    elif [ "${dans_modele}" = "${defaut}" ]; then
        ok "${v}"
    else
        ko "${v} : modele « ${dans_modele} », defaut « ${defaut} »"
    fi
done

titre "7 bis. Chaque categorie livree est installee et active d'office"
for f in "${DEPOT}"/share/categories/*.liste; do
    nom="$(basename "${f}" .liste)"
    manque=""
    grep -qF "share/categories/${nom}.liste" "${MAKEFILE}" || manque="${manque} Makefile"
    case " $(blocker_conf_defaut BLOCKER_CATEGORIES) " in *" ${nom} "*) ;; *) manque="${manque} defaut" ;; esac
    grep -qF "${nom}" "${README}" || manque="${manque} README"
    if [ -z "${manque}" ]; then ok "${nom}"; else ko "${nom} absent de :${manque}"; fi
done
for d in reddit.com x.com telegram.org t.me moviebox.ng; do
    if grep -qxF "${d}" "${DEPOT}"/share/categories/*.liste; then ok "bloque d office : ${d}"
    else ko "${d} n est dans aucune categorie"; fi
done
grep -q '^ip 149\.154\.160\.0/20$' "${DEPOT}/share/categories/reseaux-sociaux.liste" \
    && ok "adresses de Telegram bloquees au niveau reseau" \
    || ko "adresses de Telegram absentes"

titre "8. Aucune exemption large du resolveur dans les tables de filtrage"
# L'utilisateur blocker-adulte n'a besoin que du port 53 vers ses amonts. Un
# « meta skuid ... accept » dans une table de filtrage exempterait tout
# programme lance sous son identite.
if grep -nE 'meta skuid .*accept' "${DEPOT}"/etc/nftables/*.nft "${DEPOT}/bin/blocker-base-rules"; then
    ko "exemption large trouvee ci-dessus"
else
    ok "aucun « meta skuid ... accept »"
fi
if grep -qE 'th dport 53 ip daddr @amonts' "${DEPOT}/etc/nftables/blocker-adulte.nft"; then
    ok "exemption NAT limitee aux amonts sur le port 53"
else
    ko "exemption NAT du resolveur non restreinte"
fi

bilan
