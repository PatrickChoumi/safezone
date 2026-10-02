# shellcheck shell=bash
# blocker-adulte — le delai sur tout ce qui affaiblit la protection
#
# Installee dans /usr/lib/blocker-adulte/blocker-delai.sh, chargee par
# blocker-common.sh.
#
# POURQUOI UN DELAI
#
# L'outil comptait sur la complexite : il fallait savoir ou etaient les choses
# et dans quel ordre agir pour le defaire. Contre son propre auteur, la
# complexite ne retient presque rien, et elle s'use : un obstacle contourne une
# fois se contourne en deux minutes la fois suivante.
#
# Un delai, lui, ne s'use pas. Une envie dure vingt minutes, pas deux jours.
# Toute action qui affaiblit la protection est donc enregistree comme une
# DEMANDE, qui ne devient applicable qu'apres BLOCKER_DELAI_HEURES (48 h par
# defaut, 24 h au minimum), et qui doit alors etre CONFIRMEE dans les sept
# jours. Passe ce delai, elle expire.
#
# Ce qui renforce la protection s'applique tout de suite. Ce qui l'affaiblit
# attend. Rien n'est cache : « blocker-delai » montre chaque demande, son
# echeance et ce qu'elle fera.
#
# CE QUI EST SOUMIS AU DELAI
#
#   - toute modification affaiblissante de /etc/blocker-adulte/blocker.conf ;
#   - le retrait d'un domaine de la liste personnelle (blocker-block) ;
#   - une exception a un blocage (blocker-block --exception) ;
#   - la desinstallation, et donc l'arret durable des services.
#
# LA DATE QUI FAIT FOI
#
# L'age d'une demande se lit sur le « ctime » de son fichier : la date de
# derniere modification de son inode, que le noyau tient a jour et qu'aucune
# commande ordinaire ne peut antidater. Le champ « deposee » du fichier n'est
# qu'informatif.
#
# Ces fonctions lisent les variables BLOCKER_* au moment de l'appel : les
# tests peuvent les charger directement depuis le depot.

# Fenetre de confirmation apres l'echeance : passe ce delai, la demande expire.
BLOCKER_DELAI_VALIDITE_HEURES=168

# ---------------------------------------------------------------------------
# Valeurs par defaut de blocker.conf
# ---------------------------------------------------------------------------
# Seule source des valeurs par defaut : blocker-common.sh les applique avant de
# lire la configuration, et le classement des modifications s'en sert pour
# comparer une variable absente a sa valeur effective.
BLOCKER_CONF_VARIABLES="BLOCKER_LANG BLOCKER_MKINITCPIO_HOOK BLOCKER_UPSTREAM_1
BLOCKER_UPSTREAM_2 BLOCKER_GUARD_INTERVAL BLOCKER_LOCK_HOSTS BLOCKER_SAFESEARCH
BLOCKER_BLOCK_TUNNELS BLOCKER_LIST_URLS BLOCKER_CATEGORIES BLOCKER_DOH_IP_URLS
BLOCKER_DELAI_HEURES BLOCKER_RAPPORT_DESTINATAIRE BLOCKER_RAPPORT_EXPEDITEUR
BLOCKER_RAPPORT_SMTP"

blocker_conf_defaut() {
    case "$1" in
        BLOCKER_LANG)            printf 'auto' ;;
        BLOCKER_MKINITCPIO_HOOK) printf 'non' ;;
        BLOCKER_UPSTREAM_1)      printf '94.140.14.15' ;;
        BLOCKER_UPSTREAM_2)      printf '94.140.15.16' ;;
        BLOCKER_GUARD_INTERVAL)  printf '15' ;;
        BLOCKER_LOCK_HOSTS)      printf 'auto' ;;
        BLOCKER_SAFESEARCH)      printf 'oui' ;;
        BLOCKER_BLOCK_TUNNELS)   printf 'oui' ;;
        BLOCKER_LIST_URLS)
            printf '%s\n%s\n%s' \
                'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts' \
                'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/doh-vpn-proxy-bypass.txt' \
                'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/anti.piracy.txt' ;;
        BLOCKER_CATEGORIES)      printf 'moteurs-sans-filtre frontends-alternatifs reseaux-sociaux chat-video streaming' ;;
        BLOCKER_DOH_IP_URLS)
            printf '%s\n%s' \
                'https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv4.txt' \
                'https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv6.txt' ;;
        BLOCKER_DELAI_HEURES)    printf '48' ;;
        BLOCKER_RAPPORT_DESTINATAIRE|BLOCKER_RAPPORT_EXPEDITEUR|BLOCKER_RAPPORT_SMTP) printf '' ;;
    esac
}

