#!/bin/bash
# blocker-adulte — test : desinstallation en phases
#
# Verifie les deux moities de la promesse, qui se contredisent en apparence :
#
#   A. C'est PENIBLE. Aucune commande unique ne retire tout, l'ordre des phases
#      est impose, et il faut lire l'ecran a chaque phase pour obtenir son jeton.
#
#   B. Ce n'est PAS UN PIEGE. Les phases fonctionnent, la procedure manuelle
#      equivalente est affichable, et l'avancement se deduit de l'etat reel du
#      systeme — donc rien ne peut coincer la desinstallation a mi-chemin.
#
# Ce test ne desinstalle RIEN par defaut : il verifie les gardes sans les
# franchir. Avec --pour-de-vrai il execute les quatre phases et verifie qu'il ne
# reste aucun residu — a ne lancer que sur une machine jetable.
#
# sudo tests/test_uninstall_phases.sh [--pour-de-vrai]

set -u
. "$(dirname "$0")/lib.sh"

exiger_root

UNINST=/usr/sbin/blocker-uninstall
REEL=0
[ "${1:-}" = "--pour-de-vrai" ] && REEL=1

if [ ! -x "${UNINST}" ]; then
    printf '%s introuvable. Test ignore.\n' "${UNINST}" >&2
    exit "${TEST_SKIP}"
fi

titre "1. Aucune commande unique ne retire tout"

# L'ancienne interface doit etre refusee explicitement, pas ignoree en silence :
# quelqu'un qui la tape doit comprendre pourquoi elle ne marche plus.
sortie="$("${UNINST}" --confirm 2>&1)"
if printf '%s' "${sortie}" | grep -q "n'existe plus"; then
    ok "« --confirm » est refuse avec une explication"
else
    ko "« --confirm » n'est pas explicitement refuse"
fi

for arg in "--tout" "--force" "--yes" "-y"; do
    if "${UNINST}" "${arg}" >/dev/null 2>&1; then
        ko "« ${arg} » est accepte — raccourci vers une desinstallation complete"
    else
        ok "« ${arg} » est refuse"
    fi
done

titre "2. Une phase sans jeton n'execute rien"

avant_unites="$(systemctl is-enabled blocker-guard.service 2>/dev/null || echo inconnu)"
"${UNINST}" --phase 1 >/dev/null 2>&1
apres_unites="$(systemctl is-enabled blocker-guard.service 2>/dev/null || echo inconnu)"

if [ "${avant_unites}" = "${apres_unites}" ]; then
    ok "« --phase 1 » sans jeton laisse le systeme inchange"
else
    ko "« --phase 1 » sans jeton a modifie l'etat (${avant_unites} -> ${apres_unites})"
fi

titre "3. Le jeton est tire au hasard a chaque affichage"

j1="$("${UNINST}" --phase 1 2>/dev/null | grep -oE 'jeton [A-HJ-NP-Z2-9]{6}' | head -1 | awk '{print $2}')"
j2="$("${UNINST}" --phase 1 2>/dev/null | grep -oE 'jeton [A-HJ-NP-Z2-9]{6}' | head -1 | awk '{print $2}')"

if [ -n "${j1}" ] && [ -n "${j2}" ]; then
    ok "un jeton est bien delivre (${j1}, puis ${j2})"
    if [ "${j1}" != "${j2}" ]; then
        ok "le jeton change a chaque affichage : impossible a scripter d'avance"
    else
        ko "le jeton est stable — un script pourrait enchainer les phases"
    fi
else
    ko "aucun jeton delivre par « --phase 1 »"
fi

titre "4. Un jeton perime ou faux est refuse"

# j1 a ete remplace par j2 : il ne doit plus fonctionner.
if [ -n "${j1}" ] && [ "${j1}" != "${j2}" ]; then
    if "${UNINST}" --phase 1 --jeton "${j1}" 2>&1 | grep -q 'invalide ou expire'; then
        ok "un jeton perime est refuse"
    else
        ko "un jeton perime est accepte"
    fi
fi

if "${UNINST}" --phase 1 --jeton ZZZZZZ 2>&1 | grep -q 'invalide ou expire'; then
    ok "un jeton inconnu est refuse"
else
    ko "un jeton inconnu est accepte"
fi

titre "5. L'ordre des phases est impose"

for p in 2 3 4; do
    if "${UNINST}" --phase "${p}" 2>&1 | grep -q 'doit etre faite avant'; then
        ok "la phase ${p} refuse de passer avant les precedentes"
    else
        # Legitime si les phases anterieures sont deja faites sur cette machine.
        if "${UNINST}" --etat 2>/dev/null | grep -q "✔.*Phase $((p - 1))"; then
            warn "phase ${p} : les phases precedentes sont deja faites ici"
        else
            ko "la phase ${p} accepte de passer avant les precedentes"
        fi
    fi
