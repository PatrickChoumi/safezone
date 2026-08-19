#!/bin/bash
# blocker-adulte — test : messages en francais et en anglais
#
# Les deux textes de chaque message vivent cote a cote dans le code, via la
# fonction « m » :
#
#     blocker_info "$(m "resolveur demarre" "resolver started")"
#
# Ce choix supprime le risque classique des catalogues a cles — une cle
# manquante, une traduction en retard — mais en introduit un autre : un appel
# ecrit avec un seul argument. Il n'echouerait pas a l'execution, il afficherait
# simplement du francais a un lecteur anglophone, sans que rien ne le signale.
#
# Ce test est ce qui remplace la verification qu'un compilateur ferait :
#   1. la fonction « m » se comporte comme annoncee ;
#   2. la langue est choisie dans le bon ordre de priorite ;
#   3. aucun appel a « m » n'est incomplet, dans tout le depot ;
#   4. les commandes principales produisent bien deux sorties differentes.
#
# sudo tests/test_i18n.sh

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -r "${DEPOT}/lib/blocker-i18n.sh" ]; then
    I18N="${DEPOT}/lib/blocker-i18n.sh"
    SOURCE_DEPOT=1
else
    I18N=/usr/lib/blocker-adulte/blocker-i18n.sh
    SOURCE_DEPOT=0
fi
[ -r "${I18N}" ] || { echo "blocker-i18n.sh introuvable." >&2; exit "${TEST_SKIP}"; }

BAC="$(mktemp -d)"
trap 'rm -rf "${BAC}"' EXIT

# Rejoue le choix de langue dans un environnement maitrise.
langue_avec() {
    (
        unset LC_ALL LC_MESSAGES LANG BLOCKER_LANG
        while [ $# -gt 0 ]; do
            case "$1" in *=*) export "${1?}" ;; esac
            shift
        done
        # shellcheck disable=SC1090
        . "${I18N}"
        printf '%s' "${BLOCKER_LANGUE}"
    )
}

# ---------------------------------------------------------------------------
titre "1. La fonction « m » rend le bon texte"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090  # chemin choisi a l'execution (depot ou systeme)
fr="$( BLOCKER_LANG=fr; export BLOCKER_LANG; . "${I18N}"; m "bonjour" "hello" )"
# shellcheck disable=SC1090
en="$( BLOCKER_LANG=en; export BLOCKER_LANG; . "${I18N}"; m "bonjour" "hello" )"

[ "${fr}" = "bonjour" ] && ok "BLOCKER_LANG=fr rend le francais" \
                        || ko "BLOCKER_LANG=fr rend « ${fr} »"
[ "${en}" = "hello" ]   && ok "BLOCKER_LANG=en rend l anglais" \
                        || ko "BLOCKER_LANG=en rend « ${en} »"

# Un appel a un seul argument ne doit jamais rien afficher de vide : mieux vaut
# du francais pour un anglophone qu'une ligne blanche.
# shellcheck disable=SC1090
seul="$( BLOCKER_LANG=en; export BLOCKER_LANG; . "${I18N}"; m "seulement francais" )"
[ "${seul}" = "seulement francais" ] \
    && ok "un appel a un seul argument retombe sur le premier texte" \
    || ko "un appel a un seul argument rend « ${seul} »"

# ---------------------------------------------------------------------------
titre "2. Ordre de priorite du choix de la langue"
# ---------------------------------------------------------------------------
# BLOCKER_LANG doit gagner sur l'environnement : c'est le reglage explicite de
# l'utilisateur dans blocker.conf.
r="$(langue_avec BLOCKER_LANG=en LANG=fr_FR.UTF-8)"
[ "${r}" = "en" ] && ok "BLOCKER_LANG l emporte sur LANG" \
                  || ko "BLOCKER_LANG=en + LANG=fr_FR donne ${r}"

r="$(langue_avec LANG=fr_FR.UTF-8)"
[ "${r}" = "fr" ] && ok "LANG=fr_FR donne le francais" || ko "LANG=fr_FR donne ${r}"

r="$(langue_avec LANG=en_GB.UTF-8)"
[ "${r}" = "en" ] && ok "LANG=en_GB donne l anglais" || ko "LANG=en_GB donne ${r}"

r="$(langue_avec LC_ALL=fr_CA.UTF-8 LANG=en_US.UTF-8)"
[ "${r}" = "fr" ] && ok "LC_ALL l emporte sur LANG" || ko "LC_ALL=fr_CA + LANG=en_US donne ${r}"

r="$(langue_avec LANG=de_DE.UTF-8)"
[ "${r}" = "en" ] && ok "une langue non geree retombe sur l anglais" \
                  || ko "LANG=de_DE donne ${r}"

