#!/bin/bash
# blocker-adulte — module dracut (composant 4, Fedora, RHEL, openSUSE)
#
# Installe dans : /usr/lib/dracut/modules.d/99blocker-adulte/module-setup.sh
# Actif apres   : dracut --force --regenerate-all
#
# Equivalent strict du hook initramfs-tools de Debian et Ubuntu : il embarque
# dans l'image le binaire nft, les modules netfilter, le jeu de regles de base
# produit par blocker-base-rules, et le chargeur commun appele juste avant le
# switch_root.
#
# Ce module ne touche NI au bootloader NI au firmware : il ajoute des fichiers
# dans l'image initramfs, rien d'autre.

# shellcheck disable=SC2154  # $initdir, $moddir : fournis par dracut

GEN=/usr/lib/blocker-adulte/blocker-base-rules
LOADER=/usr/share/blocker-adulte/initramfs/blocker-load-rules

# dracut appelle check() pour savoir s'il doit inclure ce module. Sans nft ni
# generateur de regles, il n'y a rien a embarquer : on se retire proprement
# plutot que de produire une image a moitie equipee.
check() {
    require_binaries nft || return 1
    [ -x "${GEN}" ] || return 1
    return 0
}

depends() {
    return 0
}

installkernel() {
    # Sans eux, nft peut echouer dans l'initramfs avec « Operation not
    # supported ». La plupart sont deja integres aux noyaux courants : l'echec
    # d'un module n'est donc pas bloquant.
    instmods nf_tables nft_chain_nat nft_redir nft_reject nft_reject_inet \
             nf_nat nf_conntrack nf_defrag_ipv4 2>/dev/null || true
}

install() {
    inst_multiple nft modprobe

    mkdir -p "${initdir}/etc/blocker-adulte"
    if ! "${GEN}" > "${initdir}/etc/blocker-adulte/base.nft" 2>/dev/null; then
        rm -f "${initdir}/etc/blocker-adulte/base.nft"
        dwarn "blocker-adulte: generation des regles de base en echec, image sans regles"
        dwarn "blocker-adulte: lancer /usr/lib/blocker-adulte/blocker-configure puis dracut --force"
        return 0
    fi
    chmod 0644 "${initdir}/etc/blocker-adulte/base.nft"

    if [ -r "${LOADER}" ]; then
        inst_script "${LOADER}" /usr/sbin/blocker-adulte-load-rules
    else
        dwarn "blocker-adulte: chargeur ${LOADER} absent, regles non chargeables au boot"
        return 0
    fi

    # pre-pivot : apres le montage du disque racine, juste avant le switch_root.
    # C'est le moment equivalent a init-bottom chez initramfs-tools.
    inst_hook pre-pivot 95 "${moddir}/blocker-adulte-prepivot.sh"
}