# ---------------------------------------------------------------------------
# Lecture stricte d'un fichier blocker.conf
# ---------------------------------------------------------------------------
# blocker.conf est un fichier shell, mais un fichier PROPOSE n'est jamais
# execute : le sourcer pour l'examiner executerait immediatement n'importe
# quelle commande qu'il contient, et le delai ne protegerait plus rien.
#
# Seules sont acceptees les lignes vides, les commentaires et les affectations
# des variables connues, sans « $ », sans accent grave et sans barre oblique
# inverse. Une valeur entre guillemets peut s'etendre sur plusieurs lignes
# (BLOCKER_LIST_URLS). Tout le reste est une erreur, signalee avec son numero
# de ligne.
#
# Sortie : « NOM<TAB>valeur » par affectation (espaces et retours a la ligne
# ramenes a un espace), « ERREUR<TAB>message » par ligne refusee.
_blocker_m() {
    if command -v m >/dev/null 2>&1; then m "$1" "$2"; else printf '%s' "$1"; fi
}

blocker_conf_lire() {
    awk -v autorises="${BLOCKER_CONF_VARIABLES}" \
        -v t_ligne="$(_blocker_m "ligne" "line")" \
        -v t_interdit="$(_blocker_m "caractere interdit (\$, accent grave ou \\)" "forbidden character (\$, backtick or \\)")" \
        -v t_apres="$(_blocker_m "texte apres la fin de la valeur" "text after the end of the value")" \
        -v t_ni="$(_blocker_m "ni commentaire ni affectation" "neither a comment nor an assignment")" \
        -v t_inconnue="$(_blocker_m "variable inconnue" "unknown variable")" \
        -v t_nue="$(_blocker_m "valeur sans guillemets invalide" "invalid unquoted value")" \
        -v t_guillemet="$(_blocker_m "guillemet jamais referme" "quote never closed")" '
        BEGIN {
            n = split(autorises, liste, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (liste[i] != "") ok[liste[i]] = 1
        }
        function interdit(s) { return (s ~ /[$`\\]/) }
        function sortir(nom, v) {
            gsub(/[[:space:]]+/, " ", v)
            sub(/^ /, "", v); sub(/ $/, "", v)
            print nom "\t" v
        }
        function erreur(numero, texte) { print "ERREUR\t" t_ligne " " numero " : " texte; fautes++ }
        {
            ligne = $0
            sub(/\r$/, "", ligne)
            if (dedans) {
                pos = index(ligne, q)
                if (pos == 0) {
                    if (interdit(ligne)) erreur(NR, t_interdit)
                    valeur = valeur " " ligne
                    next
                }
                morceau = substr(ligne, 1, pos - 1)
                reste = substr(ligne, pos + 1)
                if (interdit(morceau)) erreur(NR, t_interdit)
                if (reste !~ /^[[:space:]]*(#.*)?$/) erreur(NR, t_apres)
                sortir(nom, valeur " " morceau)
                dedans = 0
                next
            }
            if (ligne ~ /^[[:space:]]*(#.*)?$/) next
            if (!match(ligne, /^[A-Z_][A-Z0-9_]*=/)) { erreur(NR, t_ni); next }
            nom = substr(ligne, 1, RLENGTH - 1)
            corps = substr(ligne, RLENGTH + 1)
            if (!(nom in ok)) { erreur(NR, t_inconnue " " nom); next }
            c = substr(corps, 1, 1)
            if (c == "\"" || c == "\047") {
                q = c
                corps = substr(corps, 2)
                pos = index(corps, q)
                if (pos == 0) {
                    if (interdit(corps)) erreur(NR, t_interdit)
                    valeur = corps; dedans = 1; debut = NR
                    next
                }
                v = substr(corps, 1, pos - 1)
                reste = substr(corps, pos + 1)
                if (interdit(v)) { erreur(NR, t_interdit); next }
                if (reste !~ /^[[:space:]]*(#.*)?$/) { erreur(NR, t_apres); next }
                sortir(nom, v)
                next
            }
            v = corps
            sub(/[[:space:]]+#.*$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            if (v !~ /^[A-Za-z0-9._:\/@+,%=-]*$/) { erreur(NR, t_nue); next }
            sortir(nom, v)
        }
        END { if (dedans) erreur(debut, t_guillemet) }
    ' "$1"
}

# Vrai si le fichier ne contient que des affectations acceptables.
blocker_conf_valide() {
    ! blocker_conf_lire "$1" | grep -q '^ERREUR'
}

# Valeur effective d'une variable dans un fichier : la derniere affectation,
# a defaut la valeur par defaut. Espaces normalises.
blocker_conf_valeur() {
    local fichier="$1" nom="$2" v
    v="$(blocker_conf_lire "${fichier}" | awk -F '\t' -v n="${nom}" '$1 == n { v = $2; vu = 1 } END { if (vu) print v; else print "__DEFAUT__" }')"
    if [ "${v}" = "__DEFAUT__" ]; then
        blocker_conf_defaut "${nom}" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    else
        printf '%s' "${v}"
    fi
}

_blocker_oui() {
    case "$1" in oui|yes|1|true) return 0 ;; esac
    return 1
}

_blocker_rang_hosts() {
    case "$1" in oui|yes|1) printf 2 ;; non|no|0) printf 0 ;; *) printf 1 ;; esac
}

# Les mots de « avant » manquent-ils dans « apres » ? (listes separees par des
# espaces : URL, categories)
_blocker_mots_retires() {
    local avant="$1" apres="$2" mot
    for mot in ${avant}; do
        case " ${apres} " in *" ${mot} "*) ;; *) return 0 ;; esac
    done
    return 1
}

# blocker_conf_comparer <fichier en vigueur> <fichier propose>
#
# Une ligne par variable modifiee : « sens<TAB>NOM<TAB>avant<TAB>apres », ou
# sens vaut « renforce », « neutre » ou « affaiblit ». Code de retour 0 si
# rien n'affaiblit la protection, 1 sinon.
#
# Dans le doute, une modification est classee « affaiblit » : un amont DNS
# change, une variable dont on ne sait pas juger. Mieux vaut attendre deux
# jours pour rien que d'appliquer tout de suite un affaiblissement.
blocker_conf_comparer() {
    local en_vigueur="$1" propose="$2" nom avant apres sens affaiblit=0
    local dest_avant
    dest_avant="$(blocker_conf_valeur "${en_vigueur}" BLOCKER_RAPPORT_DESTINATAIRE)"
    for nom in ${BLOCKER_CONF_VARIABLES}; do
        avant="$(blocker_conf_valeur "${en_vigueur}" "${nom}")"
        apres="$(blocker_conf_valeur "${propose}" "${nom}")"
        [ "${avant}" = "${apres}" ] && continue
        sens="affaiblit"
        case "${nom}" in
            BLOCKER_LANG)
                sens="neutre" ;;
            BLOCKER_LOCK_HOSTS)
                [ "$(_blocker_rang_hosts "${apres}")" -ge "$(_blocker_rang_hosts "${avant}")" ] && sens="renforce" ;;
            BLOCKER_SAFESEARCH|BLOCKER_BLOCK_TUNNELS|BLOCKER_MKINITCPIO_HOOK)
                _blocker_oui "${apres}" && sens="renforce" ;;
            BLOCKER_GUARD_INTERVAL|BLOCKER_DELAI_HEURES)
                case "${avant}${apres}" in
                    *[!0-9]*|"") ;;
                    *)
                        if [ "${nom}" = "BLOCKER_GUARD_INTERVAL" ]; then
                            [ "${apres}" -le "${avant}" ] && sens="renforce"
                        else
                            [ "${apres}" -ge "${avant}" ] && sens="renforce"
                        fi ;;
                esac ;;
            BLOCKER_LIST_URLS|BLOCKER_CATEGORIES|BLOCKER_DOH_IP_URLS)
                _blocker_mots_retires "${avant}" "${apres}" || sens="renforce" ;;
            BLOCKER_RAPPORT_DESTINATAIRE)
                [ -z "${avant}" ] && sens="renforce" ;;
            BLOCKER_RAPPORT_EXPEDITEUR|BLOCKER_RAPPORT_SMTP)
                # Sans destinataire, il n'y a pas de rapport a perturber.
                [ -z "${dest_avant}" ] && sens="neutre" ;;
        esac
        [ "${sens}" = "affaiblit" ] && affaiblit=1
        printf '%s\t%s\t%s\t%s\n' "${sens}" "${nom}" "${avant}" "${apres}"
    done
    [ "${affaiblit}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Demandes
# ---------------------------------------------------------------------------
# Une demande est un fichier de « ${BLOCKER_DELAIDIR}/demandes » :
#   <id>            type, objet, date de depot, auteur — rendu immuable
#   <id>.conf       pour une modification de blocker.conf : le fichier propose
#   <id>.confirmee  pose a la confirmation, une fois l'echeance passee
#   <id>.phase1     desinstallation : pose quand la phase 1 a ete executee
#
# Types : conf, retirer-domaine, exception, desinstallation.

_blocker_demandes_dir() { printf '%s/demandes' "${BLOCKER_DELAIDIR}"; }

_blocker_ctime() { stat -c %Z "$1" 2>/dev/null || printf '0'; }

blocker_delai_secondes() {
    local h="${BLOCKER_DELAI_HEURES:-48}"
    case "${h}" in ''|*[!0-9]*) h=48 ;; esac
    [ "${h}" -lt 24 ] && h=24
    printf '%s' $((h * 3600))
}

# Journal des demandes, en ajout seul (chattr +a) : le rapport hebdomadaire le
# relit, et une ligne effacee y laisserait un trou visible.
blocker_historique() {
    local f="${BLOCKER_DELAIDIR}/historique"
    install -d -m 0755 "${BLOCKER_DELAIDIR}" 2>/dev/null || return 0
    if [ ! -e "${f}" ]; then
        : > "${f}"; chmod 0644 "${f}"
        command -v chattr >/dev/null 2>&1 && chattr +a "${f}" 2>/dev/null
    fi
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" "$2" >> "${f}" 2>/dev/null || true
}

blocker_demande_champ() {
    sed -n "s/^$2=//p" "$(_blocker_demandes_dir)/$1" 2>/dev/null | head -1
}

# Ecrit une nouvelle demande et affiche son identifiant.
blocker_demande_creer() {
    local type="$1" objet="$2" conf="${3:-}" dir id
    dir="$(_blocker_demandes_dir)"
    install -d -m 0755 "${dir}" || return 1
    id="$(date '+%Y%m%d-%H%M%S')-${type}-$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 4)"
    {
        printf 'type=%s\n' "${type}"
        printf 'objet=%s\n' "${objet}"
        printf 'deposee=%s\n' "$(date -Is)"
        printf 'par=%s\n' "${SUDO_USER:-root}"
    } > "${dir}/${id}" || return 1
    chmod 0644 "${dir}/${id}"
    if [ -n "${conf}" ]; then
        install -m 0644 "${conf}" "${dir}/${id}.conf" || return 1
        command -v chattr >/dev/null 2>&1 && chattr +i "${dir}/${id}.conf" 2>/dev/null
    fi
    command -v chattr >/dev/null 2>&1 && chattr +i "${dir}/${id}" 2>/dev/null
    blocker_historique "deposee ${type} ${objet}" "${id}"
    printf '%s\n' "${id}"
}

# Moment ou la demande devient applicable (epoch).
blocker_demande_echeance() {
    local c
    c="$(_blocker_ctime "$(_blocker_demandes_dir)/$1")"
    printf '%s' $((c + $(blocker_delai_secondes)))
}

# Moment ou la demande expire (epoch).
blocker_demande_expiration() {
    local dir fin p
    dir="$(_blocker_demandes_dir)"
    fin=$(( $(blocker_demande_echeance "$1") + BLOCKER_DELAI_VALIDITE_HEURES * 3600 ))
    if [ -e "${dir}/$1.phase1" ]; then
        p=$(( $(_blocker_ctime "${dir}/$1.phase1") + BLOCKER_DELAI_VALIDITE_HEURES * 3600 ))
        [ "${p}" -gt "${fin}" ] && fin="${p}"
    fi
    printf '%s' "${fin}"
}

# absente | attente | mure | confirmee | expiree
blocker_demande_etat() {
    local dir maintenant
    dir="$(_blocker_demandes_dir)"
    [ -e "${dir}/$1" ] || { printf 'absente'; return; }
    maintenant="$(date +%s)"
    if [ "${maintenant}" -lt "$(blocker_demande_echeance "$1")" ]; then
        printf 'attente'
    elif [ "${maintenant}" -gt "$(blocker_demande_expiration "$1")" ]; then
        printf 'expiree'
    elif [ -e "${dir}/$1.confirmee" ]; then
        printf 'confirmee'
    else
        printf 'mure'
    fi
}

blocker_demandes_lister() {
    local dir f id
    dir="$(_blocker_demandes_dir)"
    [ -d "${dir}" ] || return 0
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        id="$(basename "${f}")"
        case "${id}" in *.*) continue ;; esac
        if [ -n "${1:-}" ] && [ "$(blocker_demande_champ "${id}" type)" != "$1" ]; then
            continue
        fi
        printf '%s\n' "${id}"
    done | sort
}

# Identifiant d'une demande non expiree de meme type et de meme objet.
blocker_demande_existante() {
    local id etat
    while IFS= read -r id; do
        [ "$(blocker_demande_champ "${id}" objet)" = "$2" ] || continue
        etat="$(blocker_demande_etat "${id}")"
        [ "${etat}" = "expiree" ] && continue
        printf '%s\n' "${id}"
        return 0
    done < <(blocker_demandes_lister "$1")
    return 1
}

blocker_demande_marquer() {
    local f
    f="$(_blocker_demandes_dir)/$1.$2"
    [ -e "${f}" ] && return 0
    date -Is > "${f}" || return 1
    chmod 0644 "${f}"
    command -v chattr >/dev/null 2>&1 && chattr +i "${f}" 2>/dev/null
    return 0
}

blocker_demande_confirmer() {
    [ "$(blocker_demande_etat "$1")" = "mure" ] || return 1
    blocker_demande_marquer "$1" confirmee || return 1
    blocker_historique "confirmee $(blocker_demande_champ "$1" type) $(blocker_demande_champ "$1" objet)" "$1"
}

# Retire la demande et ses fichiers annexes. Sert a l'annulation, a
# l'expiration et apres application.
blocker_demande_clore() {
    local id="$1" motif="$2" dir f type objet
    dir="$(_blocker_demandes_dir)"
    type="$(blocker_demande_champ "${id}" type)"
    objet="$(blocker_demande_champ "${id}" objet)"
    for f in "${dir}/${id}" "${dir}/${id}".*; do
        [ -e "${f}" ] || continue
        command -v chattr >/dev/null 2>&1 && chattr -i "${f}" 2>/dev/null
        rm -f "${f}"
    done
    blocker_historique "${motif} ${type} ${objet}" "${id}"
}

# Vrai si une desinstallation a ete demandee, que le delai est passe et que la
# fenetre de confirmation n'est pas close. C'est la seule condition sous
# laquelle les watchdogs se mettent en retrait.
blocker_retrait_autorise() {
    local id etat
    while IFS= read -r id; do
        etat="$(blocker_demande_etat "${id}")"
        case "${etat}" in mure|confirmee) return 0 ;; esac
    done < <(blocker_demandes_lister desinstallation)
    return 1
}

# Date lisible d'un epoch.
blocker_date() {
    date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}
