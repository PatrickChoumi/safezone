#!/bin/bash
# blocker-adulte — test : hook initramfs et regles de base
#
# Critere d'acceptation n°3 : au demarrage en mode recovery / single-user, les
# regles nftables de base chargees depuis l'initramfs doivent etre actives.
#
# Trois generateurs d'images sont supportes, un par famille de distribution :
# initramfs-tools (Debian, Ubuntu), dracut (Fedora, RHEL, openSUSE) et
# mkinitcpio (Arch). Ils embarquent les MEMES deux fichiers, produits par les
# memes deux scripts ; seuls les points d'accroche et les outils d'inspection
# different. Ce test s'adapte a celui qui est en service.
#
# Ce test ne peut evidemment pas redemarrer la machine. Il verifie tout ce qui
# est verifiable a chaud :
#   1. les fichiers du generateur en service sont installes ;
#   2. blocker-base-rules produit un jeu de regles valide, avec le bon UID ;
#   3. l'image reellement installee contient nft, le chargeur et les regles ;
#   4. le jeu de regles extrait de l'image est valide et complet ;
#   5. l'UID inscrit dans l'image correspond a l'utilisateur actuel ;
#   6. si le systeme a demarre avec ces regles, la table de base est chargee ;
#   7. aucun script du hook ne touche au bootloader ni au firmware.
#
# La verification finale reste manuelle et est decrite dans le README :
# demarrer en mode recovery, puis « nft list table ip blocker_adulte_base_nat ».
#
# sudo tests/test_recovery_mode_hook.sh

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur, et le
# pipeline renvoie 141 alors que la chose cherchee est bien la.
set -u
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe

# shellcheck disable=SC1091
. /usr/lib/blocker-adulte/blocker-common.sh

GEN=/usr/lib/blocker-adulte/blocker-base-rules

if [ "${BLOCKER_INITRAMFS}" = "aucun" ]; then
    printf 'Aucun generateur d initramfs (ni initramfs-tools, ni dracut, ni mkinitcpio).\n' >&2
    printf 'Composant 4 non applicable. Test ignore.\n' >&2
    exit "${TEST_SKIP}"
fi

info "generateur en service : ${BLOCKER_INITRAMFS}"

BAC="$(mktemp -d)"
EXTRAIT=""
# Un seul trap pour les deux repertoires temporaires : un second « trap ... EXIT »
# remplacerait celui-ci et laisserait le premier repertoire derriere lui.
trap 'rm -rf "${BAC}" "${EXTRAIT}"' EXIT

# ---------------------------------------------------------------------------
titre "1. Fichiers du generateur installes"
# ---------------------------------------------------------------------------
FICHIERS_HOOK=""
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    FICHIERS_HOOK="${FICHIERS_HOOK} ${f}"
    if [ -e "${f}" ]; then
        ok "present : ${f}"
    else
        ko "absent : ${f}"
    fi
done < <(blocker_initramfs_hook_paths)

verifier "generateur de regles present et executable : ${GEN}" test -x "${GEN}"

# Arch : deposer les fichiers ne suffit pas, mkinitcpio n'execute que les hooks
# listes dans HOOKS. C'est le piege propre a cette distribution.
if [ "${BLOCKER_INITRAMFS}" = "mkinitcpio" ]; then
    if grep -qE '^HOOKS=.*blocker-adulte' /etc/mkinitcpio.conf 2>/dev/null; then
        ok "« blocker-adulte » est present dans HOOKS de /etc/mkinitcpio.conf"
    else
        ko "« blocker-adulte » absent de HOOKS : le hook ne s'executera jamais"
        info "l'ajouter puis « sudo mkinitcpio -P », ou mettre"
        info "BLOCKER_MKINITCPIO_HOOK=\"oui\" dans /etc/blocker-adulte/blocker.conf"
    fi
fi

# ---------------------------------------------------------------------------
titre "2. Le jeu de regles de base est produit correctement"
# ---------------------------------------------------------------------------
# C'est desormais un seul script qui produit ces regles pour les trois
# generateurs : le verifier ici les couvre tous.
if [ -x "${GEN}" ] && "${GEN}" > "${BAC}/base.nft" 2>"${BAC}/err"; then
    ok "blocker-base-rules produit un jeu de regles"

    if nft --check --file "${BAC}/base.nft" >/dev/null 2>&1; then
        ok "le jeu de regles produit est syntaxiquement valide"
    else
        ko "le jeu de regles produit est invalide"
        nft --check --file "${BAC}/base.nft" 2>&1 | sed 's/^/        /'
    fi

    uid_genere="$(grep -oP 'meta skuid \K[0-9]+' "${BAC}/base.nft" | head -1)"
    uid_reel="$(getent passwd blocker-adulte 2>/dev/null | cut -d: -f3)"
    if [ -n "${uid_genere}" ] && [ "${uid_genere}" = "${uid_reel}" ]; then
        ok "UID inscrit en dur coherent (${uid_genere})"
    else
        ko "UID incoherent : ${uid_genere:-aucun} genere, ${uid_reel:-aucun} reel"
    fi
