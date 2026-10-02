# shellcheck shell=bash
# blocker-adulte — validation et conversion des listes venues de l'exterieur
#
# Installee dans /usr/lib/blocker-adulte/blocker-listes.sh, chargee par
# blocker-common.sh.
#
# POURQUOI CE FICHIER EXISTE
#
# Les listes telechargees etaient recopiees presque telles quelles : toute
# ligne « address= », « server= » ou « local= » d'une liste tierce passait
# directement dans la configuration du resolveur. Une seule ligne
# « server=/domaine/1.2.3.4 » suffisait alors a une liste tierce pour envoyer
# la resolution de ce domaine vers un serveur de son choix.
#
# Regle desormais tenue partout : une source exterieure ne fournit que des
# NOMS DE DOMAINE. Chacun est valide un par un, et c'est l'outil lui-meme qui
# ecrit la directive, toujours la meme : « address=/domaine/# ». Rien d'autre
# qu'un blocage ne peut donc entrer par une liste.
#
# Ces fonctions ne lisent aucune variable globale du projet : les tests les
# chargent directement depuis le depot.

# Vrai si l'argument est un nom de domaine acceptable : au moins deux
# etiquettes, chacune de 1 a 63 caracteres [a-z0-9-] sans tiret en bordure,
# 253 caracteres au plus, et un dernier element non numerique (ce qui ecarte
# les adresses IP).
blocker_domaine_valide() {
    printf '%s\n' "$1" | awk '
        { exit !(valide($0)) }
        function valide(d,   n, i, parts) {
            if (length(d) > 253) return 0
            if (d !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/) return 0
            n = split(d, parts, ".")
            for (i = 1; i <= n; i++) if (length(parts[i]) > 63) return 0
            if (parts[n] ~ /^[0-9]+$/) return 0
            return 1
        }'
}

