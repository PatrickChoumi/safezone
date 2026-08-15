#!/bin/bash
# blocker-adulte — test : aucune fuite DNS hors du resolveur local
#
# Verifie que le DNS ne peut pas sortir de la machine autrement que par le
# resolveur local, quelle que soit la facon dont on essaie :
#   - resolution systeme normale ;
#   - interrogation directe d'un resolveur public (doit etre redirigee) ;
#   - configuration explicite d'un serveur DNS tiers.
#
# sudo tests/test_dns_leak.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

exiger_root
exiger_installe
exiger_commande dig "dnsutils"

titre "1. Le resolveur local repond"

if dig +short +time=3 +tries=1 @127.0.0.1 example.com >/dev/null 2>&1; then
    ok "127.0.0.1:53 repond aux requetes"
else
    ko "127.0.0.1:53 ne repond pas — blocker-resolver.service tourne-t-il ?"
    info "journalctl -u blocker-resolver -n 30"
fi

verifier "blocker-resolver.service est actif" \
    systemctl is-active --quiet blocker-resolver.service

titre "2. systemd-resolved pointe bien sur le resolveur local"

if command -v resolvectl >/dev/null 2>&1; then
    if resolvectl status 2>/dev/null | grep -q '127\.0\.0\.1'; then
        ok "resolvectl status mentionne 127.0.0.1"
    else
        ko "resolvectl status ne mentionne pas 127.0.0.1"
        info "verifier /etc/systemd/resolved.conf.d/blocker-adulte.conf"
    fi

    if resolvectl status 2>/dev/null | grep -qi 'Default Route.*yes\|~\.'; then
        ok "la route de recherche « ~. » est en place"
    else
        warn "route « ~. » non detectee dans resolvectl status (sortie variable selon la version)"
    fi
else
    warn "resolvectl absent, controle ignore"
fi

titre "3. Une requete vers un resolveur public est redirigee"

# Le point cle : la reponse doit venir du resolveur LOCAL, pas de 8.8.8.8.
# dnsmasq et un resolveur public ne se comportent pas pareil sur une requete
# CHAOS version.bind, ce qui permet de savoir qui a repondu.
sortie="$(dig +time=3 +tries=1 @8.8.8.8 example.com 2>&1 || true)"

if printf '%s' "${sortie}" | grep -q 'SERVER: 8\.8\.8\.8'; then
    # dig affiche l'adresse visee, pas celle qui a repondu : on regarde plutot
    # si la reponse porte la signature de dnsmasq.
    version_locale="$(dig +short +time=3 @127.0.0.1 chaos txt version.bind 2>/dev/null || true)"
    version_pub="$(dig +short +time=3 @8.8.8.8 chaos txt version.bind 2>/dev/null || true)"

    if [ -n "${version_locale}" ] && [ "${version_locale}" = "${version_pub}" ]; then
        ok "la requete vers 8.8.8.8 est bien servie par le resolveur local (${version_locale})"
    elif printf '%s' "${version_pub}" | grep -qi 'dnsmasq'; then
        ok "la requete vers 8.8.8.8 est bien servie par dnsmasq local"
    else
        ko "la requete vers 8.8.8.8 semble sortir de la machine"
        info "reponse locale : ${version_locale:-vide} / via 8.8.8.8 : ${version_pub:-vide}"
        info "verifier : sudo nft list table ip blocker_adulte_nat"
    fi
else
    warn "8.8.8.8 n'a pas repondu du tout — soit la redirection fonctionne, soit la machine est hors ligne"
fi

titre "4. Les regles de redirection sont chargees"

verifier "table ip blocker_adulte_nat presente" \
    nft list table ip blocker_adulte_nat

if nft list table ip blocker_adulte_nat 2>/dev/null | grep -q 'dport 53'; then
    ok "la regle de redirection du port 53 est presente"
else
    ko "aucune regle sur le port 53 dans la table de redirection"
fi

titre "5. Un domaine de la liste de blocage est bien bloque"

# On teste avec un domaine de resolveur DoH present dans la liste de base,
# plutot qu'avec un domaine adulte : le test doit pouvoir tourner n'importe ou.
reponse="$(dig +short +time=3 +tries=1 @127.0.0.1 dns.google 2>/dev/null || true)"
if [ -z "${reponse}" ]; then
    ok "dns.google est bloque (NXDOMAIN, aucune adresse renvoyee)"
else
    ko "dns.google resout vers : ${reponse}"
    info "la liste de base /var/lib/blocker-adulte/blocklists/00-base.conf est-elle chargee ?"
fi

bilan
