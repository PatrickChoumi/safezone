#!/bin/bash
# blocker-adulte — test : rien n'est cache
#
# Criteres d'acceptation n°4 et n°6. C'est le test qui verifie la ligne rouge du
# projet : l'outil doit etre integralement decouvrable.
#
#   1. tout fichier trouve par « find / -name '*blocker-adulte*' » figure dans
#      le manifeste du README ;
#   2. inversement, chaque emplacement du manifeste existe bien (ou est
#      legitimement absent : navigateur non installe) ;
#   3. les processus du projet apparaissent sous leur vrai nom dans ps et lsof ;
#   4. l'entree dpkg est visible dans « dpkg -l » ;
#   5. aucun mecanisme de dissimulation : pas de LD_PRELOAD, pas de module noyau
#      maison, pas de montage masquant /proc ;
#   6. aucune copie de l'outil hors des emplacements documentes.
#
# sudo tests/test_no_hidden_files.sh

# Pas de « pipefail » ici, volontairement : ces tests enchainent des
# « commande | grep -q » de diagnostic. Sous pipefail, grep -q qui sort des la
# premiere correspondance fait recevoir un SIGPIPE au producteur (nft list,
# ps aux, journalctl...), et le pipeline renvoie 141 — le controle echouerait
# alors que la chose cherchee est bien la. Le code de production, lui, garde
# pipefail et capture ses sorties avant de les filtrer.
set -u
. "$(dirname "$0")/lib.sh"

exiger_root

# Le README installe fait foi ; a defaut, celui du depot.
README=""
for candidat in /usr/share/doc/blocker-adulte/README.md \
                "$(dirname "$0")/../README.md" \
                /usr/share/blocker-adulte/README.md; do
    if [ -r "${candidat}" ]; then README="${candidat}"; break; fi
done

if [ -z "${README}" ]; then
    printf 'README introuvable : impossible de verifier le manifeste. Test ignore.\n' >&2
    exit "${TEST_SKIP}"
fi

info "README de reference : ${README}"

MANIFESTE="$(mktemp)"
TROUVES="$(mktemp)"
trap 'rm -f "${MANIFESTE}" "${TROUVES}"' EXIT

# ---------------------------------------------------------------------------
titre "1. Extraction du manifeste du README"
# ---------------------------------------------------------------------------

# Le manifeste est le bloc delimite par les marqueurs MANIFEST-DEBUT /
# MANIFEST-FIN ; on ne garde que les lignes qui sont des chemins absolus.
awk '/MANIFEST-DEBUT/{prise=1; next} /MANIFEST-FIN/{prise=0} prise' "${README}" \
    | sed 's/[[:space:]]*#.*$//' \
    | grep -E '^/' \
    | sed 's/[[:space:]]*$//' \
    | sort -u > "${MANIFESTE}"

nb_manifeste="$(wc -l < "${MANIFESTE}")"

if [ "${nb_manifeste}" -eq 0 ]; then
    ko "aucun chemin extrait du manifeste — les marqueurs MANIFEST-DEBUT/FIN sont-ils presents ?"
    bilan; exit 1
fi
ok "${nb_manifeste} emplacements declares dans le manifeste du README"

# ---------------------------------------------------------------------------
titre "2. Tout ce que « find » trouve est declare"
# ---------------------------------------------------------------------------

# -xdev : on reste sur le systeme de fichiers racine, sans partir dans /proc,
# les snaps montes en boucle ou les disques externes.
#
# /tmp et /var/tmp sont ecartes : ce sont les zones de construction standard,
# ou « make install DESTDIR=... » et « dpkg-buildpackage » deposent des copies
# temporaires. Elles sont volatiles et ne constituent pas une installation.
# Cette exclusion est annoncee dans la sortie du test, pas silencieuse.
info "zones ecartees : /proc /sys /run/user /tmp /var/tmp (construction et volatiles)"

