#!/bin/bash
# blocker-adulte — test : plateformes mixtes et blocage par motif
#
# Ce test couvre le trou trouve en usage reel : MovieBox, installe sur un PC
# protege, resolu sans obstacle. Ni StevenBlack porn-only ni Hagezi NSFW ne le
# listent — ces listes classent par domaine DEDIE, et une plateforme de
# streaming non officielle n'en est pas un.
#
# Il verifie les trois pieces de la reponse :
#   1. la liste categorielle livree (02-plateformes.conf) est bien formee ;
#   2. le developpement d'un motif couvre la rotation de miroirs ;
#   3. la mise a jour quotidienne des listes n'efface plus la liste
#      personnelle ni les motifs.
#
# Le point 3 est une regression : le motif de suppression « [1-9][0-9]-*.conf »
# attrapait 50-perso.conf et 51-motifs.conf en meme temps que 10-liste.conf.
# Tout ce que l'utilisateur ajoutait a la main disparaissait a la passe
# suivante du timer, sans un mot dans le journal.
#
# sudo tests/test_plateformes.sh

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"

# Les sources : celles du depot si le test tourne depuis le depot, celles de
# l'installation sinon (le test est aussi pose dans /usr/share).
if [ -r "${DEPOT}/share/blocklists/02-plateformes.conf" ]; then
    LISTE="${DEPOT}/share/blocklists/02-plateformes.conf"
else
    LISTE=/usr/share/blocker-adulte/blocklists/02-plateformes.conf
fi

if [ -r "${DEPOT}/bin/blocker-block" ]; then
    SRC_BLOCK="${DEPOT}/bin/blocker-block"
    SRC_UPDATE="${DEPOT}/bin/blocker-list-update"
else
    SRC_BLOCK=/usr/sbin/blocker-block
    SRC_UPDATE=/usr/lib/blocker-adulte/blocker-list-update
fi

# ---------------------------------------------------------------------------
titre "1. La liste des plateformes mixtes est bien formee"
# ---------------------------------------------------------------------------

if [ ! -r "${LISTE}" ]; then
    ko "liste introuvable : ${LISTE}"
    bilan; exit 1
fi
ok "liste trouvee : ${LISTE}"

nb="$(grep -c '^address=/' "${LISTE}" || true)"
if [ "${nb}" -ge 20 ]; then
    ok "${nb} domaines listes"
else
    ko "seulement ${nb} domaines : la liste a-t-elle ete tronquee ?"
fi

# Toute ligne utile doit etre une directive dnsmasq complete. Une ligne mal
# formee empecherait le resolveur de demarrer — donc plus aucun DNS du tout.
mauvaises="$(grep -vE '^[[:space:]]*(#|$)' "${LISTE}" | grep -vE '^address=/[a-z0-9.-]+/#$' || true)"
if [ -z "${mauvaises}" ]; then
    ok "toutes les lignes utiles sont des directives « address=/domaine/# »"
else
    ko "lignes mal formees :"
    printf '%s\n' "${mauvaises}" | head -5 | sed 's/^/        /'
fi

doublons="$(grep '^address=/' "${LISTE}" | sort | uniq -d || true)"
if [ -z "${doublons}" ]; then
    ok "aucun doublon"
else
    ko "doublons dans la liste :"
    printf '%s\n' "${doublons}" | head -5 | sed 's/^/        /'
fi

# Le cas qui a motive tout ce travail.
if grep -q '^address=/moviebox\.ng/#$' "${LISTE}"; then
    ok "moviebox.ng est bien dans la liste"
else
    ko "moviebox.ng absent — c'est pourtant le domaine a l'origine de cette liste"
fi

if command -v dnsmasq >/dev/null 2>&1; then
    if dnsmasq --test --conf-file="${LISTE}" >/dev/null 2>&1; then
        ok "dnsmasq accepte la liste telle quelle"
    else
        ko "dnsmasq refuse la liste : le resolveur ne demarrerait pas"
        dnsmasq --test --conf-file="${LISTE}" 2>&1 | head -3 | sed 's/^/        /'
    fi
