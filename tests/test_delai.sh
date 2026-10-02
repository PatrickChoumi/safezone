#!/bin/bash
# blocker-adulte — test : le delai sur ce qui affaiblit la protection
#
# Verifie, sans rien installer et dans un repertoire temporaire :
#   1. qu'une proposition de blocker.conf n'est jamais executee : une commande
#      cachee dans une valeur ou sur une ligne est refusee, pas lancee ;
#   2. que chaque modification est classee dans le bon sens (renforce,
#      neutre, affaiblit), et qu'une modification inconnue affaiblit ;
#   3. qu'une demande neuve attend, et ne peut pas etre confirmee avant
#      l'echeance ;
#   4. qu'antidater le fichier d'une demande (touch -d) ne la rend pas mure :
#      l'age se lit sur le ctime, que touch ne peut pas reculer ;
#   5. que le delai a un plancher de 24 heures ;
#   6. qu'aucune desinstallation n'est autorisee sans demande arrivee a
#      echeance.
#
# tests/test_delai.sh   (root non requis)

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${DEPOT}/lib/blocker-delai.sh"
[ -r "${LIB}" ] || LIB=/usr/lib/blocker-adulte/blocker-delai.sh
[ -r "${LIB}" ] || { echo "blocker-delai.sh introuvable." >&2; exit "${TEST_SKIP}"; }
MODELE="${DEPOT}/share/conf/blocker.conf"
[ -r "${MODELE}" ] || MODELE=/usr/share/blocker-adulte/conf/blocker.conf

BAC="$(mktemp -d)"
nettoyer() { chattr -R -i -a "${BAC}" 2>/dev/null; rm -rf "${BAC}"; }
trap nettoyer EXIT

# shellcheck disable=SC1090
. "${LIB}"
BLOCKER_DELAIDIR="${BAC}/delai"
BLOCKER_DELAI_HEURES=48
SUDO_USER="test"

