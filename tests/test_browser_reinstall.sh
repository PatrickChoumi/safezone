#!/bin/bash
# blocker-adulte — test : la policy survit a une reinstallation de navigateur
#
# Critere d'acceptation n°2 : apres « apt reinstall firefox », la policy DoH
# doit etre de nouveau appliquee sans intervention manuelle.
#
# Deux modes :
#   - par defaut : on SIMULE la disparition de la policy (suppression du
#     fichier) et on verifie que les mecanismes de reapplication la remettent.
#     Aucun paquet n'est touche, le test est sans risque.
#   - avec --reinstall-reel : on lance vraiment « apt reinstall » sur les
#     navigateurs installes en .deb, ce qui exerce le trigger dpkg lui-meme.
#
# sudo tests/test_browser_reinstall.sh [--reinstall-reel]

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

REEL=0
[ "${1:-}" = "--reinstall-reel" ] && REEL=1

POLICIES="
/etc/firefox/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json
"

# Un navigateur est-il reellement installe ? Cette question decide du mode du
# test. On ne peut pas la deduire de la presence des fichiers de policy : un
# deploiement force anterieur (--all) en aurait laisse, sans navigateur derriere.
un_navigateur_installe() {
    for c in firefox google-chrome google-chrome-stable chromium chromium-browser brave-browser; do
        command -v "$c" >/dev/null 2>&1 && return 0
    done
    for d in /usr/lib/firefox /snap/firefox /opt/firefox /opt/google/chrome \
             /usr/lib/chromium /usr/lib/chromium-browser /snap/chromium \
             /opt/brave.com/brave; do
        [ -d "$d" ] && return 0
    done
    return 1
}

titre "1. Etat initial des policies"

presentes=""
for f in ${POLICIES}; do
    if [ -s "${f}" ]; then
        ok "policy en place : ${f}"
        presentes="${presentes} ${f}"
    else
        info "(absent, navigateur non installe) ${f}"
    fi
done

# Sur une machine sans navigateur, blocker-apply-policies ne deploie rien : il
# n'y a rien a proteger. On peut malgre tout exercer toute la mecanique en mode
# force. Il faut alors etre coherent de bout en bout : forcer la creation puis
# attendre une restauration par un mecanisme non force testerait une chose qui
# n'a jamais ete promise, et echouerait a tort.
MODE_FORCE=0

if un_navigateur_installe; then
    ok "au moins un navigateur est installe : test en conditions reelles"
else
    warn "aucun navigateur installe sur cette machine."
    info "Le test bascule en mode force (--all) de bout en bout : il valide la"
    info "mecanique de redeploiement, pas la detection de navigateur."
    MODE_FORCE=1
fi

if [ -z "${presentes}" ]; then
    /usr/lib/blocker-adulte/blocker-apply-policies --all >/dev/null 2>&1 || true
    for f in ${POLICIES}; do
        [ -s "${f}" ] && presentes="${presentes} ${f}"
    done
    if [ -z "${presentes}" ]; then
        printf 'Impossible de deployer la moindre policy. Test ignore.\n' >&2
        exit "${TEST_SKIP}"
    fi
fi

# Rejoue le mecanisme de reapplication, avec ou sans forcage selon le contexte.
reappliquer() {
    if [ "${MODE_FORCE}" -eq 1 ]; then
        /usr/lib/blocker-adulte/blocker-apply-policies --all >/dev/null 2>&1
    else
        systemctl start blocker-selfheal.service >/dev/null 2>&1 || \
            /usr/lib/blocker-adulte/blocker-selfheal >/dev/null 2>&1
    fi
    return 0
}

titre "2. Reaction a la reinstallation d un navigateur (composant 5)"

# Deux mecanismes complementaires. Le hook du gestionnaire de paquets n'existe
# que la ou la distribution en offre un par simple depot de fichier — dpkg et
# pacman. L'unite « path » systemd, elle, existe partout et couvre en plus les
# navigateurs installes par snap ou flatpak, que le gestionnaire de paquets ne
# voit pas. Au moins l'un des deux doit etre en place.
# shellcheck disable=SC1091
. /usr/lib/blocker-adulte/blocker-common.sh

mecanismes=0

case "${BLOCKER_PKGMGR}" in
    apt)
        if command -v dpkg-query >/dev/null 2>&1 && \
           dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
            if [ -r /var/lib/dpkg/triggers/File ] && \
               grep -q 'blocker-adulte' /var/lib/dpkg/triggers/File 2>/dev/null; then
                ok "les triggers de fichier sont enregistres aupres de dpkg"
                info "$(grep -c 'blocker-adulte' /var/lib/dpkg/triggers/File) chemin(s) surveille(s)"
                mecanismes=$((mecanismes + 1))
            else
                ko "aucun trigger blocker-adulte enregistre dans /var/lib/dpkg/triggers/File"
            fi
        else
            info "paquet .deb non installe (installation via install.sh) :"
            info "les triggers dpkg ne s appliquent pas."
        fi ;;
    pacman)
        if [ -e /etc/pacman.d/hooks/95-blocker-adulte.hook ]; then
            ok "le hook pacman est en place"
            mecanismes=$((mecanismes + 1))
        else
            ko "hook pacman absent : /etc/pacman.d/hooks/95-blocker-adulte.hook"
        fi ;;
    *)
        info "${BLOCKER_PKGMGR} n offre pas de hook par depot de fichier ;"
        info "l unite path systemd est le seul mecanisme, et elle suffit." ;;