find / -xdev \
     \( -path /proc -o -path /sys -o -path /run/user \
        -o -path /tmp -o -path /var/tmp \) -prune -o \
     -name '*blocker-adulte*' -print 2>/dev/null | sort -u > "${TROUVES}"

nb_trouves="$(wc -l < "${TROUVES}")"
info "${nb_trouves} chemins trouves sur le disque"

if [ "${nb_trouves}" -eq 0 ]; then
    warn "aucun fichier trouve : blocker-adulte n'est pas installe sur cette machine."
    info "Le test ne peut verifier que la coherence du manifeste."
fi

# Distingue une installation d'un arbre qui n'en est pas une. Renvoie 0 et
# affiche la racine de l'arbre si le chemin en fait partie.
#
# Deux formes reconnues :
#   - depot source : un repertoire ancetre contient a la fois « Makefile » et
#     « debian/control ». La disposition du depot differe volontairement de
#     celle de l'installation (etc/brave-policies/ -> /etc/brave/policies/...),
#     une comparaison de chemins ne suffit donc pas.
#   - arbre de construction (DESTDIR) : le chemin se termine par un emplacement
#     declare, precede d'un prefixe non vide.
arbre_non_installe() {
    local chemin="$1" ancetre declare_

    ancetre="$(dirname "${chemin}")"
    while [ "${ancetre}" != "/" ] && [ -n "${ancetre}" ]; do
        if [ -f "${ancetre}/Makefile" ] && [ -f "${ancetre}/debian/control" ]; then
            printf '%s (depot source)' "${ancetre}"
            return 0
        fi
        ancetre="$(dirname "${ancetre}")"
    done

    while IFS= read -r declare_; do
        case "${chemin}" in
            */"${declare_#/}")
                printf '%s (arbre de construction)' "${chemin%"${declare_}"}"
                return 0
                ;;
        esac
    done < "${MANIFESTE}"

    return 1
}

