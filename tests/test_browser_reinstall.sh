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

set -uo pipefail
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

if [ -z "${presentes}" ]; then
    warn "aucune policy deployee : aucun navigateur detecte."
    info "Deploiement force pour pouvoir tester quand meme :"
    /usr/lib/blocker-adulte/blocker-apply-policies --all >/dev/null 2>&1 || true
    for f in ${POLICIES}; do
        [ -s "${f}" ] && presentes="${presentes} ${f}"
    done
    if [ -z "${presentes}" ]; then
        printf 'Impossible de deployer la moindre policy. Test ignore.\n' >&2
        exit "${TEST_SKIP}"
    fi
fi

titre "2. Les triggers dpkg sont bien enregistres"

if command -v dpkg-query >/dev/null 2>&1 && \
   dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
    if [ -r /var/lib/dpkg/triggers/File ] && \
       grep -q 'blocker-adulte' /var/lib/dpkg/triggers/File 2>/dev/null; then
        ok "les triggers de fichier sont enregistres aupres de dpkg"
        info "$(grep -c 'blocker-adulte' /var/lib/dpkg/triggers/File) chemin(s) surveille(s)"
    else
        ko "aucun trigger blocker-adulte enregistre dans /var/lib/dpkg/triggers/File"
    fi
else
    warn "paquet .deb non installe (installation via install.sh) :"
    info "les triggers dpkg du composant 5 sont donc inactifs ;"
    info "la reapplication repose sur blocker-selfheal.timer (composant 7)."
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
info "declenchement d'une passe de self-heal (equivaut a attendre 5 minutes)"
systemctl start blocker-selfheal.service >/dev/null 2>&1 || \
    /usr/lib/blocker-adulte/blocker-selfheal >/dev/null 2>&1 || true

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

if journalctl -u blocker-selfheal.service -n 50 --no-pager 2>/dev/null | grep -q 'REPARATION'; then
    ok "la reparation apparait dans le journal"
else
    warn "aucune ligne « REPARATION » recente (le script a pu etre lance hors systemd)"
fi

titre "5. Le trigger dpkg fonctionne aussi via blocker-apply-policies"

# Meme chemin de code que celui appele par le postinst en mode « triggered ».
chattr -i "${cible}" 2>/dev/null || true
rm -f "${cible}"
/usr/lib/blocker-adulte/blocker-apply-policies >/dev/null 2>&1 || true

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
