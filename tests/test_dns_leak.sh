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
exiger_commande dig "bind9-dnsutils"

# Les valeurs de reference (amont, chemins) viennent de la bibliotheque du
# projet, pas de constantes recopiees ici qui divergeraient.
# shellcheck disable=SC1091
. /usr/lib/blocker-adulte/blocker-common.sh

titre "1. Le resolveur local repond"

# La sonde interroge un nom que le resolveur repond LUI-MEME, pris dans ses
# propres listes de blocage (« address=/domaine/# »). Interroger example.com
# imposerait un aller-retour vers l'amont : un reseau lent, ou un resolveur
# qui vient d'etre redemarre par un test precedent, faisait alors echouer le
# controle alors que dnsmasq repondait parfaitement — ce qu'on cherche a
# verifier ici, c'est que le port 53 local est bien servi, pas que l'amont
# est joignable (sections 3 et 6).
sonde_nom="$(cat "${BLOCKER_STATEDIR}"/blocklists/*.conf 2>/dev/null \
             | sed -n 's|^address=/\([^/]*\)/.*|\1|p' | head -1)"
if [ -z "${sonde_nom}" ]; then
    sonde_nom="example.com"
    info "aucune liste de blocage lisible : sonde sur ${sonde_nom} (aller-retour amont)"
fi

repond=0
for essai in 1 2 3; do
    if dig +short +time=3 +tries=1 @127.0.0.1 "${sonde_nom}" >/dev/null 2>&1; then
        repond=1
        [ "${essai}" -gt 1 ] && info "a repondu au ${essai}e essai"
        break
    fi
    sleep 1
done

if [ "${repond}" -eq 1 ]; then
    ok "127.0.0.1:53 repond aux requetes (sonde : ${sonde_nom})"
else
    ko "127.0.0.1:53 ne repond pas — blocker-resolver.service tourne-t-il ?"
    info "journalctl -u blocker-resolver -n 30"
fi

verifier_service blocker-resolver.service dnsmasq

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

titre "4. L amont DNS est reellement pilote par blocker.conf"

# L'amont etait autrefois ecrit en dur dans le modele dnsmasq, que le self-heal
# restaure a chaque passe : le reglage annonce dans blocker.conf n'avait donc
# aucun effet. On verifie que le fichier genere correspond bien a la config.
UPCONF=/var/lib/blocker-adulte/blocklists/01-upstream.conf
if [ -s "${UPCONF}" ]; then
    ok "fichier d amont genere present"
    if grep -q "^server=${BLOCKER_UPSTREAM_1}\$" "${UPCONF}"; then
        ok "amont applique = blocker.conf (${BLOCKER_UPSTREAM_1})"
    else
        ko "amont applique different de blocker.conf (${BLOCKER_UPSTREAM_1})"
        info "corriger : sudo /usr/lib/blocker-adulte/blocker-upstream"
    fi
else
    ko "aucun fichier d amont : dnsmasq n a pas de resolveur en secours"
    info "corriger : sudo /usr/lib/blocker-adulte/blocker-upstream"
fi

# Le modele ne doit plus contenir de server= en dur, sinon le reglage
# redeviendrait fige.
if grep -q '^server=' /etc/dnsmasq.d/blocker-adulte.conf 2>/dev/null; then
    ko "des « server= » sont revenus en dur dans le modele dnsmasq"
    info "ils rendraient BLOCKER_UPSTREAM_1 sans effet."
else
    ok "aucun « server= » code en dur dans le modele dnsmasq"
fi

titre "5. Les regles de redirection sont chargees"

verifier "table ip blocker_adulte_nat presente" \
    nft list table ip blocker_adulte_nat

if nft list table ip blocker_adulte_nat 2>/dev/null | grep -q 'dport 53'; then
    ok "la regle de redirection du port 53 est presente"
else
    ko "aucune regle sur le port 53 dans la table de redirection"
fi

titre "6. Un domaine de la liste de blocage est bien bloque"

# On teste avec des domaines de resolveur DoH presents dans la liste de base,
# plutot qu'avec des domaines adultes : le test doit pouvoir tourner n'importe
# ou, y compris sur une machine de travail partagee.
for domaine in dns.google cloudflare-dns.com nordvpn.com; do
    verifier_bloque "${domaine}" || \
        info "la liste /var/lib/blocker-adulte/blocklists/00-base.conf est-elle chargee ?"
done

bilan