done

titre "6. Ce n'est pas un piege"

if "${UNINST}" --manuel 2>&1 | grep -q 'Procedure manuelle'; then
    ok "la procedure manuelle equivalente est affichable"
else
    ko "aucune procedure manuelle affichable"
fi

for attendu in 'chattr -i' 'apt purge' 'update-initramfs' 'nft delete table' 'deluser'; do
    if "${UNINST}" --manuel 2>&1 | grep -qF "${attendu}"; then
        ok "la procedure manuelle couvre : ${attendu}"
    else
        ko "la procedure manuelle ne mentionne pas : ${attendu}"
    fi
done

if "${UNINST}" --etat 2>&1 | grep -qE 'Phase [1-4]'; then
    ok "« --etat » indique ou l'on en est"
else
    ko "« --etat » ne rend pas compte de l'avancement"
fi

titre "7. L'avancement ne depend d'aucun fichier compteur"

# Un compteur persistant serait un point de blocage : le supprimer ou rebooter
# au mauvais moment coincerait la desinstallation. L'etat doit etre deduit du
# systeme lui-meme.
if grep -qE '(uninstall\.state|uninstall-state|phase_courante)' "${UNINST}" 2>/dev/null; then
    ko "un fichier d'etat persistant est utilise pour suivre l'avancement"
else
    ok "aucun fichier compteur : l'avancement est deduit de l'etat du systeme"
fi

etat1="$("${UNINST}" --etat 2>&1)"
rm -rf /run/blocker-adulte/jetons 2>/dev/null
etat2="$("${UNINST}" --etat 2>&1)"
if [ "${etat1}" = "${etat2}" ]; then
    ok "supprimer les jetons ne change pas l'avancement constate"
else
    ko "l'avancement depend des fichiers de /run"
fi

# ---------------------------------------------------------------------------
if [ "${REEL}" -eq 0 ]; then
    titre "8. Desinstallation reelle"
    info "ignoree : ce test ne desinstalle rien par defaut."
    info "Pour l'executer sur une machine jetable :"
    info "  sudo $0 --pour-de-vrai"
    bilan
    exit $?
fi

titre "8. Desinstallation reelle des quatre phases"

for p in 1 2 3 4; do
    jeton="$("${UNINST}" --phase "${p}" 2>/dev/null \
             | grep -oE 'jeton [A-HJ-NP-Z2-9]{6}' | head -1 | awk '{print $2}')"
    if [ -z "${jeton}" ]; then
        if "${UNINST}" --etat 2>/dev/null | grep -q "✔.*Phase ${p}"; then
            ok "phase ${p} deja faite"
            continue
        fi
        ko "phase ${p} : aucun jeton delivre"
        break
    fi
    if "${UNINST}" --phase "${p}" --jeton "${jeton}" >/dev/null 2>&1; then
        ok "phase ${p} executee"
    else
        # La phase 4 renvoie non nul s'il reste des residus : on le verra apres.
        warn "phase ${p} : code de retour non nul"
    fi
done

titre "9. Aucun residu apres les quatre phases"

restes=0
while IFS= read -r chemin; do
    [ -n "${chemin}" ] || continue
    case "${chemin}" in
        *avant-blocker-adulte) continue ;;   # sauvegarde volontaire, documentee
    esac
    ko "residu : ${chemin}"
    restes=$((restes + 1))
done < <(find / -xdev \( -path /proc -o -path /sys -o -path /tmp -o -path /home \) -prune -o \
              -name '*blocker-adulte*' -print 2>/dev/null)

[ "${restes}" -eq 0 ] && ok "aucun fichier residuel"

if command -v nft >/dev/null 2>&1; then
    if nft list ruleset 2>/dev/null | grep -q blocker_adulte; then
        ko "des tables nftables blocker_adulte sont encore chargees"
    else
        ok "aucune table nftables residuelle"
    fi
fi

if getent passwd blocker-adulte >/dev/null 2>&1; then
    ko "l'utilisateur systeme blocker-adulte existe encore"
else
    ok "utilisateur systeme retire"
fi

if [ -n "$(ls /etc/systemd/system/*.target.wants/blocker-* 2>/dev/null)" ]; then
    ko "des liens d'activation systemd sont restes pendants"
else
    ok "aucun lien d'activation pendant"
fi

bilan
