# shellcheck shell=bash
# blocker-adulte — couche d'adaptation a la distribution
#
# Installee dans /usr/lib/blocker-adulte/blocker-os.sh, chargee par
# blocker-common.sh : tout script du projet dispose donc de ces fonctions.
#
# POURQUOI CE FICHIER EXISTE
#
# Le projet est ne sur Ubuntu et en avait pris toutes les habitudes : dpkg,
# apt-get, adduser, initramfs-tools, /etc/nftables.conf. Aucune de ces
# habitudes n'est universelle, et chacune etait ecrite en dur a plusieurs
# endroits. Ce fichier est le SEUL endroit qui connait ces differences ; le
# reste du projet ne parle plus qu'en termes de roles (« le paquet qui fournit
# dig ») et d'actions (« installer », « reconstruire l'initramfs »).
#
# CE QUI RESTE OBLIGATOIRE, QUELLE QUE SOIT LA DISTRIBUTION
#
#   - systemd : les huit composants reposent sur des unites, des timers et le
#     watchdog systemd. Il n'existe pas d'equivalent portable en OpenRC ou en
#     runit, et en fabriquer un serait un autre projet.
#   - nftables : le composant 2 est un jeu de regles nftables. iptables-legacy
#     ne sait pas exprimer « meta skuid », dont depend l'exemption du resolveur.
#
# Tout le reste s'adapte. Une distribution inconnue n'est pas refusee : les
# composants qu'on ne sait pas configurer sont signales inactifs, et le reste
# fonctionne.

# ---------------------------------------------------------------------------
# Identification
# ---------------------------------------------------------------------------
BLOCKER_OS_ID=""
BLOCKER_OS_LIKE=""
BLOCKER_OS_NAME=""
BLOCKER_FAMILY="inconnue"     # debian | rhel | arch | suse | alpine | inconnue
BLOCKER_PKGMGR="aucun"        # apt | dnf | yum | pacman | zypper | apk | aucun
BLOCKER_INITRAMFS="aucun"     # initramfs-tools | dracut | mkinitcpio | aucun

# Deux chemins sont indirectes par une variable. Ce n'est pas de la
# configuration : c'est ce qui permet a tests/test_portabilite.sh de rejouer la
# detection avec l'identite d'une Fedora ou d'une Arch sans disposer de la
# machine correspondante. Les valeurs par defaut sont les vrais chemins.
BLOCKER_OS_RELEASE="${BLOCKER_OS_RELEASE:-/etc/os-release}"
BLOCKER_INITRAMFS_DIR="${BLOCKER_INITRAMFS_DIR:-/etc/initramfs-tools}"

# /etc/os-release est un fichier d'affectations shell, mais le sourcer
# ecraserait des variables courantes (NAME, VERSION, HOME sur certaines
# distributions creatives). On le lit champ par champ.
_blocker_os_field() {
    [ -r "${BLOCKER_OS_RELEASE}" ] || return 1
    sed -n "s/^$1=//p" "${BLOCKER_OS_RELEASE}" | head -1 | sed 's/^"//; s/"$//'
}