# Le cas qui compte vraiment : un service systemd demarre SANS LANG. Sans
# lecture de la locale du systeme, le journal parlerait anglais alors que le
# terminal parle francais.
r="$(langue_avec)"
info "sans aucune variable d environnement : ${r} (lu depuis la locale du systeme)"
if [ -r /etc/locale.conf ] || [ -r /etc/default/locale ]; then
    attendu=en
    l="$(sed -n 's/^[[:space:]]*LANG=//p' /etc/locale.conf /etc/default/locale 2>/dev/null \
         | head -1 | tr -d '"')"
    case "${l}" in fr*) attendu=fr ;; esac
    [ "${r}" = "${attendu}" ] \
        && ok "la locale du systeme (LANG=${l:-absente}) est bien prise en compte" \
        || ko "locale systeme ${l:-absente} : attendu ${attendu}, obtenu ${r}"
else
    [ "${r}" = "en" ] && ok "sans locale systeme, repli sur l anglais" \
                      || ko "sans locale systeme, obtenu ${r}"
fi

# ---------------------------------------------------------------------------
titre "3. Aucun appel a « m » incomplet dans le depot"
# ---------------------------------------------------------------------------
if [ "${SOURCE_DEPOT}" -eq 0 ]; then
    warn "depot source absent : controle statique ignore"
else
    incomplets=0
    total=0
    identiques=0

    for f in "${DEPOT}"/install.sh "${DEPOT}"/blocker-uninstall.sh \
             "${DEPOT}"/bin/* "${DEPOT}"/lib/*.sh "${DEPOT}"/tests/*.sh; do
        [ -f "${f}" ] || continue
        case "${f}" in */blocker-i18n.sh) continue ;; esac   # c'est sa definition

        # Les appels s'etendent souvent sur deux lignes : on recolle les
        # continuations avant d'analyser, sinon le second argument passerait
        # pour absent.
        joint="$(sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' "${f}")"

        n_total="$(printf '%s\n' "${joint}" | grep -oE '\$\(m "' | wc -l)"
        total=$((total + n_total))

        # Un appel complet : $(m "..." "..."). Un appel a un seul argument se
        # termine par une parenthese juste apres la premiere chaine.
        mauvais="$(printf '%s\n' "${joint}" | grep -nE '\$\(m "[^"]*"[[:space:]]*\)' || true)"
        if [ -n "${mauvais}" ]; then
            ko "appel a « m » sans traduction anglaise dans $(basename "${f}") :"
            printf '%s\n' "${mauvais}" | cut -c1-120 | sed 's/^/        /'
            incomplets=$((incomplets + 1))
        fi

        # Un second argument vide afficherait une ligne blanche en anglais.
        vides="$(printf '%s\n' "${joint}" | grep -nE '\$\(m "[^"]*"[[:space:]]+""' || true)"
        if [ -n "${vides}" ]; then
            ko "traduction anglaise vide dans $(basename "${f}") :"
            printf '%s\n' "${vides}" | cut -c1-120 | sed 's/^/        /'
            incomplets=$((incomplets + 1))
        fi

        n_ident="$(printf '%s\n' "${joint}" \
                   | grep -oE '\$\(m "([^"]*)"[[:space:]]+"\1"\)' | wc -l)"
        identiques=$((identiques + n_ident))
    done

    if [ "${total}" -eq 0 ]; then
        ko "aucun appel a « m » trouve : la traduction est-elle bien en place ?"
    else
        ok "${total} appels a « m » analyses"
    fi
    [ "${incomplets}" -eq 0 ] && ok "aucun appel incomplet"
    [ "${identiques}" -gt 0 ] && \
        info "${identiques} appels ou les deux langues sont identiques (« distribution », noms propres) : normal"
fi

# ---------------------------------------------------------------------------
titre "4. Les commandes produisent bien deux sorties differentes"
# ---------------------------------------------------------------------------
if [ -x /usr/sbin/blocker-status ]; then
    sfr="$(BLOCKER_LANG=fr /usr/sbin/blocker-status --court 2>&1 | head -1)"
    sen="$(BLOCKER_LANG=en /usr/sbin/blocker-status --court 2>&1 | head -1)"
    info "fr : ${sfr}"
    info "en : ${sen}"
    if [ -n "${sfr}" ] && [ -n "${sen}" ] && [ "${sfr}" != "${sen}" ]; then
        ok "blocker-status --court parle bien deux langues"
    else
        ko "blocker-status --court rend la meme chose dans les deux langues"
    fi
else
    warn "blocker-status non installe, controle ignore"
fi

if [ -x /usr/sbin/blocker-uninstall ]; then
    ufr="$(BLOCKER_LANG=fr /usr/sbin/blocker-uninstall --manuel 2>&1 | head -3 | tail -1)"
    uen="$(BLOCKER_LANG=en /usr/sbin/blocker-uninstall --manuel 2>&1 | head -3 | tail -1)"
    if [ "${ufr}" != "${uen}" ]; then
        ok "blocker-uninstall --manuel parle bien deux langues"
    else
        ko "blocker-uninstall --manuel rend la meme chose dans les deux langues"
    fi
else
    warn "blocker-uninstall non installe, controle ignore"
fi

bilan
