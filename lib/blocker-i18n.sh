# shellcheck shell=bash
# blocker-adulte — messages en francais et en anglais
#
# Installee dans /usr/lib/blocker-adulte/blocker-i18n.sh, chargee par
# blocker-common.sh.
#
# COMMENT CA MARCHE
#
# Une fonction, deux arguments : le francais, puis l'anglais.
#
#     blocker_info "$(m "resolveur demarre" "resolver started")"
#     printf '%s\n' "$(m "%d domaines bloques" "%d domains blocked")" ...
#
# POURQUOI PAS DES CATALOGUES A CLES, NI GETTEXT
#
# Les deux ont ete envisages. gettext imposerait msgfmt a la construction et un
# domaine de traduction a l'execution, pour un projet qui tient en quelques
# scripts shell installes par « make install » sur cinq familles de
# distributions. Des catalogues « cle=texte » eviteraient cette dependance mais
# introduiraient le defaut classique : une cle mal orthographiee ne se voit
# qu'a l'execution, et rien ne garantit que les deux catalogues restent
# synchronises.
#
# Avec les deux textes cote a cote dans le code, il ne peut pas y avoir de cle
# manquante, de traduction oubliee ni de catalogue en retard : un appel
# incomplet se voit a la lecture, et tests/test_i18n.sh le detecte
# mecaniquement. La contrepartie — deux langues seulement, une troisieme
# demanderait une reecriture — est un compromis assume : c'est ce qui a ete
# demande, et la conversion vers des catalogues resterait mecanique.
#
# LE CAS DU DESINSTALLEUR
#
# blocker-uninstall.sh redefinit « m » chez lui, en cinq lignes. Il doit
# fonctionner apres que la phase 3 a supprime /usr/lib/blocker-adulte : un
# desinstalleur qui dependrait d'un fichier qu'il vient d'effacer serait cassé
# au moment ou l'on en a le plus besoin.

# Langue effective. Ordre de decision :
#   1. BLOCKER_LANG dans /etc/blocker-adulte/blocker.conf (fr / en) ;
#   2. l'environnement (LC_ALL, LC_MESSAGES, LANG) ;
#   3. la locale du systeme (/etc/locale.conf, /etc/default/locale) — les
#      services systemd demarrent sans LANG, il faut donc cette source pour que
#      le journal parle la meme langue que le terminal ;
#   4. anglais.
blocker_langue() {
    local l
    case "${BLOCKER_LANG:-auto}" in
        fr|fr_*|francais|français) printf 'fr\n'; return 0 ;;
        en|en_*|english)           printf 'en\n'; return 0 ;;
    esac

    l="${LC_ALL:-}"
    [ -n "${l}" ] || l="${LC_MESSAGES:-}"
    [ -n "${l}" ] || l="${LANG:-}"

    case "${l}" in
        ''|C|C.*|POSIX)
            local f
            for f in /etc/locale.conf /etc/default/locale; do
                [ -r "${f}" ] || continue
                l="$(sed -n 's/^[[:space:]]*LANG=//p' "${f}" | head -1 | tr -d '"')"
                [ -n "${l}" ] && break
            done
            ;;
    esac

    case "${l}" in
        fr*|FR*) printf 'fr\n' ;;
        *)       printf 'en\n' ;;
    esac
}

BLOCKER_LANGUE="$(blocker_langue)"

# m "texte francais" "english text"
#
# Volontairement courte : elle apparait a chaque message affiche, et un nom
# long rendrait les lignes illisibles.
m() {
    if [ "${BLOCKER_LANGUE}" = "en" ]; then
        printf '%s' "${2-$1}"
    else
        printf '%s' "$1"
    fi
}