titre "1. Une proposition n'est jamais executee"
TEMOIN="${BAC}/temoin"
cat > "${BAC}/piege.conf" <<EOF
BLOCKER_LANG="fr"
BLOCKER_SAFESEARCH="\$(touch ${TEMOIN})"
BLOCKER_BLOCK_TUNNELS=\`touch ${TEMOIN}\`
touch ${TEMOIN}
BLOCKER_INCONNUE="x"
BLOCKER_LIST_URLS="https://exemple.invalid/liste
EOF
blocker_conf_lire "${BAC}/piege.conf" > "${BAC}/lu"
if [ -e "${TEMOIN}" ]; then
    ko "la lecture de la proposition a execute une commande"
else
    ok "aucune commande executee a la lecture"
fi
n_err="$(grep -c '^ERREUR' "${BAC}/lu")"
[ "${n_err}" -ge 5 ] && ok "${n_err} lignes refusees (substitution, accent grave, commande, variable inconnue, guillemet)" \
                     || ko "seulement ${n_err} lignes refusees"
verifier_echec "la proposition piegee est declaree invalide" blocker_conf_valide "${BAC}/piege.conf"
verifier "le modele livre est valide" blocker_conf_valide "${MODELE}"

titre "2. Classement des modifications"
cp "${MODELE}" "${BAC}/vigueur.conf"
classer() {
    local sed_expr="$1" attendu="$2" libelle="$3" obtenu
    sed "${sed_expr}" "${BAC}/vigueur.conf" > "${BAC}/propose.conf"
    obtenu="$(blocker_conf_comparer "${BAC}/vigueur.conf" "${BAC}/propose.conf" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [ "${obtenu}" = "${attendu}" ]; then
        ok "${libelle} : ${attendu}"
    else
        ko "${libelle} : attendu « ${attendu} », obtenu « ${obtenu} »"
    fi
}
classer 's/^BLOCKER_SAFESEARCH=.*/BLOCKER_SAFESEARCH="non"/'       affaiblit "SafeSearch desactive"
classer 's/^BLOCKER_BLOCK_TUNNELS=.*/BLOCKER_BLOCK_TUNNELS="non"/' affaiblit "tunnels autorises"
classer 's/^BLOCKER_LOCK_HOSTS=.*/BLOCKER_LOCK_HOSTS="non"/'       affaiblit "/etc/hosts deverrouille"
classer 's/^BLOCKER_LOCK_HOSTS=.*/BLOCKER_LOCK_HOSTS="oui"/'       renforce  "/etc/hosts toujours verrouille"
classer 's/^BLOCKER_UPSTREAM_1=.*/BLOCKER_UPSTREAM_1="1.1.1.3"/'   affaiblit "amont change (dans le doute)"
classer 's/^BLOCKER_DELAI_HEURES=.*/BLOCKER_DELAI_HEURES="24"/'     affaiblit "delai raccourci"
classer 's/^BLOCKER_DELAI_HEURES=.*/BLOCKER_DELAI_HEURES="72"/'     renforce  "delai allonge"
classer 's/^BLOCKER_CATEGORIES=.*/BLOCKER_CATEGORIES="moteurs-sans-filtre"/' affaiblit "categorie retiree"
classer 's/^BLOCKER_LANG=.*/BLOCKER_LANG="en"/'                     neutre    "langue"
classer 's/^BLOCKER_RAPPORT_DESTINATAIRE=.*/BLOCKER_RAPPORT_DESTINATAIRE="ami@exemple.org"/' renforce "destinataire ajoute"
sed -i 's/^BLOCKER_RAPPORT_DESTINATAIRE=.*/BLOCKER_RAPPORT_DESTINATAIRE="ami@exemple.org"/' "${BAC}/vigueur.conf"
classer 's/^BLOCKER_RAPPORT_DESTINATAIRE=.*/BLOCKER_RAPPORT_DESTINATAIRE=""/' affaiblit "destinataire retire"
classer 's/^BLOCKER_RAPPORT_SMTP=.*/BLOCKER_RAPPORT_SMTP="smtps:\/\/autre.exemple:465"/' affaiblit "serveur du rapport change"
classer '/^https:\/\/raw.githubusercontent.com\/hagezi/d; s/^\(BLOCKER_LIST_URLS="[^"]*\)$/\1"/' affaiblit "URL de liste retiree"

titre "3. Une demande neuve attend"
id="$(blocker_demande_creer retirer-domaine exemple.org)"
if [ -n "${id}" ] && [ -e "${BLOCKER_DELAIDIR}/demandes/${id}" ]; then
    ok "demande creee : ${id}"
else
    ko "aucune demande creee"; bilan; exit 1
fi
etat="$(blocker_demande_etat "${id}")"
[ "${etat}" = "attente" ] && ok "etat : attente" || ko "etat : ${etat}, attendu attente"
reste=$(( $(blocker_demande_echeance "${id}") - $(date +%s) ))
[ "${reste}" -gt $((47 * 3600)) ] && ok "echeance dans environ 48 h" || ko "echeance dans ${reste} s seulement"
verifier_echec "confirmation refusee avant l echeance" blocker_demande_confirmer "${id}"
[ "$(blocker_demande_existante retirer-domaine exemple.org)" = "${id}" ] \
    && ok "une seconde demande identique est reconnue comme deja en cours" \
    || ko "demande en cours non retrouvee"

titre "4. Antidater ne sert a rien"
f="${BLOCKER_DELAIDIR}/demandes/${id}"
chattr -i "${f}" 2>/dev/null
touch -d '10 days ago' "${f}"
etat="$(blocker_demande_etat "${id}")"
[ "${etat}" = "attente" ] && ok "touch -d « il y a 10 jours » : toujours en attente (ctime inchange)" \
                          || ko "antidater la demande l a fait passer a « ${etat} »"

titre "5. Plancher du delai"
BLOCKER_DELAI_HEURES=1
[ "$(blocker_delai_secondes)" -eq $((24 * 3600)) ] && ok "un delai de 1 h est ramene a 24 h" \
                                                  || ko "delai de 1 h accepte : $(blocker_delai_secondes) s"
BLOCKER_DELAI_HEURES=abc
[ "$(blocker_delai_secondes)" -eq $((48 * 3600)) ] && ok "une valeur invalide donne 48 h" \
                                                  || ko "valeur invalide : $(blocker_delai_secondes) s"
BLOCKER_DELAI_HEURES=48

titre "6. Pas de desinstallation sans demande arrivee a echeance"
verifier_echec "aucune demande : retrait non autorise" blocker_retrait_autorise
id2="$(blocker_demande_creer desinstallation blocker-adulte)"
verifier_echec "demande deposee a l instant : retrait toujours non autorise" blocker_retrait_autorise

titre "7. Annulation et journal"
blocker_demande_clore "${id}" annulee
[ "$(blocker_demande_etat "${id}")" = "absente" ] && ok "demande annulee : plus aucune trace active" \
                                                 || ko "la demande annulee existe encore"
blocker_demande_clore "${id2}" annulee
if grep -q "annulee retirer-domaine exemple.org" "${BLOCKER_DELAIDIR}/historique" 2>/dev/null; then
    ok "l annulation est inscrite au journal des demandes"
else
    ko "journal des demandes incomplet"
fi

bilan