else
    ko "blocker-base-rules n a pas produit de regles"
    sed 's/^/        /' "${BAC}/err" 2>/dev/null
fi

# Le hook initramfs-tools peut en plus etre execute a blanc dans un DESTDIR :
# cela exerce sa logique complete sans dependre d'une image deja construite.
# dracut et mkinitcpio n'offrent pas d'equivalent simple.
if [ "${BLOCKER_INITRAMFS}" = "initramfs-tools" ]; then
    HOOK=/etc/initramfs-tools/hooks/blocker-adulte
    noyau_dry="$(uname -r)"
    if ( DESTDIR="${BAC}/destdir"; verbose=n; version="${noyau_dry}"
         export DESTDIR verbose version
         mkdir -p "${DESTDIR}"; "${HOOK}" >/dev/null 2>&1 ); then
        ok "le hook initramfs-tools s'execute sans erreur"
    else
        warn "le hook a retourne un code non nul (modules noyau indisponibles ?)"
    fi
    if [ -e "${BAC}/destdir/usr/sbin/nft" ] || [ -e "${BAC}/destdir/sbin/nft" ]; then
        ok "le hook embarque le binaire nft"
    else
        ko "le hook n'a pas embarque nft"
    fi
    if [ -s "${BAC}/destdir/etc/blocker-adulte/base.nft" ]; then
        ok "le hook depose le jeu de regles dans l'image"
    else
        ko "le hook n'a pas depose etc/blocker-adulte/base.nft"
    fi
fi

# ---------------------------------------------------------------------------
titre "3. Contenu de l image initramfs reellement installee"
# ---------------------------------------------------------------------------
# Chaque generateur a son emplacement d'image et son outil d'inspection.
noyau="$(uname -r)"
IMAGE=""
LISTER=""
EXTRAIRE=""

case "${BLOCKER_INITRAMFS}" in
    initramfs-tools)
        for cand in "/boot/initrd.img-${noyau}" "$(readlink -f /boot/initrd.img 2>/dev/null)"; do
            [ -n "${cand}" ] && [ -r "${cand}" ] && { IMAGE="${cand}"; break; }
        done
        LISTER="lsinitramfs"; EXTRAIRE="unmkinitramfs" ;;
    dracut)
        for cand in "/boot/initramfs-${noyau}.img" "/boot/initrd-${noyau}"; do
            [ -r "${cand}" ] && { IMAGE="${cand}"; break; }
        done
        LISTER="lsinitrd"; EXTRAIRE="lsinitrd" ;;
    mkinitcpio)
        for cand in /boot/initramfs-linux.img /boot/initramfs-linux-lts.img; do
            [ -r "${cand}" ] && { IMAGE="${cand}"; break; }
        done
        LISTER="lsinitcpio"; EXTRAIRE="lsinitcpio" ;;
esac

CONTENU=""
if [ -z "${IMAGE}" ]; then
    warn "image initramfs introuvable pour le noyau ${noyau}, controles 3 a 5 ignores"
elif ! command -v "${LISTER}" >/dev/null 2>&1; then
    warn "${LISTER} absent, controles 3 a 5 ignores"
else
    info "image inspectee : ${IMAGE}"
    CONTENU="$("${LISTER}" "${IMAGE}" 2>/dev/null || true)"

    if printf '%s' "${CONTENU}" | grep -qE '(^|/)s?bin/nft$'; then
        ok "le binaire nft est embarque dans l'image"
    else
        ko "nft absent de l'image — reconstruire l'image"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'etc/blocker-adulte/base.nft'; then
        ok "le jeu de regles de base est embarque"
    else
        ko "etc/blocker-adulte/base.nft absent de l'image"
        info "l'utilisateur systeme existait-il lors de la derniere reconstruction ?"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'blocker-adulte-load-rules'; then
        ok "le chargeur est embarque dans l'image"
    else
        ko "blocker-adulte-load-rules absent de l'image"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'nf_tables'; then
        ok "les modules netfilter sont embarques"
    else
        warn "nf_tables non trouve — il est peut-etre compile en dur dans le noyau"
    fi
fi

# ---------------------------------------------------------------------------
titre "4. Validite du jeu de regles extrait de l image"
# ---------------------------------------------------------------------------
BASE=""
EXTRAIT="$(mktemp -d)"