else
    warn "dnsmasq absent : validation syntaxique par dnsmasq ignoree"
fi

# ---------------------------------------------------------------------------
titre "2. Le developpement d'un motif couvre la rotation de miroirs"
# ---------------------------------------------------------------------------

# On extrait la table et la fonction du script reel plutot que d'en recopier
# une version dans le test : une copie aurait cesse de suivre l'originale a la
# premiere extension ajoutee, et le test serait devenu vert pour rien.
FRAG="$(mktemp)"
trap 'rm -f "${FRAG}"' EXIT

sed -n '/^TLD_MIROIRS=/,/^VARIANTES_MOTIF=/p; /^developper_motif()/,/^}/p' \
    "${SRC_BLOCK}" > "${FRAG}"

if ! grep -q '^developper_motif()' "${FRAG}" || ! grep -q '^TLD_MIROIRS=' "${FRAG}"; then
    ko "impossible d extraire la table des extensions de ${SRC_BLOCK}"
    info "le test ne verifie donc RIEN du blocage par motif : le corriger"
    info "avant de se fier a ce resultat."
else
    ok "table des extensions et fonction de developpement extraites de blocker-block"

    # shellcheck disable=SC1090
    EXP="$(. "${FRAG}"; developper_motif moviebox)"
    nb_exp="$(printf '%s\n' "${EXP}" | grep -c '^address=/' || true)"
    nb_uniq="$(printf '%s\n' "${EXP}" | sort -u | wc -l)"

    if [ "${nb_exp}" -ge 500 ]; then
        ok "« moviebox » developpe en ${nb_exp} domaines"
    else
        ko "« moviebox » ne developpe qu en ${nb_exp} domaines : couverture trop mince"
    fi

    if [ "${nb_exp}" -eq "${nb_uniq}" ]; then
        ok "aucun doublon dans le developpement"
    else
        ko "$((nb_exp - nb_uniq)) doublons dans le developpement"
    fi

    # Les formes reellement rencontrees : le domaine du jour, un autre TLD,
    # une variante numerotee, une variante suffixee.
    for attendu in moviebox.ng moviebox.pro moviebox.to moviebox2.cc \
                   movieboxhd.site moviebox-pro.xyz; do
        if printf '%s\n' "${EXP}" | grep -qxF "address=/${attendu}/#"; then
            ok "couvre ${attendu}"
        else
            ko "ne couvre pas ${attendu}"
        fi
    done

    if printf '%s\n' "${EXP}" | grep -vqE '^address=/[a-z0-9.-]+/#$'; then
        ko "le developpement produit des lignes mal formees"
    else
        ok "toutes les lignes produites sont des directives valides"
    fi
fi

# ---------------------------------------------------------------------------
titre "2 bis. Les motifs livres par defaut"
# ---------------------------------------------------------------------------

if [ -r "${DEPOT}/share/motifs-defaut" ]; then
    DEFAUT="${DEPOT}/share/motifs-defaut"
else
    DEFAUT=/usr/share/blocker-adulte/motifs-defaut
fi

if [ ! -r "${DEFAUT}" ]; then
    ko "motifs livres introuvables : ${DEFAUT}"
