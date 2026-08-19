#!/bin/bash
# blocker-adulte — test : portabilite entre distributions
#
# L'outil est ne sur Ubuntu et en avait pris toutes les habitudes. Ce test
# verifie qu'elles sont bien toutes passees dans lib/blocker-os.sh, et que la
# detection donne le bon resultat pour les familles supportees.
#
# Il ne demande ni Fedora, ni Arch, ni openSUSE : la detection est rejouee avec
# l'identite de chacune, grace aux deux variables d'indirection de
# blocker-os.sh (BLOCKER_OS_RELEASE, BLOCKER_INITRAMFS_DIR) et a des
# gestionnaires de paquets simules places dans le PATH.
#
# CE QUE CE TEST NE PROUVE PAS
#
# Qu'une installation reelle aboutit sur Fedora ou sur Arch. Il verifie la
# couche d'adaptation — les noms de paquets, les chemins, les commandes
# choisies — pas le comportement de dnf ou de mkinitcpio, qui ne peuvent etre
# eprouves que sur la machine correspondante. C'est dit ici plutot que sous-
# entendu.
#
# sudo tests/test_portabilite.sh

set -u
. "$(dirname "$0")/lib.sh"

DEPOT="$(cd "$(dirname "$0")/.." && pwd)"

# La bibliotheque testee est celle du depot si l'on y est, celle du systeme
# sinon : le test doit valoir aussi bien avant qu'apres installation.
if [ -r "${DEPOT}/lib/blocker-os.sh" ]; then
    OS_LIB="${DEPOT}/lib/blocker-os.sh"
    SOURCE_DEPOT=1
else
    OS_LIB=/usr/lib/blocker-adulte/blocker-os.sh
    SOURCE_DEPOT=0
fi

[ -r "${OS_LIB}" ] || { echo "blocker-os.sh introuvable." >&2; exit "${TEST_SKIP}"; }

BAC="$(mktemp -d)"
trap 'rm -rf "${BAC}"' EXIT

# ---------------------------------------------------------------------------
titre "1. Detection sur cette machine"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
( . "${OS_LIB}"; printf '%s\n%s\n%s\n%s\n' \
    "${BLOCKER_FAMILY}" "${BLOCKER_PKGMGR}" "${BLOCKER_INITRAMFS}" "${BLOCKER_OS_NAME}" ) \
    > "${BAC}/ici"

famille="$(sed -n 1p "${BAC}/ici")"
pkgmgr="$(sed -n 2p "${BAC}/ici")"
initrd="$(sed -n 3p "${BAC}/ici")"
nom="$(sed -n 4p "${BAC}/ici")"

info "systeme : ${nom:-inconnu}"
[ -n "${famille}" ] && ok "famille detectee : ${famille}" || ko "famille non detectee"
[ -n "${pkgmgr}" ]  && ok "gestionnaire de paquets : ${pkgmgr}" || ko "gestionnaire non detecte"
[ -n "${initrd}" ]  && ok "generateur d initramfs : ${initrd}" || ko "generateur non detecte"

if [ "${pkgmgr}" = "aucun" ]; then
    warn "aucun gestionnaire de paquets : les controles qui en dependent seront ignores"
fi

# ---------------------------------------------------------------------------
titre "2. Detection rejouee avec l identite d autres distributions"
# ---------------------------------------------------------------------------

# Chaque cas : identifiant | ID_LIKE | commandes simulees | famille attendue |
#              gestionnaire attendu | initramfs attendu
CAS="
ubuntu|debian|apt-get update-initramfs|debian|apt|initramfs-tools
debian||apt-get update-initramfs|debian|apt|initramfs-tools
linuxmint|ubuntu debian|apt-get update-initramfs|debian|apt|initramfs-tools
fedora||dnf dracut|rhel|dnf|dracut
rhel|fedora|dnf dracut|rhel|dnf|dracut
rocky|rhel centos fedora|dnf dracut|rhel|dnf|dracut
arch||pacman mkinitcpio|arch|pacman|mkinitcpio
manjaro|arch|pacman mkinitcpio|arch|pacman|mkinitcpio
opensuse-tumbleweed|opensuse suse|zypper dracut|suse|zypper|dracut
alpine||apk|alpine|apk|aucun
voidlinux||apk|inconnue|apk|aucun
"

# Le PATH de la simulation ne contient QUE ce qu'on y met : sinon le dnf ou le
# pacman de la machine hote serait trouve et fausserait la detection. Les
# utilitaires dont blocker-os.sh a besoin y sont donc places explicitement.
OUTILS="sed head awk cut grep tr sort cat mkdir"