blocker_os_detect() {
    BLOCKER_OS_ID="$(_blocker_os_field ID || true)"
    BLOCKER_OS_LIKE="$(_blocker_os_field ID_LIKE || true)"
    BLOCKER_OS_NAME="$(_blocker_os_field PRETTY_NAME || true)"
    [ -n "${BLOCKER_OS_NAME}" ] || BLOCKER_OS_NAME="$(_blocker_os_field NAME || true)"

    # ID est unique, ID_LIKE est une liste separee par des espaces. On teste les
    # deux d'un coup, encadres d'espaces pour eviter qu'« arch » ne corresponde a
    # « archlinux-arm » par accident.
    case " ${BLOCKER_OS_ID} ${BLOCKER_OS_LIKE} " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" raspbian "*) BLOCKER_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*|*" rocky "*) BLOCKER_FAMILY="rhel" ;;
        *" arch "*|*" archlinux "*|*" manjaro "*) BLOCKER_FAMILY="arch" ;;
        *" suse "*|*" opensuse "*|*" sles "*) BLOCKER_FAMILY="suse" ;;
        *" alpine "*) BLOCKER_FAMILY="alpine" ;;
    esac

    # Le gestionnaire de paquets est deduit de ce qui est REELLEMENT installe,
    # pas de la famille : une machine peut porter le nom d'une famille et le
    # gestionnaire d'une autre (conteneurs bricoles, distributions derivees).
    # L'ordre place d'abord le gestionnaire attendu pour la famille.
    local candidats="apt-get dnf yum pacman zypper apk"
    case "${BLOCKER_FAMILY}" in
        rhel)   candidats="dnf yum apt-get pacman zypper apk" ;;
        arch)   candidats="pacman apt-get dnf yum zypper apk" ;;
        suse)   candidats="zypper dnf yum apt-get pacman apk" ;;
        alpine) candidats="apk apt-get dnf yum pacman zypper" ;;
    esac
    local c
    for c in ${candidats}; do
        if command -v "${c}" >/dev/null 2>&1; then
            case "${c}" in
                apt-get) BLOCKER_PKGMGR="apt" ;;
                *)       BLOCKER_PKGMGR="${c}" ;;
            esac
            break
        fi
    done

    # Generateur d'initramfs. Meme logique : on regarde ce qui est la.
    if [ -d "${BLOCKER_INITRAMFS_DIR}" ] && command -v update-initramfs >/dev/null 2>&1; then
        BLOCKER_INITRAMFS="initramfs-tools"
    elif command -v dracut >/dev/null 2>&1; then
        BLOCKER_INITRAMFS="dracut"
    elif command -v mkinitcpio >/dev/null 2>&1; then
        BLOCKER_INITRAMFS="mkinitcpio"
    fi
}

# ---------------------------------------------------------------------------
# Noms de paquets, par role
# ---------------------------------------------------------------------------
# On ne renvoie pas UN nom mais une liste de candidats, du plus probable au
# moins probable, et l'appelant retient le premier que le gestionnaire de
# paquets connait reellement. C'est ce qui permet de survivre aux renommages
# (dnsutils -> bind9-dnsutils sur Debian, bind-tools -> bind sur Arch) sans
# maintenir une table par version de distribution.
#
# Une liste vide est une reponse valable : elle signifie « ce role est deja
# couvert par le systeme de base » (systemd-resolved fait partie de systemd
# sur Arch, par exemple).
blocker_pkg_candidats() {
    case "$1" in
        dnsmasq)
            case "${BLOCKER_FAMILY}" in
                debian) printf 'dnsmasq-base dnsmasq\n' ;;
                *)      printf 'dnsmasq\n' ;;
            esac ;;
        nftables)
            printf 'nftables\n' ;;
        resolved)
            case "${BLOCKER_FAMILY}" in
                debian) printf 'systemd-resolved\n' ;;
                rhel)   printf 'systemd-resolved\n' ;;
                suse)   printf 'systemd-network\n' ;;
                *)      printf '\n' ;;   # inclus dans systemd
            esac ;;
        auditd)
            case "${BLOCKER_FAMILY}" in
                debian) printf 'auditd\n' ;;
                *)      printf 'audit\n' ;;
            esac ;;
        curl)
            printf 'curl\n' ;;
        dig)
            case "${BLOCKER_FAMILY}" in
                debian) printf 'bind9-dnsutils dnsutils\n' ;;
                rhel)   printf 'bind-utils\n' ;;
                arch)   printf 'bind bind-tools\n' ;;
                suse)   printf 'bind-utils\n' ;;
                alpine) printf 'bind-tools\n' ;;
                *)      printf 'bind-utils bind-tools dnsutils\n' ;;
            esac ;;
        chattr)
            printf 'e2fsprogs\n' ;;
        initramfs)
            case "${BLOCKER_INITRAMFS}" in
                initramfs-tools) printf 'initramfs-tools\n' ;;
                dracut)          printf 'dracut\n' ;;
                mkinitcpio)      printf 'mkinitcpio\n' ;;
                *)               printf '\n' ;;
            esac ;;
        *) printf '\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# Interrogation et installation de paquets