if [ -n "${IMAGE}" ] && command -v "${EXTRAIRE}" >/dev/null 2>&1; then
    case "${BLOCKER_INITRAMFS}" in
        initramfs-tools)
            if unmkinitramfs "${IMAGE}" "${EXTRAIT}" >/dev/null 2>&1; then
                BASE="$(find "${EXTRAIT}" -path '*/etc/blocker-adulte/base.nft' -print -quit 2>/dev/null)"
            fi ;;
        dracut)
            # lsinitrd -f ecrit le contenu d'un fichier de l'image sur stdout.
            if lsinitrd -f etc/blocker-adulte/base.nft "${IMAGE}" > "${EXTRAIT}/base.nft" 2>/dev/null \
               && [ -s "${EXTRAIT}/base.nft" ]; then
                BASE="${EXTRAIT}/base.nft"
            fi ;;
        mkinitcpio)
            if ( cd "${EXTRAIT}" && lsinitcpio -x "${IMAGE}" >/dev/null 2>&1 ); then
                BASE="$(find "${EXTRAIT}" -path '*etc/blocker-adulte/base.nft' -print -quit 2>/dev/null)"
            fi ;;
    esac
fi

if [ -n "${BASE}" ] && [ -r "${BASE}" ]; then
    ok "jeu de regles extrait de l image"

    if nft --check --file "${BASE}" >/dev/null 2>&1; then
        ok "le jeu de regles de base est syntaxiquement valide"
    else
        ko "le jeu de regles de base est invalide"
        nft --check --file "${BASE}" 2>&1 | sed 's/^/        /'
    fi

    for motif in "blocker_adulte_base_nat" "dport 53" "dport 853"; do
        if grep -q -- "${motif}" "${BASE}"; then
            ok "regle de base presente : ${motif}"
        else
            ko "regle de base absente : ${motif}"
        fi
    done

    titre "5. Coherence de l UID inscrit dans l image"

    UID_REGLE="$(grep -oP 'meta skuid \K[0-9]+' "${BASE}" | head -1)"
    UID_REEL="$(getent passwd blocker-adulte 2>/dev/null | cut -d: -f3)"

    if [ -z "${UID_REGLE}" ]; then
        ko "aucun UID trouve dans le jeu de regles de base"
    elif [ "${UID_REGLE}" = "${UID_REEL}" ]; then
        ok "UID coherent : ${UID_REGLE} = utilisateur blocker-adulte actuel"
    else
        ko "UID incoherent : ${UID_REGLE} dans l'image, ${UID_REEL:-aucun} sur le systeme"
        info "au prochain boot, le resolveur se redirigerait vers lui-meme."
        info "Corriger : sudo /usr/lib/blocker-adulte/blocker-configure"
    fi
else
    warn "extraction impossible (${EXTRAIRE} absent ou image non lisible), controles 4 et 5 ignores"
fi

# ---------------------------------------------------------------------------
titre "6. Regles de base actives sur le systeme en cours"
# ---------------------------------------------------------------------------
if nft list table ip blocker_adulte_base_nat >/dev/null 2>&1; then
    ok "la table blocker_adulte_base_nat est chargee (heritee du boot initramfs)"
    info "c'est cette table qui reste active en mode recovery."
else
    warn "la table de base n'est pas chargee actuellement"
    info "Attendu si l'initramfs a ete regenere apres le dernier demarrage :"
    info "les regles seront presentes au prochain boot."
    info "Verification manuelle en mode recovery :"
    info "  nft list table ip blocker_adulte_base_nat"
fi

# ---------------------------------------------------------------------------
titre "7. Aucun script du hook ne touche au bootloader ni au firmware"
# ---------------------------------------------------------------------------
# Controle explicite de la ligne rouge du projet, applique aux fichiers du
# generateur en service ET au chargeur commun. Les commentaires sont exclus de
# la recherche : le mot « bootloader » y apparait justement pour dire qu'on n'y
# touche pas.
A_INSPECTER="${FICHIERS_HOOK} ${GEN}"
CHARGEUR=/usr/share/blocker-adulte/initramfs/blocker-load-rules
[ -e "${CHARGEUR}" ] && A_INSPECTER="${A_INSPECTER} ${CHARGEUR}"

souci=0
for interdit in grub efibootmgr systemd-boot bootctl efivar /sys/firmware; do
    # shellcheck disable=SC2086
    if grep -vE '^[[:space:]]*#' ${A_INSPECTER} 2>/dev/null \
       | grep -qi -- "${interdit}"; then
        ko "reference a « ${interdit} » hors commentaire dans les scripts du hook"
        souci=1
    fi
done
if [ "${souci}" -eq 0 ]; then
    ok "aucune manipulation du bootloader ni du firmware dans les scripts du hook"
fi

bilan