simuler() {
    local id="$1" like="$2" cmds="$3" bac c o chemin
    bac="$(mktemp -d "${BAC}/sim.XXXXXX")"
    mkdir -p "${bac}/bin"
    for o in ${OUTILS}; do
        chemin="$(command -v "${o}" 2>/dev/null)" || continue
        ln -sf "${chemin}" "${bac}/bin/${o}"
    done
    {
        printf 'ID=%s\n' "${id}"
        [ -n "${like}" ] && printf 'ID_LIKE="%s"\n' "${like}"
        printf 'PRETTY_NAME="Simulation %s"\n' "${id}"
    } > "${bac}/os-release"
    for c in ${cmds}; do
        printf '#!/bin/sh\nexit 0\n' > "${bac}/bin/${c}"
        chmod +x "${bac}/bin/${c}"
    done
    # PATH réduit aux commandes simulees + les binaires de base : sans cela, le
    # dnf ou le pacman de la machine hote fausserait la detection.
    (
        PATH="${bac}/bin"
        export PATH
        BLOCKER_OS_RELEASE="${bac}/os-release"
        BLOCKER_INITRAMFS_DIR="${bac}/initramfs-tools-absent"
        [ -x "${bac}/bin/update-initramfs" ] && \
            { mkdir -p "${bac}/initramfs-tools"; BLOCKER_INITRAMFS_DIR="${bac}/initramfs-tools"; }
        export BLOCKER_OS_RELEASE BLOCKER_INITRAMFS_DIR
        # shellcheck disable=SC1090
        . "${OS_LIB}"
        printf '%s|%s|%s\n' "${BLOCKER_FAMILY}" "${BLOCKER_PKGMGR}" "${BLOCKER_INITRAMFS}"
    )
}

while IFS='|' read -r id like cmds att_fam att_pkg att_ird; do
    [ -n "${id}" ] || continue
    obtenu="$(simuler "${id}" "${like}" "${cmds}")"
    attendu="${att_fam}|${att_pkg}|${att_ird}"
    if [ "${obtenu}" = "${attendu}" ]; then
        ok "${id} -> ${obtenu}"
    else
        ko "${id} -> ${obtenu}, attendu ${attendu}"
    fi
done <<EOF
$(printf '%s\n' "${CAS}")
EOF

# ---------------------------------------------------------------------------
titre "3. Chaque role a un nom de paquet dans chaque famille"
# ---------------------------------------------------------------------------
# Sans ce controle, l'ajout d'une famille sans mettre a jour la table des noms
# passerait inapercu jusqu'a la premiere installation reelle.
ROLES="dnsmasq nftables auditd curl dig chattr"
manque=0
for fam in debian rhel arch suse alpine; do
    liste=""
    for role in ${ROLES}; do
        # shellcheck disable=SC1090
        nomp="$( . "${OS_LIB}"; BLOCKER_FAMILY="${fam}"; blocker_pkg_candidats "${role}" | awk '{print $1}' )"
        if [ -z "${nomp}" ]; then
            ko "${fam} : aucun paquet pour le role « ${role} »"
            manque=$((manque + 1))
        fi
        liste="${liste} ${nomp}"
    done
    [ "${manque}" -eq 0 ] && ok "${fam} :${liste}"
done

# « resolved » et « initramfs » ont le droit d'etre vides : le premier fait
# partie de systemd sur Arch, le second n'a pas de paquet quand aucun
# generateur n'est present.
info "roles « resolved » et « initramfs » : une reponse vide est valable"

# ---------------------------------------------------------------------------
titre "4. Aucune commande propre a une distribution hors de la couche prevue"
# ---------------------------------------------------------------------------
# C'est le vrai garde-fou de regression : rien n'empeche, dans six mois, de
# retaper « apt-get install » au milieu d'un script. Ce controle le voit.
#
# Deux fichiers ont le droit de les contenir : lib/blocker-os.sh, qui EST la
# couche d'adaptation, et blocker-uninstall.sh, qui doit rester autonome apres
# que la phase 3 a supprime /usr/lib/blocker-adulte. bin/blocker-configure a le
# droit de nommer mkinitcpio : il traite le cas particulier de HOOKS.
if [ "${SOURCE_DEPOT}" -eq 0 ]; then
    warn "depot source absent : controle statique ignore"
else
    MOTIFS='apt-get|dpkg-query|adduser |deluser |delgroup |update-initramfs'
    trouve=0
    for f in "${DEPOT}"/install.sh "${DEPOT}"/bin/* "${DEPOT}"/lib/*.sh; do
        [ -f "${f}" ] || continue
        case "${f}" in
            */blocker-os.sh|*/blocker-uninstall.sh) continue ;;
        esac
        # Les commentaires ne comptent pas : ils expliquent souvent justement
        # pourquoi telle commande a ete abandonnee.
        lignes="$(grep -nE "${MOTIFS}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        if [ -n "${lignes}" ]; then
            ko "commande propre a Debian dans $(basename "${f}") :"
            printf '%s\n' "${lignes}" | sed 's/^/        /'
            trouve=$((trouve + 1))
        fi
    done
    [ "${trouve}" -eq 0 ] && ok "install.sh, bin/ et lib/ ne codent en dur aucune commande Debian"

    # L'inverse : blocker-os.sh doit bien couvrir les cinq gestionnaires.
    for g in apt dnf yum pacman zypper apk; do
        if grep -q "        ${g})" "${DEPOT}/lib/blocker-os.sh" || \
           grep -q "^        ${g}|" "${DEPOT}/lib/blocker-os.sh" || \
           grep -q "${g})" "${DEPOT}/lib/blocker-os.sh"; then
            ok "blocker-os.sh traite ${g}"
        else
            ko "blocker-os.sh ne traite pas ${g}"
        fi
    done