non_declares=0
construction=0
while IFS= read -r chemin; do
    [ -n "${chemin}" ] || continue

    # 1. Chemin exactement declare.
    grep -qxF "${chemin}" "${MANIFESTE}" && continue

    # 2. Chemin situe SOUS un repertoire declare (le manifeste liste les
    #    repertoires, pas chacun de leurs fichiers).
    couvert=0
    while IFS= read -r declare_; do
        case "${chemin}" in
            "${declare_}"/*) couvert=1; break ;;
        esac
    done < "${MANIFESTE}"
    [ "${couvert}" -eq 1 ] && continue

    # 3. Repertoire ANCETRE d'un emplacement declare : « find » remonte aussi
    #    les repertoires, et /usr/lib/blocker-adulte est le parent legitime des
    #    huit executables declares un a un.
    if [ -d "${chemin}" ] && grep -q "^${chemin}/" "${MANIFESTE}"; then
        continue
    fi

    # 4. Fichiers generes par le systeme a partir de ce que nous installons.
    case "${chemin}" in
        /var/lib/systemd/*|/run/systemd/*|/var/log/*|/var/cache/*) continue ;;
        /etc/systemd/system/*.wants/*) continue ;;
        /var/lib/dpkg/info/blocker-adulte.*) continue ;;
        /etc/nftables.conf.avant-blocker-adulte) continue ;;
    esac

    # 5. Arbre de construction ou depot source : signale, mais pas compte comme
    #    une installation dissimulee.
    if racine_arbre="$(arbre_non_installe "${chemin}")" && [ -n "${racine_arbre}" ]; then
        if [ "${construction}" -eq 0 ]; then
            warn "arbre non installe detecte : ${racine_arbre}"
            info "ces copies ne sont pas une installation ; les chemins sont listes ci-dessous."
        fi
        info "(hors installation) ${chemin}"
        construction=$((construction + 1))
        continue
    fi

    ko "chemin NON DECLARE dans le README : ${chemin}"
    non_declares=$((non_declares + 1))
done < "${TROUVES}"

if [ "${non_declares}" -eq 0 ]; then
    ok "tous les chemins installes sont declares dans le README"
    [ "${construction}" -gt 0 ] && \
        info "(${construction} chemins ecartes comme arbre de construction)"
else
    ko "${non_declares} chemin(s) non declare(s) — le README doit etre complete"
fi

# ---------------------------------------------------------------------------
titre "3. Tout ce qui est declare existe (ou est legitimement absent)"
# ---------------------------------------------------------------------------

absents=0
while IFS= read -r declare_; do
    [ -e "${declare_}" ] && continue

    # Emplacements conditionnels : navigateur non installe, auditd absent, etc.
    case "${declare_}" in
        /etc/firefox/*|/etc/opt/chrome/*|/etc/chromium/*|/etc/opt/chromium/*|/etc/brave/*)
            info "(absent, navigateur non installe) ${declare_}" ; continue ;;
        /etc/audit/*)
            info "(absent, auditd non installe) ${declare_}" ; continue ;;
        /etc/initramfs-tools/*|/usr/lib/dracut/*|/etc/initcpio/*)
            # Un seul des trois generateurs est present sur une machine donnee.
            info "(absent, generateur d initramfs different) ${declare_}" ; continue ;;
        /etc/pacman.d/*)
            info "(absent, pacman non utilise sur cette distribution) ${declare_}" ; continue ;;
        /usr/lib/systemd/system/*|/lib/systemd/system/*)
            # usr-merge : les deux chemins designent le meme fichier sur une
            # distribution recente, un seul des deux existe sur une ancienne.
            autre="${declare_#/usr}"
            case "${declare_}" in
                /usr/lib/systemd/*) autre="/lib/systemd/${declare_#/usr/lib/systemd/}" ;;
                *)                  autre="/usr${declare_}" ;;
            esac
            if [ -e "${autre}" ]; then
                continue
            fi
            ;;
        /run/blocker-adulte|/run/blocker-adulte/*)
            info "(absent, cree seulement quand les services tournent) ${declare_}" ; continue ;;
    esac

    if [ "${nb_trouves}" -eq 0 ]; then
        continue   # outil non installe : normal que rien n'existe
    fi

    ko "declare dans le README mais absent du disque : ${declare_}"
    absents=$((absents + 1))
done < "${MANIFESTE}"

if [ "${absents}" -eq 0 ]; then
    ok "le manifeste ne declare aucun emplacement fantome"
fi

# ---------------------------------------------------------------------------
titre "4. Les processus sont visibles sous leur vrai nom"
# ---------------------------------------------------------------------------

if pgrep -x dnsmasq >/dev/null 2>&1; then
    if ps aux | grep -v grep | grep -q 'dnsmasq'; then
        ok "le processus dnsmasq apparait dans « ps aux » sous son vrai nom"
        info "$(ps aux | grep -v grep | grep dnsmasq | head -1 | cut -c1-110)"
    else
        ko "le resolveur tourne mais aucun processus dnsmasq visible dans ps"
    fi

    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iUDP:53 2>/dev/null | grep -q dnsmasq; then
            ok "lsof montre dnsmasq en ecoute sur le port 53"
        else
            warn "lsof ne montre pas dnsmasq sur le port 53 (ss -ulpn donnera plus de detail)"
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -ulpn 2>/dev/null | grep -q 'dnsmasq'; then
            ok "ss montre dnsmasq en ecoute sur le port 53"
        else
            warn "ss ne montre pas dnsmasq en ecoute"
        fi
    fi
else
    warn "aucun resolveur en cours, controle des processus ignore"
fi

if systemd_actif && systemctl is-active --quiet blocker-guard.service 2>/dev/null; then
    if ps aux | grep -v grep | grep -q 'blocker-guard'; then
        ok "le watchdog apparait dans « ps aux » sous le nom blocker-guard"
    else
        ko "blocker-guard.service actif mais invisible dans ps"
    fi
fi

# ---------------------------------------------------------------------------
titre "5. L'entree dpkg est visible"
# ---------------------------------------------------------------------------

if dpkg-query -W -f='${Status}' blocker-adulte 2>/dev/null | grep -q 'install ok installed'; then
    ok "« dpkg -l blocker-adulte » montre le paquet sous son vrai nom"
    info "$(dpkg-query -W -f='${Package} ${Version} ${Status}' blocker-adulte 2>/dev/null)"

    # Le nombre de fichiers listes par dpkg doit correspondre a ce qui est sur
    # le disque : un paquet qui poserait des fichiers hors de sa liste serait
    # precisement le comportement interdit.
    nb_dpkg="$(dpkg -L blocker-adulte 2>/dev/null | grep -c '^/usr' || true)"
    info "${nb_dpkg} fichiers declares sous /usr par dpkg -L"
else
    warn "paquet .deb non installe (installation directe par install.sh)"
    info "l'absence d'entree dpkg est alors normale et attendue."
fi

# ---------------------------------------------------------------------------
titre "6. Aucun mecanisme de dissimulation"
# ---------------------------------------------------------------------------

if [ -s /etc/ld.so.preload ]; then
    if grep -qi 'blocker' /etc/ld.so.preload; then
        ko "/etc/ld.so.preload reference blocker-adulte : c'est un mecanisme de dissimulation interdit"
    else
        warn "/etc/ld.so.preload existe mais ne mentionne pas blocker-adulte"
        info "$(cat /etc/ld.so.preload)"
    fi
else
    ok "aucun LD_PRELOAD global (/etc/ld.so.preload vide ou absent)"
fi

if lsmod 2>/dev/null | grep -qi 'blocker'; then
    ko "un module noyau nomme blocker* est charge : non prevu par ce projet"
else
    ok "aucun module noyau du projet (le projet n'en fournit aucun)"
fi

if mount 2>/dev/null | grep -E '/proc(/| )' | grep -qi 'blocker\|hidepid=2'; then
    warn "un montage particulier de /proc est en place — verifier qu'il ne vient pas de ce projet"
else
    ok "/proc n'est pas monte de facon a masquer des processus"
fi

# ---------------------------------------------------------------------------
titre "7. Aucune copie hors des emplacements documentes"
# ---------------------------------------------------------------------------

# La liste des executables a chercher est DERIVEE, jamais recopiee ici.
#
# Elle etait auparavant ecrite en dur, et n'a pas suivi l'ajout de
# blocker-safesearch, blocker-doh-refresh et blocker-status : ces trois scripts
# ont cesse d'etre verifies sans que rien ne le signale. Une liste dupliquee
# derive toujours ; on repart donc des sources de verite.
#
# Deux sources, reunies :
#   - le Makefile, qui decide seul de ce qui s'installe et ou. C'est la source
#     de reference, disponible quand le test tourne depuis le depot.
#   - les executables reellement poses dans /usr/lib/blocker-adulte, qui prend
#     le relais quand le test tourne depuis /usr/share/blocker-adulte/tests,
#     ou aucun Makefile n'accompagne l'installation.
scripts_a_chercher() {
    local makefile
    for makefile in "$(dirname "$0")/../Makefile" \
                    "$(dirname "$0")/../../Makefile" \
                    /usr/share/blocker-adulte/Makefile; do
        [ -r "${makefile}" ] || continue
        grep -oE 'bin/blocker-[a-z0-9-]+' "${makefile}" | sed 's#^bin/##'
    done
    [ -d /usr/lib/blocker-adulte ] && \
        find /usr/lib/blocker-adulte -maxdepth 1 -type f -name 'blocker-*' \
             -not -name '*.sh' -printf '%f\n' 2>/dev/null
}

mapfile -t SCRIPTS < <(scripts_a_chercher | sort -u)

# Une extraction vide signifie que le Makefile a change de forme ou que rien
# n'est installe. Passer sous silence donnerait un test toujours vert qui ne
# verifie plus rien : on echoue franchement.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    ko "aucun executable a chercher n'a pu etre derive"
    info "ni le Makefile ni /usr/lib/blocker-adulte n'ont fourni de liste."
    info "Le controle anti-copie ne verifie donc RIEN : le corriger avant"
    info "de se fier au resultat de ce test."
else
    ok "${#SCRIPTS[@]} executables a verifier, derives du Makefile et de l'installation"
    info "$(printf '%s ' "${SCRIPTS[@]}")"
fi

# On cherche les executables du projet ailleurs que la ou ils doivent etre.
copies=0
for script in "${SCRIPTS[@]}"; do
    while IFS= read -r emplacement; do
        [ -n "${emplacement}" ] || continue
        case "${emplacement}" in
            /usr/lib/blocker-adulte/*|/usr/share/blocker-adulte/*) continue ;;
        esac

        # /usr/sbin accueille volontairement les commandes destinees a root.
        # Lesquelles ? On le demande au manifeste plutot que de les nommer ici :
        # une liste ecrite en dur avait deja cesse de suivre les ajouts une
        # premiere fois, et « blocker-update » l'aurait fait une seconde.
        if grep -qxF "${emplacement}" "${MANIFESTE}"; then
            continue
        fi
        # Depot source ou arbre de construction : reconnu a la presence d'un
        # Makefile et d'un debian/control dans un repertoire ancetre.
        racine="$(dirname "$(dirname "${emplacement}")")"
        if [ -f "${racine}/Makefile" ] && [ -f "${racine}/debian/control" ]; then
            info "(depot source) ${emplacement}"
            continue
        fi
        ko "copie hors emplacement documente : ${emplacement}"
        copies=$((copies + 1))
    done < <(find / -xdev \
                  \( -path /proc -o -path /sys -o -path /tmp -o -path /var/tmp \) -prune -o \
                  -type f -name "${script}" -print 2>/dev/null)
done

if [ "${copies}" -eq 0 ]; then
    ok "aucune copie des executables hors de /usr/lib/blocker-adulte"
fi

# Emplacements ou un outil cherchant a survivre discretement se placerait.
for suspect in /etc/rc.local /etc/cron.d /etc/cron.daily /var/spool/cron/crontabs \
               /etc/profile.d /usr/local/bin /usr/local/sbin /etc/systemd/user; do
    [ -e "${suspect}" ] || continue
    if grep -rqil 'blocker-adulte' "${suspect}" 2>/dev/null; then
        ko "reference a blocker-adulte dans un emplacement non documente : ${suspect}"
        grep -ril 'blocker-adulte' "${suspect}" 2>/dev/null | sed 's/^/        /'
        copies=$((copies + 1))
    fi
done

if [ "${copies}" -eq 0 ]; then
    ok "aucune reference dans cron, rc.local, profile.d ou /usr/local"
fi

# ---------------------------------------------------------------------------
titre "8. Recapitulatif des huit composants"
# ---------------------------------------------------------------------------

composant() {
    local numero="$1" nom="$2" preuve="$3"
    if [ -e "${preuve}" ]; then
        ok "composant ${numero} — ${nom}"
    else
        warn "composant ${numero} — ${nom} : ${preuve} absent"
    fi
}

composant 1 "resolveur DNS local"        /etc/dnsmasq.d/blocker-adulte.conf
composant 2 "application reseau forcee"  /etc/nftables/blocker-adulte.nft
composant 3 "policies navigateur"        /usr/share/blocker-adulte/policies
composant 4 "hook initramfs"             /etc/initramfs-tools/hooks/blocker-adulte
composant 5 "reaction a la reinstallation" /usr/lib/blocker-adulte/blocker-apply-policies
composant 6 "services a surveillance croisee" /lib/systemd/system/blocker-guard.service
composant 7 "timer de self-heal"         /lib/systemd/system/blocker-selfheal.timer
composant 8 "journalisation auditd"      /etc/audit/rules.d/blocker-adulte.rules

bilan