esac

if systemctl is-active --quiet blocker-policies.path 2>/dev/null; then
    ok "blocker-policies.path surveille les repertoires de policies"
    mecanismes=$((mecanismes + 1))
elif [ -d /run/systemd/system ]; then
    ko "blocker-policies.path n est pas actif"
    info "l armer : sudo systemctl enable --now blocker-policies.path"
else
    warn "systemd absent, unite path non verifiable"
fi

if [ "${mecanismes}" -eq 0 ]; then
    ko "aucun mecanisme de reaction immediate : seul le self-heal repassera (5 min)"
else
    ok "${mecanismes} mecanisme(s) de reaction immediate en place"
fi

titre "3. Suppression d'une policy, puis reapplication automatique"

cible="$(printf '%s' "${presentes}" | awk '{print $1}')"
info "cible du test : ${cible}"

empreinte_avant="$(sha256sum "${cible}" | awk '{print $1}')"

chattr -i "${cible}" 2>/dev/null || true
rm -f "${cible}"

if [ -e "${cible}" ]; then
    ko "impossible de supprimer la policy pour le test"
    bilan; exit 1
fi
ok "policy supprimee (simulation d'une reinstallation de navigateur)"

# Le composant 7 (self-heal) repasse toutes les 5 minutes, mais on peut
# declencher la meme passe tout de suite : c'est exactement ce que fera le
# timer, sans attendre.
if [ "${MODE_FORCE}" -eq 1 ]; then
    info "reapplication via blocker-apply-policies --all (mode force)"
else
    info "declenchement d'une passe de self-heal (equivaut a attendre 5 minutes)"
fi
reappliquer

sleep 2

if [ -s "${cible}" ]; then
    ok "policy reappliquee automatiquement"
    empreinte_apres="$(sha256sum "${cible}" | awk '{print $1}')"
    if [ "${empreinte_avant}" = "${empreinte_apres}" ]; then
        ok "le contenu restaure est identique a l'original"
    else
        ko "le contenu restaure differe de l'original"
    fi
else
    ko "policy toujours absente apres la passe de self-heal"
    info "journalctl -u blocker-selfheal -n 30"
fi

titre "4. La reapplication est journalisee"

# Le mot-cle suit la langue dans laquelle le service tournait quand il a ecrit
# la ligne, qui n'est pas forcement celle d'aujourd'hui : on cherche les deux.
if journalctl -u blocker-selfheal.service -n 50 --no-pager 2>/dev/null \
   | grep -qE 'REPARATION|REPAIR'; then
    ok "la reparation apparait dans le journal"
else
    warn "aucune ligne « REPARATION » / « REPAIR » recente (le script a pu etre lance hors systemd)"
fi

titre "5. Le trigger dpkg fonctionne aussi via blocker-apply-policies"

# Meme chemin de code que celui appele par le postinst en mode « triggered ».
chattr -i "${cible}" 2>/dev/null || true
rm -f "${cible}"
if [ "${MODE_FORCE}" -eq 1 ]; then
    /usr/lib/blocker-adulte/blocker-apply-policies --all >/dev/null 2>&1 || true
else
    /usr/lib/blocker-adulte/blocker-apply-policies >/dev/null 2>&1 || true
fi

if [ -s "${cible}" ]; then
    ok "blocker-apply-policies (chemin du trigger dpkg) remet la policy"
else
    ko "blocker-apply-policies n'a pas remis la policy"
fi

if [ "${REEL}" -eq 1 ]; then
    titre "6. Reinstallation reelle d'un navigateur (--reinstall-reel)"

    reinstalle=0
    for pkg in firefox firefox-esr chromium chromium-browser google-chrome-stable brave-browser; do
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
            info "apt reinstall ${pkg} (cela peut prendre un moment)"
            if DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "${pkg}" >/dev/null 2>&1; then
                ok "${pkg} reinstalle"
                reinstalle=1
                sleep 3
                for f in ${POLICIES}; do
                    if [ -s "${f}" ]; then
                        ok "policy toujours en place apres reinstallation : ${f}"
                    fi
                done
            else
                warn "la reinstallation de ${pkg} a echoue (reseau ?)"
            fi
        fi
    done

    if [ "${reinstalle}" -eq 0 ]; then
        warn "aucun navigateur installe en .deb : rien a reinstaller."
        info "Sur Ubuntu 22.04+, Firefox et Chromium sont des snaps et ne passent"
        info "pas par dpkg — c'est blocker-selfheal.timer qui les couvre."
    fi
else
    titre "6. Reinstallation reelle"
    info "ignoree. Pour l'executer : sudo $0 --reinstall-reel"
fi

bilan