fi

# ---------------------------------------------------------------------------
titre "5. Le desinstalleur connait les memes familles que la couche"
# ---------------------------------------------------------------------------
# blocker-uninstall.sh refait la detection chez lui, volontairement. La
# duplication est justifiee, mais elle doit rester synchronisee : une famille
# ajoutee d'un cote et oubliee de l'autre donnerait un desinstalleur qui ne
# sait pas quelle commande de purge proposer.
UNINST="${DEPOT}/blocker-uninstall.sh"
[ -r "${UNINST}" ] || UNINST=/usr/sbin/blocker-uninstall
if [ -r "${UNINST}" ]; then
    ecart=0
    for fam in debian rhel arch suse alpine; do
        if grep -q "printf '${fam}" "${UNINST}"; then
            ok "desinstalleur : famille ${fam} reconnue"
        else
            ko "desinstalleur : famille ${fam} absente"
            ecart=$((ecart + 1))
        fi
    done
    for g in apt-get dnf pacman zypper apk; do
        grep -q "command -v ${g}" "${UNINST}" || \
            ko "desinstalleur : ${g} absent des commandes de retrait"
    done
    [ "${ecart}" -eq 0 ] && ok "aucune famille oubliee cote desinstalleur"
else
    warn "blocker-uninstall introuvable, controle ignore"
fi

# ---------------------------------------------------------------------------
titre "6. Les trois generateurs d initramfs sont livres au complet"
# ---------------------------------------------------------------------------
# Chaque generateur a besoin de deux fichiers : celui qui construit l'image et
# celui qui s'execute au demarrage. Un seul des deux ne sert a rien.
# Le depot fait foi quand on y est : c'est lui qui doit contenir les fichiers,
# l'installation n'en est que la copie.
if [ -d "${DEPOT}/initramfs-hook" ]; then
    RACINE_IRD="${DEPOT}"
elif [ -d /usr/share/blocker-adulte/initramfs ]; then
    RACINE_IRD=/usr/share/blocker-adulte/initramfs
else
    RACINE_IRD=""
fi

if [ -z "${RACINE_IRD}" ]; then
    warn "fichiers initramfs introuvables, controle ignore"
elif [ "${RACINE_IRD}" = "${DEPOT}" ]; then
    for f in initramfs-hook/blocker-adulte-hook \
             initramfs-hook/blocker-adulte-init-bottom \
             initramfs-hook/blocker-load-rules \
             dracut/module-setup.sh \
             dracut/blocker-adulte-prepivot.sh \
             mkinitcpio/blocker-adulte-install \
             mkinitcpio/blocker-adulte-hook \
             bin/blocker-base-rules; do
        [ -f "${DEPOT}/${f}" ] && ok "present : ${f}" || ko "absent du depot : ${f}"
    done
else
    for f in blocker-adulte-hook blocker-adulte-init-bottom blocker-load-rules \
             dracut-module-setup.sh dracut-blocker-adulte-prepivot.sh \
             mkinitcpio-blocker-adulte-install mkinitcpio-blocker-adulte-hook; do
        [ -f "${RACINE_IRD}/${f}" ] && ok "installe : ${f}" || ko "non installe : ${f}"
    done
    [ -x /usr/lib/blocker-adulte/blocker-base-rules ] \
        && ok "installe : blocker-base-rules" \
        || ko "non installe : blocker-base-rules"
fi

# Les deux points d'entree sources par leur init (dracut, mkinitcpio) ne
# doivent contenir aucun « exit » : il arreterait l'init du systeme et rendrait
# la machine non demarrable. C'est le defaut le plus grave possible ici.
for f in "${DEPOT}/dracut/blocker-adulte-prepivot.sh" \
         "${DEPOT}/mkinitcpio/blocker-adulte-hook"; do
    [ -r "${f}" ] || continue
    if grep -qE '^[[:space:]]*exit\b' "${f}"; then
        ko "$(basename "${f}") contient « exit » : il est SOURCE par l init, la machine ne demarrerait plus"
    else
        ok "$(basename "${f}") ne contient aucun « exit » (il est source par l init)"
    fi
done

bilan
