#!/bin/bash
# blocker-adulte — test : hook initramfs et regles de base
#
# Critere d'acceptation n°3 : au demarrage en mode recovery / single-user, les
# regles nftables de base chargees par le hook initramfs doivent etre actives.
#
# Ce test ne peut evidemment pas redemarrer la machine. Il verifie tout ce qui
# est verifiable a chaud :
#   1. le hook et le script de boot sont installes et executables ;
#   2. l'image initramfs contient reellement nft, les modules et le jeu de
#      regles de base (on inspecte l'image, on ne se fie pas aux fichiers
#      sources) ;
#   3. le jeu de regles embarque est syntaxiquement valide ;
#   4. l'UID inscrit en dur dans ces regles correspond bien a l'utilisateur
#      actuel — sinon le resolveur boucle sur lui-meme au prochain boot ;
#   5. si le systeme a demarre avec ces regles, la table de base est chargee.
#
# La verification finale reste manuelle et est decrite dans le README :
# demarrer en mode recovery, puis « nft list table ip blocker_adulte_base_nat ».
#
# sudo tests/test_recovery_mode_hook.sh

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur (nft list,
# ps aux, journalctl...), et le pipeline renvoie 141 — le controle echouerait
# alors que la chose cherchee est bien la. Le code de production, lui, garde
# pipefail et capture ses sorties avant de les filtrer.
set -u
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe

HOOK=/etc/initramfs-tools/hooks/blocker-adulte
INITB=/etc/initramfs-tools/scripts/init-bottom/blocker-adulte

if [ ! -d /etc/initramfs-tools ]; then
    printf 'initramfs-tools absent : composant 4 non applicable. Test ignore.\n' >&2
    exit "${TEST_SKIP}"
fi

titre "1. Fichiers du hook installes"

verifier "hook present et executable : ${HOOK}"   test -x "${HOOK}"
verifier "script de boot present et executable : ${INITB}" test -x "${INITB}"

titre "2. Execution du hook dans un DESTDIR temporaire"

# Ce controle exerce la logique du hook sans dependre d'une image initramfs
# deja construite : il fonctionne donc sur une machine dont /boot est vide
# (conteneur, chroot, image cloud) comme sur une installation normale.
BAC="$(mktemp -d)"
EXTRAIT=""
# Un seul trap pour les deux repertoires temporaires : un second « trap ... EXIT »
# remplacerait celui-ci et laisserait le premier repertoire derriere lui.
trap 'rm -rf "${BAC}" "${EXTRAIT}"' EXIT

if ( export DESTDIR="${BAC}" verbose=n version="$(uname -r)"; \
     "${HOOK}" >/dev/null 2>&1 ); then
    ok "le hook s'execute sans erreur"
else
    warn "le hook a retourne un code non nul (modules noyau indisponibles ?)"
    info "les deux controles suivants disent si l'essentiel a malgre tout ete produit."
fi

if [ -e "${BAC}/usr/sbin/nft" ] || [ -e "${BAC}/sbin/nft" ]; then
    ok "le hook embarque le binaire nft"
else
    ko "le hook n'a pas embarque nft"
fi

if [ -s "${BAC}/etc/blocker-adulte/base.nft" ]; then
    ok "le hook genere le jeu de regles de base"

    if nft --check --file "${BAC}/etc/blocker-adulte/base.nft" >/dev/null 2>&1; then
        ok "le jeu de regles genere est syntaxiquement valide"
    else
        ko "le jeu de regles genere est invalide"
        nft --check --file "${BAC}/etc/blocker-adulte/base.nft" 2>&1 | sed 's/^/        /'
    fi

    uid_genere="$(grep -oP 'meta skuid \K[0-9]+' "${BAC}/etc/blocker-adulte/base.nft" | head -1)"
    uid_reel="$(getent passwd blocker-adulte 2>/dev/null | cut -d: -f3)"
    if [ -n "${uid_genere}" ] && [ "${uid_genere}" = "${uid_reel}" ]; then
        ok "UID inscrit en dur coherent (${uid_genere})"
    else
        ko "UID incoherent : ${uid_genere:-aucun} genere, ${uid_reel:-aucun} reel"
    fi
else
    ko "le hook n'a pas genere etc/blocker-adulte/base.nft"
fi

titre "3. Contenu de l'image initramfs reellement installee"

exiger_commande lsinitramfs "initramfs-tools"

IMAGE="/boot/initrd.img-$(uname -r)"
if [ ! -r "${IMAGE}" ]; then
    # Certaines installations utilisent le lien /boot/initrd.img.
    IMAGE="$(readlink -f /boot/initrd.img 2>/dev/null || true)"
fi

if [ -z "${IMAGE}" ] || [ ! -r "${IMAGE}" ]; then
    warn "image initramfs introuvable pour le noyau $(uname -r), controles 4 et 5 ignores"
else
    info "image inspectee : ${IMAGE}"
    CONTENU="$(lsinitramfs "${IMAGE}" 2>/dev/null || true)"

    if printf '%s' "${CONTENU}" | grep -qE '(^|/)sbin/nft$'; then
        ok "le binaire nft est embarque dans l'image"
    else
        ko "nft absent de l'image — lancer « sudo update-initramfs -u »"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'etc/blocker-adulte/base.nft'; then
        ok "le jeu de regles de base est embarque"
    else
        ko "etc/blocker-adulte/base.nft absent de l'image"
        info "l'utilisateur systeme existait-il lors du dernier update-initramfs ?"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'scripts/init-bottom/blocker-adulte'; then
        ok "le script de boot est embarque"
    else
        ko "scripts/init-bottom/blocker-adulte absent de l'image"
    fi

    if printf '%s' "${CONTENU}" | grep -q 'nf_tables'; then
        ok "les modules netfilter sont embarques"
    else
        warn "nf_tables non trouve dans l'image — il est peut-etre compile en dur dans le noyau"
    fi

    titre "4. Validite du jeu de regles embarque dans l'image"

    EXTRAIT="$(mktemp -d)"

    if command -v unmkinitramfs >/dev/null 2>&1 && \
       unmkinitramfs "${IMAGE}" "${EXTRAIT}" >/dev/null 2>&1; then

        BASE="$(find "${EXTRAIT}" -path '*/etc/blocker-adulte/base.nft' -print -quit 2>/dev/null)"

        if [ -n "${BASE}" ] && [ -r "${BASE}" ]; then
            ok "jeu de regles extrait : $(basename "$(dirname "$(dirname "${BASE}")")")/etc/blocker-adulte/base.nft"

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

            titre "5. Coherence de l'UID inscrit dans l'image"

            UID_REGLE="$(grep -oP 'meta skuid \K[0-9]+' "${BASE}" | head -1)"
            UID_REEL="$(getent passwd blocker-adulte 2>/dev/null | cut -d: -f3)"

            if [ -z "${UID_REGLE}" ]; then
                ko "aucun UID trouve dans le jeu de regles de base"
            elif [ "${UID_REGLE}" = "${UID_REEL}" ]; then
                ok "UID coherent : ${UID_REGLE} = utilisateur blocker-adulte actuel"
            else
                ko "UID incoherent : ${UID_REGLE} dans l'image, ${UID_REEL:-aucun} sur le systeme"
                info "au prochain boot, le resolveur se redirigerait vers lui-meme."
                info "Corriger : sudo update-initramfs -u"
            fi
        else
            warn "base.nft introuvable dans l'image extraite, controles 4 et 5 ignores"
        fi
    else
        warn "unmkinitramfs indisponible ou extraction en echec, controles 4 et 5 ignores"
    fi
fi

titre "6. Regles de base actives sur le systeme en cours"

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

titre "7. Le hook ne touche ni au bootloader ni au firmware"

# Controle explicite de la ligne rouge du projet. Les commentaires sont exclus
# de la recherche : le mot « bootloader » y apparait justement pour dire qu'on
# n'y touche pas.
souci=0
for interdit in grub efibootmgr systemd-boot bootctl efivar /sys/firmware; do
    if grep -vE '^[[:space:]]*#' "${HOOK}" "${INITB}" 2>/dev/null \
       | grep -qi -- "${interdit}"; then
        ko "reference a « ${interdit} » hors commentaire dans les scripts du hook"
        souci=1
    fi
done
if [ "${souci}" -eq 0 ]; then
    ok "aucune manipulation du bootloader ni du firmware dans les scripts du hook"
fi

bilan
