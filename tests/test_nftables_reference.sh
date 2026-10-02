#!/bin/bash
# blocker-adulte — test : le controle nftables voit vraiment les ecarts
#
# Le controle se contentait de chercher « dport 53 » et « dport 853 » dans deux
# tables. Il compare desormais le jeu de regles actif, table par table, a une
# reference chargee dans un espace reseau jetable.
#
# Tout ce test se deroule lui-meme dans un espace reseau jetable
# (« unshare -n ») : les regles reelles de la machine ne sont jamais touchees.
#   1. dans un espace vide, le controle signale l'absence des regles ;
#   2. apres chargement, le controle est conforme ;
#   3. une regle retiree d'une chaine est detectee — l'ancien controle ne
#      l'aurait pas vue ;
#   4. un element retire d'un jeu d'adresses est detecte ;
#   5. une regle NAT d'une autre table sur le port 53 est signalee ;
#   6. le rechargement remet le jeu en conformite.
#
# sudo tests/test_nftables_reference.sh

set -u
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe
exiger_commande nft "nftables"
exiger_commande unshare "util-linux"

APPLY=/usr/lib/blocker-adulte/blocker-apply-nftables
if ! unshare -n true 2>/dev/null; then
    printf 'Espaces reseau jetables indisponibles ici (conteneur sans droits ?). Test ignore.\n' >&2
    exit "${TEST_SKIP}"
fi

# Le scenario complet tourne dans UN espace reseau jetable : chaque etape voit
# l'etat laisse par la precedente. Il ecrit ses verdicts, une ligne par
# controle, que l'on reprend ensuite ici.
VERDICTS="$(mktemp)"
trap 'rm -f "${VERDICTS}"' EXIT

unshare -n bash -c '
    APPLY="$1"
    v() { printf "%s|%s\n" "$1" "$2"; }

    if "${APPLY}" --check >/dev/null 2>&1; then v ko "espace vide declare conforme"
    else v ok "espace vide : regles signalees absentes"; fi

    if "${APPLY}" --force >/dev/null 2>&1 && "${APPLY}" --check >/dev/null 2>&1; then
        v ok "apres chargement : conforme a la reference"
    else
        v ko "apres chargement : toujours non conforme"
    fi

    # Une regle retiree : l exemption du resolveur vers ses amonts.
    h="$(nft -a list chain ip blocker_adulte_nat output 2>/dev/null | sed -n "s/.*@amonts.*# handle \([0-9]*\)$/\1/p" | head -1)"
    if [ -n "${h}" ] && nft delete rule ip blocker_adulte_nat output handle "${h}" 2>/dev/null; then
        if "${APPLY}" --check >/dev/null 2>&1; then v ko "regle retiree non detectee"
        else v ok "regle retiree d une chaine : detectee"; fi
    else
        v warn "impossible de retirer la regle de test"
    fi
    "${APPLY}" --force >/dev/null 2>&1

    # Un element retire d un jeu d adresses.
    if nft delete element inet blocker_adulte doh_ipv4 "{ 8.8.8.8 }" 2>/dev/null; then
        if "${APPLY}" --check >/dev/null 2>&1; then v ko "element retire du jeu DoH non detecte"
        else v ok "element retire du jeu DoH : detecte"; fi
    else
        v warn "impossible de retirer l element de test"
    fi

    # Une table nat etrangere qui reecrit le port 53.
    nft -f - >/dev/null 2>&1 <<EOF
table ip test_etranger {
    chain sortie {
        type nat hook output priority -150; policy accept;
        udp dport 53 dnat to 192.0.2.53
    }
}
EOF
    if "${APPLY}" --etrangeres >/dev/null 2>&1; then v ko "regle NAT etrangere sur le port 53 non signalee"
    else v ok "regle NAT etrangere sur le port 53 : signalee"; fi
    nft delete table ip test_etranger 2>/dev/null

    if "${APPLY}" >/dev/null 2>&1 && "${APPLY}" --check >/dev/null 2>&1; then
        v ok "rechargement : de nouveau conforme"
    else
        v ko "rechargement : toujours non conforme"
    fi
' _ "${APPLY}" > "${VERDICTS}" 2>/dev/null

titre "Controle complet du jeu de regles (espace reseau jetable)"
while IFS='|' read -r verdict texte; do
    case "${verdict}" in
        ok)   ok "${texte}" ;;
        warn) warn "${texte}" ;;
        *)    ko "${texte}" ;;
    esac
done < "${VERDICTS}"
[ -s "${VERDICTS}" ] || ko "le scenario n a produit aucun verdict"

bilan