else
    nb_def="$(grep -cvE '^[[:space:]]*(#|$)' "${DEFAUT}" || true)"
    if [ "${nb_def}" -ge 10 ]; then
        ok "${nb_def} motifs livres par defaut"
    else
        ko "seulement ${nb_def} motifs livres"
    fi

    # Chaque motif doit passer la validation de blocker-block. Un motif rejete
    # serait pose dans /var/lib puis ignore en silence : le paquet promettrait
    # une couverture qu'il ne fournit pas.
    eval "$(sed -n '/^motif_valide()/,/^}/p' "${SRC_BLOCK}")"
    invalides=""
    while IFS= read -r mot; do
        case "${mot}" in ''|'#'*) continue ;; esac
        motif_valide "${mot}" || invalides="${invalides} ${mot}"
    done < "${DEFAUT}"
    if [ -z "${invalides}" ]; then
        ok "tous les motifs livres passent la validation de blocker-block"
    else
        ko "motifs livres refuses par blocker-block :${invalides}"
    fi

    # Un nom trop court attraperait des domaines legitimes en masse.
    courts="$(grep -vE '^[[:space:]]*(#|$)' "${DEFAUT}" | awk 'length($0) < 5 {print}' || true)"
    if [ -z "${courts}" ]; then
        ok "aucun motif livre de moins de 5 caracteres"
    else
        ko "motifs livres trop courts (risque de faux positifs) :"
        printf '%s\n' "${courts}" | sed 's/^/        /'
    fi
fi

# ---------------------------------------------------------------------------
titre "3. La mise a jour des listes epargne la liste personnelle"
# ---------------------------------------------------------------------------

# Le motif de suppression est lu dans blocker-list-update, pas recopie ici :
# c'est le motif reel qui doit etre mis a l'epreuve, pas une idee de ce qu'il
# devrait etre.
MOTIF_SUPPR="$(grep -oE "\-name '[^']+' -delete" "${SRC_UPDATE}" \
               | head -1 | sed "s/^-name '//; s/' -delete$//")"

if [ -z "${MOTIF_SUPPR}" ]; then
    ko "motif de suppression introuvable dans ${SRC_UPDATE}"
else
    info "motif de suppression en vigueur : ${MOTIF_SUPPR}"

    BAC="$(mktemp -d)"
    for f in 00-base.conf 02-plateformes.conf 01-upstream.conf 05-safesearch.conf \
             10-liste.conf 11-liste.conf 50-perso.conf 51-motifs.conf; do
        : > "${BAC}/${f}"
    done

    find "${BAC}" -maxdepth 1 -name "${MOTIF_SUPPR}" -delete

    # Ce qui doit disparaitre : les listes telechargees, et elles seules.
    for f in 10-liste.conf 11-liste.conf; do
        if [ -e "${BAC}/${f}" ]; then
            ko "${f} a survecu : les listes telechargees ne sont plus renouvelees"
        else
            ok "${f} supprimee, comme prevu"
        fi
    done

    # Ce qui doit survivre.
    for f in 00-base.conf 02-plateformes.conf 01-upstream.conf 05-safesearch.conf \
             50-perso.conf 51-motifs.conf; do
        if [ -e "${BAC}/${f}" ]; then
            ok "${f} conservee"
        else
            ko "${f} effacee par la mise a jour des listes — regression"
        fi
    done

    rm -rf "${BAC}"
fi

# ---------------------------------------------------------------------------
titre "4. Blocage effectif (machine equipee seulement)"
# ---------------------------------------------------------------------------

if [ ! -d /usr/lib/blocker-adulte ]; then
    warn "blocker-adulte n est pas installe : controle de blocage ignore"
elif ! command -v dig >/dev/null 2>&1; then
    warn "dig absent (paquet dnsutils / bind-utils) : controle de blocage ignore"
elif ! pgrep -x dnsmasq >/dev/null 2>&1; then
    warn "aucun resolveur en cours : controle de blocage ignore"
else
    POSEE="/var/lib/blocker-adulte/blocklists/02-plateformes.conf"
    if [ -s "${POSEE}" ]; then
        ok "la liste est bien posee dans ${POSEE}"
    else
        ko "liste absente de ${POSEE} : blocker-configure l a-t-il posee ?"
        info "la reposer : sudo /usr/lib/blocker-adulte/blocker-selfheal"
    fi

    for d in moviebox.ng moviebox.pro vidsrc.to; do
        verifier_bloque "${d}"
    done
fi

bilan