# ---------------------------------------------------------------------------
blocker_pkg_installe() {
    case "${BLOCKER_PKGMGR}" in
        apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
        apk)    apk info -e "$1" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Le gestionnaire connait-il ce nom de paquet ? Sert a departager les listes de
# candidats sans tenter une installation qui echouerait.
blocker_pkg_connu() {
    case "${BLOCKER_PKGMGR}" in
        apt)    apt-cache show "$1" >/dev/null 2>&1 ;;
        dnf)    dnf --quiet --cacheonly info "$1" >/dev/null 2>&1 ||
                dnf --quiet info "$1" >/dev/null 2>&1 ;;
        yum)    yum --quiet info "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        zypper) zypper --quiet --non-interactive search --match-exact "$1" >/dev/null 2>&1 ;;
        apk)    [ -n "$(apk search -x "$1" 2>/dev/null)" ] ;;
        *)      return 1 ;;
    esac
}

# Premier candidat que le gestionnaire connait, pour un role donne. Vide si le
# role n'a pas de paquet sur cette distribution (ou si aucun candidat n'existe).
blocker_pkg_pour_role() {
    local role="$1" p
    for p in $(blocker_pkg_candidats "${role}"); do
        if blocker_pkg_connu "${p}"; then printf '%s\n' "${p}"; return 0; fi
    done
    # Aucun candidat reconnu : on renvoie le premier de la liste malgre tout,
    # pour que le message d'erreur cite un nom que l'utilisateur peut chercher.
    blocker_pkg_candidats "${role}" | awk '{print $1}'
}

blocker_pkg_maj_index() {
    case "${BLOCKER_PKGMGR}" in
        apt)    env DEBIAN_FRONTEND=noninteractive apt-get update ;;
        dnf|yum) return 0 ;;   # resolvent leurs metadonnees a l'installation
        pacman) pacman -Sy --noconfirm ;;
        zypper) zypper --non-interactive refresh ;;
        apk)    apk update ;;
        *)      return 0 ;;
    esac
}

blocker_pkg_installer() {
    [ $# -gt 0 ] || return 0
    case "${BLOCKER_PKGMGR}" in
        apt)    env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        pacman) pacman -S --needed --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        apk)    apk add "$@" ;;
        *)      return 1 ;;
    esac
}

# Commande de suppression, affichee par blocker-uninstall --manuel. On ne la
# lance jamais nous-memes : le retrait du paquet est une etape que
# l'utilisateur tape lui-meme.
blocker_pkg_commande_retrait() {
    case "${BLOCKER_PKGMGR}" in
        apt)    printf 'apt purge blocker-adulte\n' ;;
        dnf)    printf 'dnf remove blocker-adulte\n' ;;
        yum)    printf 'yum remove blocker-adulte\n' ;;
        pacman) printf 'pacman -Rns blocker-adulte\n' ;;
        zypper) printf 'zypper remove blocker-adulte\n' ;;
        apk)    printf 'apk del blocker-adulte\n' ;;
        *)      printf 'apt purge blocker-adulte\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# Utilisateur systeme
# ---------------------------------------------------------------------------
# « adduser » est un script Debian ; « useradd » vient de shadow-utils et
# existe partout. On unifie sur useradd.
blocker_user_shell_nologin() {
    local s
    for s in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do
        [ -x "${s}" ] && { printf '%s\n' "${s}"; return 0; }
    done
    printf '/bin/false\n'
}

blocker_user_creer() {
    local u="$1"
    getent passwd "${u}" >/dev/null 2>&1 && return 0
    command -v useradd >/dev/null 2>&1 || return 1
    useradd --system --user-group --no-create-home \
            --home-dir /nonexistent --shell "$(blocker_user_shell_nologin)" \
            "${u}"
}

