#!/bin/bash
# blocker-adulte — test : les canaux DNS chiffres sont bloques
#
# Verifie que DoH, DoT et DoQ ne peuvent pas servir de porte de sortie :
#   - regles nftables presentes ;
#   - connexion TCP/853 refusee ;
#   - requete DoH vers un endpoint public en echec ;
#   - policies navigateur desactivant DoH bien deployees.
#
# sudo tests/test_doh_blocked.sh

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
exiger_commande nft "nftables"

titre "1. Regles nftables de blocage des canaux chiffres"

verifier "table inet blocker_adulte presente" nft list table inet blocker_adulte

regles="$(nft list table inet blocker_adulte 2>/dev/null || true)"

for motif in "dport 853" "784" "8853" "doh_ipv4" "doh_ipv6"; do
    if printf '%s' "${regles}" | grep -q -- "${motif}"; then
        ok "regle presente : ${motif}"
    else
        ko "regle absente : ${motif}"
    fi
done

titre "2. DNS-over-TLS (port 853) refuse"

# On vise Cloudflare, mais n'importe quel hote ferait l'affaire : le blocage
# porte sur le port, pas sur la destination.
if command -v timeout >/dev/null 2>&1; then
    if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/853' 2>/dev/null; then
        ko "la connexion TCP vers 1.1.1.1:853 a abouti — DoT n'est pas bloque"
        exec 3<&- 2>/dev/null || true
    else
        ok "connexion TCP vers 1.1.1.1:853 refusee"
    fi
else
    warn "commande timeout absente, controle ignore"
fi

titre "3. Requete DoH vers un endpoint public"

if command -v curl >/dev/null 2>&1; then
    # --resolve court-circuite le DNS : on teste bien le blocage IP, pas le
    # blocage de nom. Sinon un DNS qui bloque deja dns.google donnerait un
    # faux positif.
    if curl --silent --show-error --max-time 8 \
            --resolve 'dns.google:443:8.8.8.8' \
            --header 'accept: application/dns-json' \
            'https://dns.google/resolve?name=example.com&type=A' >/dev/null 2>&1; then
        ko "une requete DoH vers 8.8.8.8 a abouti"
        info "verifier le set doh_ipv4 : sudo nft list set inet blocker_adulte doh_ipv4"
    else
        ok "requete DoH vers 8.8.8.8 en echec"
    fi

    if curl --silent --show-error --max-time 8 \
            --resolve 'cloudflare-dns.com:443:1.1.1.1' \
            --header 'accept: application/dns-json' \
            'https://cloudflare-dns.com/dns-query?name=example.com&type=A' >/dev/null 2>&1; then
        ko "une requete DoH vers 1.1.1.1 a abouti"
    else
        ok "requete DoH vers 1.1.1.1 en echec"
    fi
else
    warn "curl absent, controle ignore"
fi

titre "4. Le resolveur local filtre les noms des endpoints DoH"

if command -v dig >/dev/null 2>&1; then
    for domaine in dns.google cloudflare-dns.com dns.quad9.net \
                   mozilla.cloudflare-dns.com dns.adguard.com; do
        verifier_bloque "${domaine}"
    done
else
    warn "dig absent, controle ignore"
fi

titre "5. Extensions proxy de navigateur bloquees"

# C'est le contournement le plus facile de tout le dispositif : installer une
# extension VPN/proxy ne demande aucun droit root et fait sortir tout le trafic
# du navigateur hors du resolveur local et de nftables.
verifier_antiproxy() {
    local fichier="$1" famille="$2"
    [ -s "${fichier}" ] || return 0
    case "${famille}" in
        firefox)
            # Firefox ne sait pas filtrer par permission : le seul levier fiable
            # est d'interdire l'installation de nouvelles extensions.
            if grep -q '"InstallAddonsPermission"' "${fichier}" && \
               grep -A3 '"InstallAddonsPermission"' "${fichier}" | grep -q '"Default": *false'; then
                ok "Firefox : installation de nouvelles extensions interdite"
            else
                ko "Firefox : une extension VPN/proxy reste installable (${fichier})"
            fi
            if grep -A4 '"Proxy"' "${fichier}" | grep -q '"Locked": *true'; then
                ok "Firefox : parametres proxy verrouilles"
            else
                ko "Firefox : parametres proxy non verrouilles"
            fi
            ;;
        *)
            if grep -q '"blocked_permissions"' "${fichier}" && \
               grep -A5 '"blocked_permissions"' "${fichier}" | grep -q '"proxy"'; then
                ok "${famille} : permission « proxy » refusee aux extensions"
            else
                ko "${famille} : une extension proxy reste installable (${fichier})"
            fi
            if grep -q '"ProxyMode": *"system"' "${fichier}"; then
                ok "${famille} : mode proxy impose par policy"
            else
                ko "${famille} : mode proxy non impose"
            fi
            ;;
    esac
}

verifier_antiproxy /etc/firefox/policies/policies.json firefox
verifier_antiproxy /etc/opt/chrome/policies/managed/blocker-adulte.json chrome
verifier_antiproxy /etc/chromium/policies/managed/blocker-adulte.json chromium
verifier_antiproxy /etc/brave/policies/managed/blocker-adulte.json brave

titre "6. Les enregistrements HTTPS/SVCB (type 65) sont filtres"

# Ces enregistrements annoncent aux navigateurs les endpoints DoH disponibles :
# les laisser passer permettrait une bascule automatique vers DoH.
if grep -q '^filter-rr=65' /etc/dnsmasq.d/blocker-adulte.conf 2>/dev/null; then
    ok "filter-rr=65 present dans la configuration du resolveur"
else
    ko "filter-rr=65 absent de /etc/dnsmasq.d/blocker-adulte.conf"
fi

titre "7. Policies navigateur : DoH desactive"

trouve=0
for f in /etc/firefox/policies/policies.json \
         /etc/opt/chrome/policies/managed/blocker-adulte.json \
         /etc/chromium/policies/managed/blocker-adulte.json \
         /etc/opt/chromium/policies/managed/blocker-adulte.json \
         /etc/brave/policies/managed/blocker-adulte.json; do
    [ -s "${f}" ] || continue
    trouve=$((trouve + 1))
    case "${f}" in
        */firefox/*)
            if grep -q '"DNSOverHTTPS"' "${f}" && grep -q '"Locked": *true' "${f}"; then
                ok "Firefox : DoH desactive et verrouille (${f})"
            else
                ko "Firefox : policy DoH incomplete (${f})"
            fi
            ;;
        *)
            if grep -q '"DnsOverHttpsMode": *"off"' "${f}"; then
                ok "Chromium/Chrome/Brave : DnsOverHttpsMode=off (${f})"
            else
                ko "policy DoH incomplete (${f})"
            fi
            ;;
    esac
done

if [ "${trouve}" -eq 0 ]; then
    warn "aucune policy navigateur deployee — aucun navigateur detecte sur cette machine ?"
    info "forcer le deploiement : sudo /usr/lib/blocker-adulte/blocker-apply-policies --all"
fi

bilan