# blocker_convertir_liste <source> <sortie> [fichier d'exceptions]
#
# Accepte quatre formats, melanges ou non dans le meme fichier :
#   - hosts           « 0.0.0.0 domaine », « 127.0.0.1 domaine », « :: domaine »
#   - dnsmasq         « address=/domaine/... », « server=/domaine/... »,
#                     « local=/domaine/ » — seul le domaine est retenu, la
#                     cible ecrite par la liste est ignoree
#   - adblock simple  « ||domaine^ »
#   - un domaine nu par ligne
#
# Produit des lignes « address=/domaine/# » triees et sans doublon. Les
# domaines du fichier d'exceptions (un par ligne) sont ecartes : c'est la seule
# facon de lever un blocage exact, « address= » l'emportant sur « server= »
# pour un meme domaine dans dnsmasq.
blocker_convertir_liste() {
    local src="$1" out="$2" exceptions="${3:-/dev/null}"
    [ -r "${exceptions}" ] || exceptions=/dev/null
    awk -v fexc="${exceptions}" '
        function valide(d,   n, i, parts) {
            if (length(d) > 253) return 0
            if (d !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/) return 0
            n = split(d, parts, ".")
            for (i = 1; i <= n; i++) if (length(parts[i]) > 63) return 0
            if (parts[n] ~ /^[0-9]+$/) return 0
            if (d == "localhost.localdomain" || d == "ip6-localhost.localdomain") return 0
            return 1
        }
        function garder(d) {
            d = tolower(d)
            sub(/\.$/, "", d)
            if (!valide(d)) { rejetees++; return }
            if (d in exclu) return
            print "address=/" d "/#"
        }
        # Les exceptions sont lues d avance. Un « FNR == NR » sur deux fichiers
        # se tromperait des que le premier est vide : la liste entiere serait
        # alors prise pour des exceptions.
        BEGIN {
            while ((getline e < fexc) > 0) {
                sub(/[[:space:]]*#.*$/, "", e)
                gsub(/[[:space:]]/, "", e)
                if (e != "") exclu[tolower(e)] = 1
            }
            close(fexc)
        }
        {
            ligne = $0
            sub(/\r$/, "", ligne)
            sub(/^[[:space:]]+/, "", ligne)
            sub(/[[:space:]]+$/, "", ligne)
            if (ligne == "" || ligne ~ /^[#!]/) next

            # dnsmasq : on ne garde que les domaines, jamais la cible.
            if (ligne ~ /^(address|server|local)=\//) {
                corps = ligne
                sub(/^[a-z]+=\//, "", corps)
                n = split(corps, morceaux, "/")
                # Le dernier morceau est la cible (« # », une adresse ou rien).
                for (i = 1; i < n; i++) if (morceaux[i] != "") garder(morceaux[i])
                next
            }

            # hosts : adresse nulle ou de bouclage, puis un ou plusieurs noms.
            if (ligne ~ /^(0\.0\.0\.0|127\.0\.0\.1|::|::1|0)[[:space:]]/) {
                n = split(ligne, champs, /[[:space:]]+/)
                for (i = 2; i <= n; i++) {
                    if (champs[i] ~ /^#/) break
                    if (champs[i] ~ /^(localhost|broadcasthost|local)$/) continue
                    garder(champs[i])
                }
                next
            }

            # adblock simple : ||domaine^
            if (ligne ~ /^\|\|[^\/^*]+\^$/) {
                d = ligne
                sub(/^\|\|/, "", d); sub(/\^$/, "", d)
                garder(d)
                next
            }

            # Domaine nu, eventuellement suivi d un commentaire.
            sub(/[[:space:]]+#.*$/, "", ligne)
            if (ligne !~ /[[:space:]]/) { garder(ligne); next }

            rejetees++
        }
        END {
            if (rejetees > 0) printf "%d\n", rejetees > "/dev/stderr"
        }
    ' "${src}" 2>"${out}.rejets" | LC_ALL=C sort -u > "${out}"
}

# Nombre de lignes ecartees lors de la derniere conversion vers <sortie>.
blocker_conversion_rejets() {
    local n
    n="$(cat "$1.rejets" 2>/dev/null)"
    rm -f "$1.rejets"
    printf '%s\n' "${n:-0}"
}

# blocker_filtrer_ip <famille 4|6> < entree > sortie
#
# Garde les adresses (ou prefixes) IP publiques et bien formees d'une liste
# communautaire : « adresse  # commentaire » par ligne. Les reseaux prives, de
# bouclage, lien-local, multicast et les prefixes trop larges (moins de /16 en
# IPv4, de /32 en IPv6) sont ecartes : une liste tierce ne doit pas pouvoir
# couper le reseau local ni la moitie d'internet.
blocker_filtrer_ip() {
    local famille="$1"
    awk -v famille="${famille}" '
        function octets_ok(a,   n, i, o) {
            n = split(a, o, ".")
            if (n != 4) return 0
            for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) return 0
            if (o[1] == 0 || o[1] == 10 || o[1] == 127) return 0
            if (o[1] == 169 && o[2] == 254) return 0
            if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
            if (o[1] == 192 && o[2] == 168) return 0
            if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
            if (o[1] >= 224) return 0
            return 1
        }
        {
            sub(/\r$/, "")
            sub(/#.*$/, "")
            gsub(/[[:space:]]/, "")
            if ($0 == "") next
            a = $0; p = ""
            if (index(a, "/") > 0) { p = substr(a, index(a, "/") + 1); a = substr(a, 1, index(a, "/") - 1) }
            if (p != "" && p !~ /^[0-9]+$/) next
            if (famille == 4) {
                if (!octets_ok(a)) next
                if (p != "" && (p + 0 < 16 || p + 0 > 32)) next
            } else {
                a = tolower(a)
                if (a !~ /^[0-9a-f:]+$/ || index(a, ":") == 0) next
                if (a ~ /^(::|::1)$/ || a ~ /^fe[89ab]/ || a ~ /^f[cd]/ || a ~ /^ff/) next
                if (p != "" && (p + 0 < 32 || p + 0 > 128)) next
            }
            print (p == "" ? a : a "/" p)
        }
    ' | LC_ALL=C sort -u
}