blocker_user_supprimer() {
    local u="$1"
    getent passwd "${u}" >/dev/null 2>&1 || return 0
    command -v userdel >/dev/null 2>&1 || return 1
    userdel "${u}" 2>/dev/null || true
    # userdel retire le groupe prive sur la plupart des distributions ; ailleurs
    # il reste, et on le retire explicitement.
    if getent group "${u}" >/dev/null 2>&1 && command -v groupdel >/dev/null 2>&1; then
        groupdel "${u}" 2>/dev/null || true
    fi
    ! getent passwd "${u}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Emplacements systeme
# ---------------------------------------------------------------------------
# Repertoire des unites systemd fournies par un paquet. /lib/systemd/system est
# la reponse Debian historique ; sur une distribution usr-merge (toutes les
# recentes) c'est un lien vers /usr/lib/systemd/system. On demande a systemd
# plutot que de deviner.
blocker_unitdir() {
    local d
    if command -v pkg-config >/dev/null 2>&1; then
        d="$(pkg-config --variable=systemdsystemunitdir systemd 2>/dev/null)"
        [ -n "${d}" ] && { printf '%s\n' "${d}"; return 0; }
    fi
    for d in /usr/lib/systemd/system /lib/systemd/system; do
        [ -d "${d}" ] && { printf '%s\n' "${d}"; return 0; }
    done
    printf '/usr/lib/systemd/system\n'
}

# Fichier charge par nftables.service au demarrage. Debian et Arch utilisent
# /etc/nftables.conf, Fedora et RHEL /etc/sysconfig/nftables.conf. Plutot que de
# tenir une table, on lit la ligne ExecStart de l'unite : c'est elle qui fait
# foi, et elle reste juste si la distribution change d'avis.
blocker_nft_persist_file() {
    local ligne f
    if command -v systemctl >/dev/null 2>&1; then
        ligne="$(systemctl cat nftables.service 2>/dev/null | sed -n 's/^ExecStart=.*-f *//p' | head -1)"
        f="$(printf '%s' "${ligne}" | awk '{print $1}')"
        case "${f}" in
            /*) printf '%s\n' "${f}"; return 0 ;;
        esac
    fi
    case "${BLOCKER_FAMILY}" in
        rhel) printf '/etc/sysconfig/nftables.conf\n' ;;
        *)    printf '/etc/nftables.conf\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# Initramfs
# ---------------------------------------------------------------------------
# Le composant 4 embarque un jeu de regles nftables dans l'image initramfs pour
# qu'il soit charge avant le switch_root et survive donc a un demarrage en mode
# recovery. Les trois generateurs courants n'ont rien en commun : chacun a son
# emplacement de hook et sa commande de reconstruction.
#
# Les fichiers propres a chaque generateur sont poses par blocker-configure ;
# ces fonctions ne font que dire OU et COMMENT.
blocker_initramfs_hook_paths() {
    case "${BLOCKER_INITRAMFS}" in
        initramfs-tools)
            printf '/etc/initramfs-tools/hooks/blocker-adulte\n'
            printf '/etc/initramfs-tools/scripts/init-bottom/blocker-adulte\n' ;;
        dracut)
            printf '/usr/lib/dracut/modules.d/99blocker-adulte/module-setup.sh\n'
            printf '/usr/lib/dracut/modules.d/99blocker-adulte/blocker-adulte-prepivot.sh\n' ;;
        mkinitcpio)
            printf '/etc/initcpio/install/blocker-adulte\n'
            printf '/etc/initcpio/hooks/blocker-adulte\n' ;;
    esac
}

blocker_initramfs_rebuild() {
    case "${BLOCKER_INITRAMFS}" in
        initramfs-tools) update-initramfs -u ;;
        dracut)          dracut --force --regenerate-all ;;
        mkinitcpio)      mkinitcpio -P ;;
        *)               return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Hooks du gestionnaire de paquets (composant 5)
# ---------------------------------------------------------------------------
# But : reappliquer les policies navigateur immediatement apres une
# reinstallation de navigateur, sans attendre la passe de self-heal.
#
# Seuls dpkg et pacman offrent un vrai point d'accroche par simple depot de
# fichier. dnf et zypper demandent un greffon en Python, hors de proportion
# ici. Partout, y compris la ou un hook existe, une unite « path » systemd
# surveille les repertoires de policies : c'est la reponse portable, et elle
# couvre aussi les navigateurs installes par snap ou flatpak, que le
# gestionnaire de paquets ne voit pas.
blocker_pkg_hook_path() {
    case "${BLOCKER_PKGMGR}" in
        pacman) printf '/etc/pacman.d/hooks/95-blocker-adulte.hook\n' ;;
    esac
}

blocker_os_detect
