# blocker-adulte

Blocage de contenu adulte pour une machine Linux personnelle, **persistant et
distribué sur huit composants indépendants**.

Fonctionne sur toute distribution offrant **systemd** et **nftables** :
Debian, Ubuntu, Fedora, RHEL, Arch, openSUSE, Alpine. Messages en **français ou
en anglais**, selon la locale. Voir
[Distributions supportées](#distributions-supportées) et
[Langue](#langue--français-et-anglais).

L'outil n'est pas conçu pour être impossible à retirer. Il est conçu pour que le
retrait demande de **savoir ce qu'on fait, où, et dans quel ordre** — ce qui
suffit à écarter la désactivation impulsive, sans jamais transformer la machine
en boîte noire.

**Aucune commande ne retire tout.** Le retrait se fait en
[quatre phases](#désinstallation), soit huit commandes, avec un jeton tiré au
hasard à chaque étape. Ce n'est ni une minuterie ni un piège : la procédure
manuelle équivalente est affichable à tout moment par `blocker-uninstall --manuel`.

Deux commandes à retenir :

```bash
blocker-status              # est-ce que ça marche, là, maintenant ?
blocker-status --sonde      # le vérifier par de vraies requêtes DNS
```

---

## Sommaire

- [Langue : français et anglais](#langue--français-et-anglais)
- [Distributions supportées](#distributions-supportées)
- [Philosophie et ligne rouge](#philosophie-et-ligne-rouge)
- [Les huit composants](#les-huit-composants)
- [Installation](#installation)
- [Manifeste : tous les emplacements](#manifeste--tous-les-emplacements)
- [Savoir où on en est : blocker-status](#savoir-où-on-en-est--blocker-status)
- [Désinstallation](#désinstallation)
- [Vérifier que tout fonctionne](#vérifier-que-tout-fonctionne)
- [Observer l'outil au travail](#observer-loutil-au-travail)
- [Limites connues](#limites-connues)
- [Dépannage](#dépannage)

---

## Langue : français et anglais

Tout ce que l'outil affiche — sorties de commandes, journal, procédure de
désinstallation — existe en **français et en anglais**. La langue est choisie
dans cet ordre :

1. `BLOCKER_LANG` dans `/etc/blocker-adulte/blocker.conf` (`fr`, `en`, `auto`) ;
2. l'environnement : `LC_ALL`, puis `LC_MESSAGES`, puis `LANG` ;
3. la locale du système, lue dans `/etc/locale.conf` ou `/etc/default/locale` ;
4. l'anglais.

L'étape 3 compte plus qu'il n'y paraît : **les services systemd démarrent sans
`LANG`**. Sans elle, le journal parlerait anglais pendant que le terminal parle
français, sur la même machine.

Forcer une langue :

```bash
sudo sed -i 's/^BLOCKER_LANG=.*/BLOCKER_LANG="en"/' /etc/blocker-adulte/blocker.conf
sudo systemctl restart blocker-resolver.service blocker-guard.service
```

Ou pour une seule commande : `BLOCKER_LANG=en sudo -E blocker-status`.

### Comment la traduction est faite

Les deux textes vivent côte à côte dans le code, par une seule fonction :

```sh
blocker_info "$(m "resolveur demarre" "resolver started")"
```

C'est un choix, pas une facilité. Des catalogues à clés, ou gettext, auraient
ajouté une dépendance de construction et le défaut classique : une clé mal
orthographiée n'échoue pas, elle affiche du vide. Avec les deux chaînes sur
place, une traduction manquante se voit en lisant la ligne, et
`tests/test_i18n.sh` détecte mécaniquement un appel incomplet. La contrepartie —
deux langues seulement, une troisième demanderait une réécriture — est assumée.

`blocker-uninstall.sh` redéfinit `m` chez lui, en quelques lignes : la phase 3
supprime `/usr/lib/blocker-adulte`, et la phase 4 s'exécute après. Un
désinstalleur qui dépendrait d'un fichier qu'il vient d'effacer serait cassé au
moment où l'on en a le plus besoin.

### Ce qui reste en français

**La suite de tests.** 442 messages d'assertion de plus auraient triplé la
surface traduite, et cette surface-là est justement celle qui valide tout le
reste : une erreur de transcription y serait la plus coûteuse. `run_all.sh` le
dit en une ligne quand la machine n'est pas en français, plutôt que de mélanger
les deux langues. Les commentaires du code sont également en français.

---

## Distributions supportées

Deux choses sont **obligatoires**, quelle que soit la distribution :

| Exigence | Pourquoi il n'y a pas de contournement |
|---|---|
| **systemd** | Les huit composants reposent sur des unités, des timers et le watchdog systemd. Il n'existe pas d'équivalent portable sous OpenRC ou runit, et en fabriquer un serait un autre projet. |
| **nftables** | Le composant 2 **est** un jeu de règles nftables. iptables-legacy ne sait pas exprimer `meta skuid`, dont dépend l'exemption du résolveur — sans elle, le résolveur se redirige vers lui-même. |

Tout le reste s'adapte. `lib/blocker-os.sh` est le **seul** fichier qui connaît
les différences ; le reste du projet ne parle plus qu'en **rôles** (« le paquet
qui fournit `dig` ») et en **actions** (« reconstruire l'initramfs »).

| Famille | Paquets | Initramfs | Hook de paquet | Éprouvé |
|---|---|---|---|---|
| Debian, Ubuntu, Mint | `apt` | initramfs-tools | triggers dpkg | **Sur machine réelle** (Ubuntu 26.04) |
| Fedora, RHEL, Rocky, Alma | `dnf` / `yum` | dracut | unité path systemd | Couche d'adaptation seulement |
| Arch, Manjaro | `pacman` | mkinitcpio | hook pacman | Couche d'adaptation seulement |
| openSUSE, SLES | `zypper` | dracut | unité path systemd | Couche d'adaptation seulement |
| Alpine | `apk` | — | unité path systemd | Couche d'adaptation seulement |
| Autre | détecté s'il existe | détecté s'il existe | unité path systemd | — |

**Lire la dernière colonne honnêtement.** `tests/test_portabilite.sh` rejoue la
détection avec l'identité de chaque distribution et vérifie les noms de paquets,
les chemins et les commandes retenus. Il ne prouve **pas** qu'une installation
réelle aboutit sur Fedora ou sur Arch : cela ne peut se vérifier que sur la
machine correspondante. Une distribution non reconnue n'est pas refusée — les
composants qu'on ne sait pas configurer sont signalés inactifs, le reste marche.

### Noms de paquets, par rôle

Plutôt qu'une table par version de distribution, l'outil garde une liste de
candidats par rôle et retient le **premier nom que le gestionnaire de paquets
connaît réellement**. C'est ce qui survit aux renommages (`dnsutils` →
`bind9-dnsutils` sur Debian, `bind-tools` → `bind` sur Arch) sans maintenance.

| Rôle | Debian | Fedora / RHEL | Arch | openSUSE | Alpine |
|---|---|---|---|---|---|
| résolveur | `dnsmasq-base` | `dnsmasq` | `dnsmasq` | `dnsmasq` | `dnsmasq` |
| pare-feu | `nftables` | `nftables` | `nftables` | `nftables` | `nftables` |
| stub DNS | `systemd-resolved` | `systemd-resolved` | *(dans systemd)* | `systemd-network` | — |
| audit | `auditd` | `audit` | `audit` | `audit` | `audit` |
| `dig` | `bind9-dnsutils`, `dnsutils` | `bind-utils` | `bind`, `bind-tools` | `bind-utils` | `bind-tools` |
| `chattr` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` |

### Composant 4 : trois générateurs d'initramfs

Les règles nftables sont un **état du noyau**. Chargées depuis l'initramfs,
elles survivent au `switch_root` et restent actives même en mode recovery, où
`nftables.service` n'est pas lancé.

Trois générateurs, un seul comportement. Les trois embarquent les **mêmes deux
fichiers**, produits par les **mêmes deux scripts** ; seuls les points
d'accroche diffèrent :

| Générateur | Hook de construction | Hook de démarrage | Reconstruction |
|---|---|---|---|
| initramfs-tools | `/etc/initramfs-tools/hooks/blocker-adulte` | `scripts/init-bottom/blocker-adulte` | `update-initramfs -u` |
| dracut | `/usr/lib/dracut/modules.d/99blocker-adulte/module-setup.sh` | hook `pre-pivot` | `dracut --force --regenerate-all` |
| mkinitcpio | `/etc/initcpio/install/blocker-adulte` | `/etc/initcpio/hooks/blocker-adulte` (`run_latehook`) | `mkinitcpio -P` |

Les deux points d'entrée de dracut et de mkinitcpio ne contiennent **aucun
`exit`** : leur init les *source*, donc un `exit` arrêterait le démarrage.
`test_portabilite.sh` le vérifie explicitement — c'est le défaut le plus grave
possible à cet endroit.

#### Le cas particulier d'Arch

`mkinitcpio` n'exécute que les hooks listés dans `HOOKS=` de
`/etc/mkinitcpio.conf`. Déposer les fichiers ne suffit pas — mais une ligne
`HOOKS` erronée empêche la machine de démarrer. `blocker-configure` **ne touche
donc pas à ce fichier** sans qu'on le lui demande :

```bash
# /etc/blocker-adulte/blocker.conf
BLOCKER_MKINITCPIO_HOOK="oui"
```

Avec ce réglage, le fichier est sauvegardé dans
`/etc/mkinitcpio.conf.avant-blocker-adulte`, modifié, puis `mkinitcpio -P` est
lancé. **Si la reconstruction échoue, la sauvegarde est restaurée et l'image
reconstruite à partir d'elle.** Le composant 4 se déclare alors inactif plutôt
que de laisser une image non amorçable.

Sans ce réglage, `blocker-status` indique exactement la ligne à ajouter.

### Composant 5 : réaction à la réinstallation d'un navigateur

Seuls dpkg et pacman offrent un point d'accroche par simple dépôt de fichier.
`dnf` et `zypper` demanderaient un greffon Python, hors de proportion ici.
Partout — y compris là où un hook existe — une **unité `path` systemd**
(`blocker-policies.path`) surveille directement les répertoires de policies :
elle réagit en une seconde au lieu de cinq minutes, et couvre en plus les
navigateurs installés par snap ou flatpak, que le gestionnaire de paquets ne
voit pas.

---

## Philosophie et ligne rouge

L'inspiration technique est le modèle *tamper protection* des agents EDR
d'entreprise : des watchdogs qui se surveillent mutuellement, une auto-réparation
périodique, une suppression volontairement multi-étapes. La résistance vient de
la **distribution** et de la **redondance**, jamais d'un combat actif contre
l'utilisateur.

### Ce que l'outil ne fait pas

Ces règles sont tenues dans tout le code, et vérifiées par
`tests/test_no_hidden_files.sh` :

| Interdit | Comment c'est garanti |
|---|---|
| Cacher un processus, un fichier, une entrée dpkg | Aucune manipulation de `/proc`, aucun `LD_PRELOAD`, aucun module noyau. `ps aux`, `lsof`, `dpkg -l` montrent tout sous les vrais noms. |
| Se recopier vers des emplacements non documentés | Le [manifeste](#manifeste--tous-les-emplacements) ci-dessous liste **tous** les emplacements. Le test n°7 cherche activement des copies ailleurs. |
| Contrer une suppression volontaire | Un drapeau de retrait volontaire met les watchdogs en veille dès la première étape de la désinstallation. Voir [ci-dessous](#le-drapeau-de-retrait-volontaire). |
| Toucher au bootloader ou au firmware | Le hook initramfs n'ajoute que des fichiers à l'image initramfs. Aucune référence à GRUB, systemd-boot, `efibootmgr` ou `/sys/firmware` : vérifié par le test n°6 de `test_recovery_mode_hook.sh`. |
| Réparer en silence | Chaque correction automatique est journalisée avec le préfixe `REPARATION:` (ou `REPAIR:` en anglais) dans `journalctl`. |

### Le drapeau de retrait volontaire

C'est le mécanisme qui rend la désinstallation fiable plutôt qu'un bras de fer.

```
/run/blocker-adulte/uninstall-in-progress
```

Ce fichier est créé **en tout premier** par `blocker-uninstall.sh` (et par le
`prerm` du paquet). Tant qu'il existe, `blocker-guard`, `blocker-resolver-run`,
`blocker-selfheal` et le dispatcher NetworkManager cessent immédiatement toute
réparation et le disent dans le journal.

Second déclencheur, indépendant : une unité passée à `systemctl disable` est
elle aussi traitée comme un retrait volontaire. C'est pourquoi la procédure de
désinstallation fait toujours `disable` **avant** `stop`.

L'outil ne cherche donc jamais à deviner si un `rm` est « légitime » : c'est
l'utilisateur qui l'annonce, et l'outil s'écarte.

---

## Les huit composants

| # | Composant | Rôle | Se relève grâce à |
|---|---|---|---|
| 1 | **Résolveur DNS local** | `dnsmasq` sur `127.0.0.1:53`, listes StevenBlack *porn-only* + Hagezi *doh-vpn-proxy-bypass*, **SafeSearch forcé**, amont filtrant en secours | 6, 7 |
| 2 | **Application réseau forcée** | `systemd-resolved` → `127.0.0.1`, DNAT nftables du port 53, rejet DoT/DoQ/DoH, dispatcher NetworkManager | 4, 6, 7 |
| 3 | **Policies navigateur** | Un fichier indépendant par navigateur détecté (Firefox, Chrome, Chromium, Brave) | 5, 6, 7 |
| 4 | **Hook initramfs** | Règles nftables de base chargées avant le montage de la racine, actives en mode recovery | — (regénéré à l'installation) |
| 5 | **Réaction à la réinstallation** | Triggers dpkg, hook pacman, et une unité `path` systemd qui surveille les répertoires de policies | 7 |
| 6 | **Deux services à surveillance croisée** | `blocker-resolver.service` ↔ `blocker-guard.service`, chacun relance l'autre | l'un l'autre, et 7 |
| 7 | **Timer de self-heal** | Passe complète toutes les 5 min : `chattr +i`, policies, règles nftables, services | systemd |
| 8 | **Journalisation auditd** | Trace toute écriture sur les fichiers protégés | — (n'empêche rien, enregistre) |

### 1. Résolveur DNS local

`dnsmasq` écoute sur `127.0.0.1:53`, séparément du stub `systemd-resolved`
(`127.0.0.53:53`) — les deux coexistent sans conflit de port. Il tourne sous
l'utilisateur système `blocker-adulte`, ce qui permet aux règles nftables de le
distinguer du reste du trafic et d'éviter une boucle de redirection.

Les listes sont mises à jour quotidiennement par `blocker-list-update.timer`,
validées par `dnsmasq --test` **avant** d'être mises en place. Une liste
corrompue ne peut donc pas empêcher le résolveur de démarrer — priver la machine
de DNS serait le plus sûr moyen de pousser à tout désinstaller.

`filter-rr=65` bloque les enregistrements HTTPS/SVCB, qui annoncent aux
navigateurs les points d'accès DoH disponibles.

#### SafeSearch forcé — la mesure la plus efficace de l'outil

Une liste de blocage ne peut rien contre **Google Images, YouTube ou Bing** : ce
sont des domaines qu'on ne peut pas bloquer sans rendre la machine inutilisable,
et ils servent pourtant du contenu adulte à la demande. C'est le trou par lequel
passe l'essentiel de ce qu'un filtre DNS classique laisse échapper.

Tous ces moteurs exposent un nom d'hôte « verrouillé en mode strict ». Faire
résoudre `www.google.com` vers l'adresse de `forcesafesearch.google.com` force
donc le SafeSearch **au niveau du réseau** :

- impossible à désactiver depuis les préférences du navigateur ou du compte ;
- valable pour **tous** les navigateurs et toutes les applications d'un coup,
  y compris ceux qui ignorent les policies (`curl`, un client tiers, un profil
  portable) ;
- indépendant du fait d'être connecté ou non à un compte Google.

| Moteur | Redirigé vers | Domaines couverts |
|---|---|---|
| Google | `forcesafesearch.google.com` | `www.google.com` + 38 domaines nationaux |
| YouTube | `restrict.youtube.com` | `www.youtube.com`, `m.youtube.com`, `youtube.com`, les API |
| Bing | `strict.bing.com` | `www.bing.com`, `bing.com`, `cn.bing.com` |
| DuckDuckGo | `safe.duckduckgo.com` | `duckduckgo.com` et ses sous-domaines de recherche |
| Yandex | `familysearch.yandex.ru` | `yandex.com`, `yandex.ru` |

**Les adresses ne sont jamais codées en dur** : `blocker-safesearch` les résout à
chaque mise à jour quotidienne. Si la résolution échoue, le fichier en place est
conservé — jamais de retour silencieux à « pas de SafeSearch ».

**Protection contre la dérive.** Ces adresses appartiennent aux moteurs et
peuvent changer sans préavis. Une adresse périmée ne dégraderait pas le
filtrage : elle **casserait Google Search** pour toute la machine jusqu'à la
mise à jour suivante — précisément le genre de panne qui fait tout désinstaller.
Le self-heal sonde donc l'hôte témoin `forcesafesearch.google.com` dès que le
fichier a plus de 6 heures, et régénère immédiatement en cas d'écart. La sonde
n'a pas lieu à chaque passe : une requête DNS toutes les 5 minutes pour rien
serait du gaspillage.

**Critère d'admission d'une entrée.** Un moteur n'a sa place dans la table que
s'il publie un hôte dédié appliquant le filtrage d'après l'**adresse** jointe,
indépendamment de l'en-tête `Host`. Un mécanisme par cookie ou paramètre d'URL
(`?safesearch=true`) est hors de portée du DNS : rediriger dans ce cas ne filtre
rien **et risque de casser le site**. `tests/test_safesearch.sh` vérifie
automatiquement, pour chaque entrée, que l'adresse stricte diffère de l'adresse
normale du domaine ciblé — une entrée qui échoue fait échouer la suite.

*Pixabay a été retiré pour cette raison* : son SafeSearch documenté passe par un
cookie, et rien n'établit que `safesearch.pixabay.com` serve le site. Le détail
du raisonnement est en commentaire dans `bin/blocker-safesearch`.

**Ce qui n'est délibérément pas touché.** Seuls les hôtes de recherche sont
redirigés, jamais un domaine nu. Rediriger `google.com` s'appliquerait à *tous*
ses sous-domaines et casserait Gmail, Drive, Agenda et l'authentification.
`tests/test_safesearch.sh` vérifie explicitement que ces six services répondent
normalement.

Désactivable par `BLOCKER_SAFESEARCH="non"` dans `/etc/blocker-adulte/blocker.conf`.

Vérification :

```bash
sudo blocker-status --sonde
dig +short @127.0.0.1 www.google.com    # doit donner l'IP de forcesafesearch
```

Un détail qui compte : après régénération du fichier, un `SIGHUP` **ne suffit
pas**. dnsmasq relit ses fichiers `hosts` sur `HUP`, mais pas les directives
`address=` d'un `conf-dir`. Il faut un vrai
`systemctl restart blocker-resolver.service` — ce que fait la mise à jour.

### 2. Application réseau forcée

Trois barrières superposées :

- **`systemd-resolved`** : `DNS=127.0.0.1`, `Domains=~.`, `FallbackDNS=` vide.
  Aucun serveur poussé par le DHCP ou un VPN ne peut reprendre la main.
- **nftables** : tout trafic sortant vers le port 53 est réécrit en DNAT vers
  `127.0.0.1:53`. Configurer « DNS = 8.8.8.8 » à la main ne change rien.
- **Dispatcher NetworkManager** : `90-blocker-adulte` réapplique la
  configuration à chaque changement de réseau (Wi-Fi, VPN, DHCP).

**Note technique — pourquoi DoT n'est pas redirigé.** Le port 853 est *rejeté*,
pas redirigé. Rediriger une connexion TLS vers un résolveur en clair produirait
une poignée de main invalide et un échec silencieux, très pénible à
diagnostiquer. Un rejet TCP franc fait basculer le client sur le DNS classique
en quelques millisecondes. Même raisonnement pour DoQ (784, 8853) et pour DoH,
bloqué par les IP d'amorçage des principaux fournisseurs (jeux `doh_ipv4` /
`doh_ipv6`) et par leurs noms côté résolveur.

Les tables portent un nom propre (`blocker_adulte*`) et le fichier ne contient
**aucun `flush ruleset`** : les règles Docker, libvirt ou UFW existantes sont
intactes.

### 3. Policies navigateur

Détection à l'installation, puis un fichier par navigateur — indépendants les
uns des autres, retirer un navigateur n'affecte pas les policies des autres.

| Navigateur | Fichier | Effets principaux |
|---|---|---|
| Firefox | `/etc/firefox/policies/policies.json` | `DNSOverHTTPS.Enabled=false` + `Locked=true`, `network.trr.mode=5` verrouillé, `DisablePrivateBrowsing`, `BlockAboutConfig` |
| Chrome | `/etc/opt/chrome/policies/managed/blocker-adulte.json` | `DnsOverHttpsMode=off`, `QuicAllowed=false`, `SafeSitesFilterBehavior`, navigation privée désactivée |
| Chromium | `/etc/chromium/policies/managed/` **et** `/etc/opt/chromium/policies/managed/` | idem — les deux emplacements sont écrits, la disposition varie selon l'origine du paquet |
| Brave | `/etc/brave/policies/managed/blocker-adulte.json` | idem + `TorDisabled`, `BraveVPNDisabled` (qui contourneraient entièrement le résolveur) |

Chaque fichier contient une clé `_comment` de documentation. Chrome et dérivés
la signaleront comme « policy inconnue » dans `chrome://policy` : c'est attendu
et sans effet.

### 4. Hook initramfs

Les règles nftables sont un **état du noyau** : chargées depuis l'initramfs,
elles survivent au `switch_root` et restent actives même en mode
recovery / single-user, où `nftables.service` et les watchdogs ne tournent pas.

Deux fichiers :

- `/etc/initramfs-tools/hooks/blocker-adulte` — s'exécute lors de
  `update-initramfs -u`, embarque `nft`, les modules netfilter et un jeu de
  règles de base ;
- `/etc/initramfs-tools/scripts/init-bottom/blocker-adulte` — s'exécute au
  démarrage et charge ces règles.

Le jeu de règles embarqué est une **variante** de celui du système complet :
l'UID de `blocker-adulte` y est inscrit en dur, la base utilisateurs n'existant
pas dans l'initramfs. Si cet UID change, relancer `update-initramfs -u` — sinon
le résolveur se redirigerait vers lui-même au prochain démarrage.
`test_recovery_mode_hook.sh` vérifie précisément cette cohérence.

### 5. Hooks dpkg/apt

`debian/triggers` déclare des triggers de fichier sur les chemins
d'installation des navigateurs. Quand `apt reinstall firefox` remplace des
fichiers sous `/usr/lib/firefox`, dpkg rappelle notre `postinst` en mode
`triggered`, qui redéploie les policies.

**Limite honnête** : sur Ubuntu 22.04+, Firefox et Chromium sont livrés en
**snap** et ne passent pas par dpkg. Aucun trigger ne peut donc se déclencher
sur leur mise à jour. Ces navigateurs sont couverts par le composant 7, qui
repasse toutes les 5 minutes.

### 6. Deux services à surveillance croisée

```
blocker-resolver.service  ──surveille──▶  blocker-guard.service
        ▲                                          │
        └──────────────surveille───────────────────┘
```

Chacun vérifie l'autre toutes les 15 secondes et le relance s'il est arrêté.
Les deux ont `Restart=always` et `WatchdogSec=60s`. `blocker-guard` vérifie en
plus que le résolveur **répond réellement** à une requête, et pas seulement que
son processus existe.

Arrêter un seul des deux ne sert donc à rien : il repart en quelques secondes,
et l'événement apparaît dans `journalctl`. Les arrêter **tous les deux** en même
temps fonctionne — jusqu'à la prochaine passe du composant 7, cinq minutes plus
tard au maximum.

### 7. Timer de self-heal

`blocker-selfheal.timer` déclenche une passe complète toutes les 5 minutes :
`chattr +i` réappliqué, quatre répertoires de policies revérifiés, règles
nftables actives comparées aux règles attendues, ligne d'inclusion dans
`/etc/nftables.conf`, présence des deux services et des hooks initramfs.

Chaque écart est journalisé **avec son détail** avant d'être corrigé. Un
compte-rendu est écrit à chaque passe, même quand rien n'a bougé : un watchdog
muet est indiscernable d'un watchdog mort.

Le self-heal ne relance **pas** `update-initramfs` tout seul (ce serait de
l'usure disque inutile toutes les 5 minutes) : il signale l'écart, la correction
est manuelle.

### 8. Journalisation auditd

`auditd` trace toute écriture, suppression ou changement d'attribut sur les
fichiers protégés. Ces règles **n'empêchent rien** : elles enregistrent.

```bash
ausearch -k blocker-adulte -i --start today
ausearch -k blocker-adulte-policies -i
journalctl _TRANSPORT=audit | grep blocker-adulte
```

Dans `-p wa`, le `a` couvre déjà les changements d'attribut : un `chattr -i` sur
un fichier surveillé est donc journalisé sans règle supplémentaire. Aucune règle
sur `ioctl` en général n'est posée — le volume rendrait le journal inexploitable.

---

## Installation

### En trois commandes

Testé sur Ubuntu 24.04 et 26.04.

```bash
git clone https://github.com/PatrickChoumi/safezone.git
cd safezone
sudo ./install.sh
```

`install.sh` détecte la distribution, installe les dépendances manquantes avec
le bon gestionnaire de paquets (voir
[Noms de paquets, par rôle](#noms-de-paquets-par-rôle)), pose les fichiers,
active les huit composants et lance la première mise à jour des listes.
Comptez deux à trois minutes, dont `update-initramfs`.

Puis vérifiez :

```bash
sudo blocker-status --sonde     # les contournements sont-ils vraiment bloqués ?
sudo tests/run_all.sh --tout    # la suite complète, watchdogs inclus
```

`--tout` inclut le test de surveillance croisée, qui **arrête réellement les
services** et coupe le DNS quelques secondes. C'est le seul critère que je n'ai
jamais pu vérifier moi-même : le conteneur de développement n'a pas systemd en
PID 1. Lancez-le au moins une fois.

**Avant de commencer**, si vous voulez voir ce qui va se passer sans rien
changer :

```bash
sudo ./install.sh --dry-run
```

**Redémarrez ensuite une fois** : c'est ce qui active le hook initramfs
(composant 4) et confirme que tout revient bien en place au boot.

### Mettre à jour

```bash
sudo blocker-update --verifier   # y a-t-il du nouveau ? n'installe rien
sudo blocker-update              # affiche les changements, puis demande confirmation
```

L'emplacement du dépôt est mémorisé à l'installation dans
`/etc/blocker-adulte/source` : rien à retenir. S'il manque (installation par
`.deb`, dépôt déplacé), l'indiquer une fois avec `--source /chemin` et il sera
retenu.

**La mise à jour n'est pas automatique, et aucun timer ne la déclenche.**
Appliquer sans regarder du code venu d'internet, sur une machine où il tournera
en root, est une mauvaise idée — même quand le dépôt est le vôtre. La commande
affiche donc toujours les commits et les fichiers touchés avant de demander
confirmation. La détection peut être automatique ; l'application reste un geste
conscient.

Quatre garde-fous, chacun vérifié :

| Situation | Comportement |
|---|---|
| Modifications locales non validées | **Refus** — la mise à jour les écraserait. Les commandes pour s'en sortir sont affichées |
| Le code reçu ne passe pas `make check` | **Arrêt avant installation.** Une erreur de syntaxe dans un watchdog laisserait la machine sans protection ; le système reste sur la version précédente |
| Historiques divergents | **Arrêt** — pas de fusion à l'aveugle |
| Dépôt local en avance | Le dit, suggère `git push`, n'installe rien |

La commande de retour arrière est affichée à la fin de chaque mise à jour.
Une passe de self-heal est forcée après coup, les modèles ayant pu changer.

### Prérequis

Ubuntu 20.04 ou plus récent (ou une Debian équivalente), avec systemd. Système
de fichiers racine ext4, xfs ou btrfs pour que `chattr +i` fonctionne.

### Voie 1 — directement depuis le dépôt

```bash
git clone <url-du-depot> blocker-adulte
cd blocker-adulte

sudo ./install.sh --dry-run    # voir ce qui serait fait
sudo ./install.sh              # installer
```

### Voie 2 — paquet .deb (active le composant 5)

```bash
sudo apt install build-essential debhelper devscripts
make deb
sudo apt install ../blocker-adulte_1.0.0_all.deb
```

Les deux voies appellent le même `blocker-configure` et produisent la même
arborescence. Le `.deb` ajoute les triggers dpkg — sans lui, le composant 5 est
inactif et les policies ne sont réappliquées que par le self-heal.

### Après l'installation

```bash
sudo systemctl start blocker-list-update.service   # premières listes complètes
sudo tests/run_all.sh                              # vérifier
```

Jusqu'à cette première mise à jour, le blocage adulte repose uniquement sur le
résolveur amont filtrant (Cloudflare for Families) : la liste livrée avec le
paquet ne contient que des domaines de contournement (DoH, VPN, proxys), pas
d'énumération de sites adultes — un dépôt git n'est pas le bon endroit pour ça.

### Réglages

Tout se passe dans `/etc/blocker-adulte/blocker.conf` : résolveurs amont,
intervalle des watchdogs, URL des listes. Ce fichier n'est jamais écrasé par une
mise à jour et n'est pas rendu immuable.

---

## Manifeste : tous les emplacements

**Tout** ce que le projet pose sur le disque figure ci-dessous. Cette liste est
lue automatiquement par `tests/test_no_hidden_files.sh`, qui la compare au
résultat de `find / -name '*blocker-adulte*'` et **échoue** si un fichier
existe sans être déclaré ici.

<!-- MANIFEST-DEBUT -->
```text
# --- Exécutables et bibliothèque partagée ---
/usr/lib/blocker-adulte/blocker-common.sh
/usr/lib/blocker-adulte/blocker-os.sh
/usr/lib/blocker-adulte/blocker-i18n.sh
/usr/lib/blocker-adulte/blocker-base-rules
/usr/lib/blocker-adulte/blocker-configure
/usr/lib/blocker-adulte/blocker-guard
/usr/lib/blocker-adulte/blocker-resolver-run
/usr/lib/blocker-adulte/blocker-selfheal
/usr/lib/blocker-adulte/blocker-list-update
/usr/lib/blocker-adulte/blocker-safesearch
/usr/lib/blocker-adulte/blocker-upstream
/usr/lib/blocker-adulte/blocker-doh-refresh
/usr/lib/blocker-adulte/blocker-apply-policies
/usr/lib/blocker-adulte/blocker-apply-nftables
/usr/sbin/blocker-uninstall
/usr/sbin/blocker-status
/usr/sbin/blocker-update
/usr/sbin/blocker-block

# --- Modèles, listes, tests, documentation ---
/usr/share/blocker-adulte
/usr/share/doc/blocker-adulte

# --- Unités systemd ---
# Le répertoire dépend de la distribution : /usr/lib/systemd/system sur toute
# distribution usr-merge (toutes les récentes), /lib/systemd/system sur les
# plus anciennes. Les deux chemins désignent le même fichier là où /lib est un
# lien ; le test accepte l'un ou l'autre.
/usr/lib/systemd/system/blocker-resolver.service
/usr/lib/systemd/system/blocker-guard.service
/usr/lib/systemd/system/blocker-selfheal.service
/usr/lib/systemd/system/blocker-selfheal.timer
/usr/lib/systemd/system/blocker-list-update.service
/usr/lib/systemd/system/blocker-list-update.timer
/usr/lib/systemd/system/blocker-policies.path
/usr/lib/systemd/system/blocker-policies.service

# --- Configuration ---
/etc/blocker-adulte
/etc/dnsmasq.d/blocker-adulte.conf
/etc/nftables/blocker-adulte.nft
/etc/nftables/blocker-adulte-tunnels.nft
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
/etc/audit/rules.d/blocker-adulte.rules

# --- Hooks initramfs (un seul jeu selon le générateur de la distribution) ---
# initramfs-tools : Debian, Ubuntu
/etc/initramfs-tools/hooks/blocker-adulte
/etc/initramfs-tools/scripts/init-bottom/blocker-adulte
# dracut : Fedora, RHEL, openSUSE
/usr/lib/dracut/modules.d/99blocker-adulte
# mkinitcpio : Arch
/etc/initcpio/install/blocker-adulte
/etc/initcpio/hooks/blocker-adulte

# --- Hook du gestionnaire de paquets (Arch uniquement) ---
/etc/pacman.d/hooks/95-blocker-adulte.hook

# --- Policies navigateur (présentes seulement si le navigateur l'est) ---
/etc/firefox/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json

# --- État et exécution ---
/var/lib/blocker-adulte
/run/blocker-adulte
```
<!-- MANIFEST-FIN -->

### Modifications apportées à des fichiers existants

Deux fichiers qui ne nous appartiennent pas sont touchés — ils ne peuvent pas
être simplement supprimés à la désinstallation :

| Fichier | Modification | Retrait |
|---|---|---|
| `/etc/nftables.conf` | Ajout d'une ligne `include "/etc/nftables/blocker-adulte.nft"` | Étape 7 de la désinstallation (une sauvegarde `.avant-blocker-adulte` est créée) |
| `/etc/hosts` | **Contenu jamais modifié.** Seul l'attribut d'immuabilité est posé, et seulement si `BLOCKER_LOCK_HOSTS` le permet (voir ci-dessous) | Étape 3 : `sudo chattr -i /etc/hosts` |
| Service `dnsmasq` de la distribution | Désactivé s'il était actif, pour éviter un conflit sur le port 53 | `sudo systemctl enable --now dnsmasq` |

#### Le cas `/etc/hosts`

Une seule ligne dans `/etc/hosts` contourne **entièrement** le résolveur : la
résolution système (NSS) lit ce fichier avant d'interroger le DNS, et
`no-hosts` côté dnsmasq n'y change rien puisque c'est la glibc qui le lit.
C'est le contournement le plus simple qui existe contre un filtrage DNS.

Le rendre immuable ferme ce trou, mais `/etc/hosts` appartient au système et
d'autres logiciels l'écrivent légitimement. Réglage dans
`/etc/blocker-adulte/blocker.conf` :

| `BLOCKER_LOCK_HOSTS` | Comportement |
|---|---|
| `auto` *(défaut)* | Verrouille, **sauf** si Docker, podman, LXC, Vagrant ou cloud-init est détecté. L'abstention est écrite dans le journal à chaque passe de self-heal — elle n'est jamais silencieuse. |
| `oui` | Verrouille toujours. Peut casser Docker et consorts. |
| `non` | Ne verrouille jamais. Le fichier reste surveillé par auditd (composant 8). |

Le contenu du fichier n'est jamais réécrit : l'outil ne pose et ne retire qu'un
attribut.

### Ce qui n'existe nulle part

Vérifié par `test_no_hidden_files.sh` : aucune entrée dans `cron`,
`/etc/rc.local`, `/etc/profile.d`, `/usr/local/bin`, `/usr/local/sbin`,
`/etc/systemd/user`, aucun `LD_PRELOAD`, aucun module noyau, aucune copie des
exécutables hors de `/usr/lib/blocker-adulte`.

### Éléments hors manifeste, créés par le système

Ces fichiers portent notre nom mais sont générés par systemd ou dpkg à partir de
ce que nous installons. Le test les tolère explicitement :

```
/etc/systemd/system/multi-user.target.wants/blocker-*.service
/etc/systemd/system/timers.target.wants/blocker-*.timer
/var/lib/dpkg/info/blocker-adulte.*
/etc/nftables.conf.avant-blocker-adulte     (sauvegarde de désinstallation)
```

---

## Savoir où on en est : blocker-status

Un outil de ce genre qui n'afficherait que ses réussites donnerait une fausse
assurance — pire que pas d'outil du tout. `blocker-status` répond en une commande
à « est-ce que ça marche, là, maintenant ? », **et dit ce qui ne protège pas**.

```bash
blocker-status            # rapport complet, lisible sans être root
blocker-status --sonde    # teste en direct des domaines réels
blocker-status --trous    # uniquement ce qui ne protège pas
```

Le rapport donne l'état des huit composants, l'état du SafeSearch vérifié **par
une résolution réelle** (pas seulement par la présence du fichier), le nombre de
domaines en liste, l'âge des listes, les réparations des dernières 24 h, et deux
sections franches :

- **« Ce qui ne protège pas »** : composant arrêté, listes périmées, `/etc/hosts`
  non verrouillé, auditd qui ne collecte rien, policies incomplètes — avec la
  commande exacte pour corriger.
- **« Limites permanentes »** : ce qui ne disparaîtra jamais, par conception.

Le code de sortie vaut `0` si tout est opérationnel ou dégradé, `1` si un
composant est hors service — utilisable dans un script de vérification.

`--sonde` est le contrôle le plus parlant : il interroge réellement le résolveur
sur des domaines de contournement (doivent être bloqués), sur les moteurs de
recherche (doivent être en mode strict) et sur des services légitimes (ne doivent
**pas** être cassés).

---

## Désinstallation

### Il n'y a pas de commande unique

C'est le point central de la conception, et il est délibéré : **aucune commande
ne retire tout**. Le retrait se fait en quatre phases, chacune demandant deux
commandes — une pour voir ce qu'elle fera et obtenir un jeton, une pour
l'exécuter avec ce jeton. Huit commandes au total, et il faut lire l'écran à
chaque fois puisque **le jeton est tiré au hasard à chaque affichage** : aucun
script préparé à l'avance ne peut enchaîner les phases.

```bash
sudo blocker-uninstall --etat       # où en est-on
sudo blocker-uninstall --phase 1    # ce que la phase fera + son jeton
sudo blocker-uninstall --phase 1 --jeton A7K2M9
```

### Ce que ce découpage n'est pas

| Ce n'est pas… | Pourquoi |
|---|---|
| **une minuterie** | Aucune phase ne fait attendre. Qui veut aller au bout y va tout de suite — il faut simplement le vouloir huit fois de suite. |
| **un piège** | Les quatre phases fonctionnent jusqu'au retrait complet, et `--manuel` affiche la procédure équivalente qui n'utilise pas ce script du tout. |
| **un état caché** | L'avancement est **déduit de l'état réel du système**, pas d'un fichier compteur. Redémarrer, sauter une phase ou en refaire une déjà faite ne peut pas coincer la désinstallation. |

`tests/test_uninstall_phases.sh` vérifie les deux moitiés de cette promesse : que
c'est pénible (pas de raccourci, ordre imposé, jeton non rejouable) **et** que ce
n'est pas un piège (procédure manuelle complète, aucun fichier compteur).

### Les quatre phases

| Phase | Ce qu'elle fait | Effet visible |
|---|---|---|
| **1** | Pose le drapeau de retrait, désactive puis arrête `blocker-guard` **d'abord** (c'est elle qui relance le résolveur), puis `blocker-resolver`, puis les deux timers | Le filtrage s'arrête. Les règles nftables pointent encore vers un résolveur éteint : **la résolution DNS est cassée jusqu'à la phase 4.** C'est normal et temporaire. |
| **2** | `chattr -i` sur chaque fichier protégé | Sans elle, ni `apt` ni `rm` ne peuvent supprimer ces fichiers |
| **3** | `apt purge` (ou suppression manuelle), les 4 policies navigateur, les liens d'activation systemd pendants | Le paquet et les policies disparaissent |
| **4** | Hook initramfs + `update-initramfs -u`, tables nftables chargées en mémoire, ligne d'inclusion, règles auditd, utilisateur système | **La résolution DNS redevient normale** |

La phase 1 casse volontairement le DNS jusqu'à la phase 4. C'est la conséquence
directe du fait que les règles nftables sont un état du noyau qui survit à
l'arrêt du résolveur — et c'est annoncé à l'écran avant d'exécuter la phase.
Une désinstallation abandonnée en cours de route se rattrape soit en allant au
bout, soit en relançant les services :

```bash
sudo systemctl enable --now blocker-resolver.service blocker-guard.service
sudo rm -f /run/blocker-adulte/uninstall-in-progress
```

### La procédure manuelle

Le script n'est pas indispensable. La commande suivante affiche la suite exacte
de commandes qui fait la même chose, sans jamais passer par lui :

```bash
sudo blocker-uninstall --manuel
```

Elle couvre les quatre phases : `chattr -i` sur chaque fichier listé, `apt purge`
ou la suppression manuelle, les policies navigateur, le retrait du hook
initramfs suivi de `update-initramfs -u`, les cinq tables nftables à décharger,
la ligne d'inclusion de `/etc/nftables.conf`, les règles auditd, les liens
d'activation systemd et l'utilisateur système.

### Purge directe par apt

`sudo apt purge blocker-adulte` sans passer par `blocker-uninstall` reste
possible et **ne casse pas la machine** : le `prerm` pose le drapeau de retrait,
arrête les watchdogs dans le bon ordre et lève l'immuabilité ; le `postrm`
décharge les tables nftables et régénère l'initramfs. Il restera à retirer à la
main les policies navigateur, qu'`apt` ne possède pas.

### Vérifier que le système est propre

```bash
sudo blocker-uninstall --etat                            # doit tout cocher
sudo find / -xdev -name '*blocker-adulte*' 2>/dev/null   # rien
systemctl list-units --all 'blocker-*'                   # rien
sudo nft list ruleset | grep blocker                     # rien
dpkg -l | grep blocker                                   # rien
resolvectl status                                        # DNS d'origine revenu
```

Un fichier est laissé volontairement : `/etc/nftables.conf.avant-blocker-adulte`,
la sauvegarde faite avant de retirer la ligne d'inclusion. À supprimer une fois
le fichier courant vérifié.

## Vérifier que tout fonctionne

```bash
sudo tests/run_all.sh          # tous les tests non intrusifs
sudo tests/run_all.sh --tout   # y compris l'arrêt réel des services
```

| Test | Critère d'acceptation vérifié |
|---|---|
| `test_dns_leak.sh` | Aucune requête DNS ne sort hors du résolveur local |
| `test_doh_blocked.sh` | DoH, DoT et DoQ sont bloqués, policies navigateur cohérentes |
| `test_watchdog_cross_restart.sh` | n°1 — relance croisée en moins d'une minute, **et** respect du drapeau de retrait |
| `test_browser_reinstall.sh` | n°2 — la policy revient après une réinstallation de navigateur |
| `test_recovery_mode_hook.sh` | n°3 — l'image initramfs contient bien règles, binaire et modules |
| `test_no_hidden_files.sh` | n°4 et n°6 — manifeste complet, rien de caché |
| `test_portabilite.sh` | la couche d'adaptation est juste pour chaque famille supportée |
| `test_i18n.sh` | les deux langues, aucun appel de traduction incomplet |
| `test_safesearch.sh` | SafeSearch effectif **et** Gmail/Drive/Agenda non cassés |
| `test_uninstall_phases.sh` | Retrait pénible (pas de raccourci, jeton non rejouable) **et** sans piège |

Codes de sortie : `0` conforme, `1` échec, `77` test ignoré (prérequis absent).

Les tests savent où ils tournent. Sans systemd en PID 1 (conteneur, chroot,
image en construction), `test_watchdog_cross_restart.sh` s'ignore proprement et
les contrôles de service se rabattent sur le processus, au lieu d'échouer à
tort.

`make check` complète la suite par une analyse statique : `bash -n` / `sh -n` sur
les 22 scripts, `shellcheck -x` en niveau *warning*, et validation JSON des quatre
fichiers de policies. Un avertissement shellcheck fait échouer la cible.

`test_watchdog_cross_restart.sh` arrête réellement des services : le DNS est
interrompu quelques secondes.

### Vérification manuelle du mode recovery (critère n°3)

Le test ne peut pas redémarrer la machine. Pour la vérification complète :

1. Redémarrer, maintenir <kbd>Shift</kbd> (ou <kbd>Échap</kbd>) pour le menu GRUB.
2. *Advanced options* → l'entrée `(recovery mode)`.
3. Choisir `root` — *Drop to root shell prompt*.
4. Puis :

```bash
nft list table ip blocker_adulte_base_nat
```

La chaîne `output` avec sa règle `dport 53 → redirect` doit être présente.

---

## Observer l'outil au travail

Toutes les réparations automatiques sont visibles en clair :

```bash
# En direct
journalctl -f -u blocker-guard -u blocker-selfheal -u blocker-resolver

# Uniquement les réparations
journalctl -u blocker-guard -u blocker-selfheal --since today | grep 'REPARATION'

# Historique du self-heal
systemctl list-timers 'blocker-*'
journalctl -u blocker-selfheal --since '24 hours ago'

# Tentatives de modification des fichiers protégés
sudo ausearch -k blocker-adulte -i --start today
```

État général :

```bash
systemctl status blocker-resolver blocker-guard
sudo nft list table inet blocker_adulte
resolvectl status
sudo ss -ulpn | grep :53
```

---

## Limites connues

Elles sont réelles et assumées : l'outil est un dispositif de friction, pas une
mesure de sécurité contre un adversaire déterminé disposant du mot de passe root.

### Contournements réellement testés

Le tableau ci-dessous rend compte de tentatives de contournement effectivement
exécutées contre une installation complète, pas d'une analyse théorique.

| Tentative | Résultat | Pourquoi |
|---|---|---|
| Changer `/etc/resolv.conf` vers 9.9.9.9 | **Bloqué** | Le DNAT réécrit la destination quel que soit le serveur configuré |
| `dig @8.8.8.8`, `@9.9.9.9`, `@208.67.222.222` | **Bloqué** | Toutes les réponses viennent du résolveur local (`version.bind` renvoie `dnsmasq`) |
| DNS-over-TLS (853) vers Cloudflare, Google, Quad9 | **Bloqué** | Rejet TCP franc |
| DoH vers `dns.google`, `cloudflare-dns.com`, `quad9` | **Bloqué** | IP d'amorçage refusées + noms filtrés |
| Enregistrements HTTPS/SVCB (bascule auto vers DoH) | **Bloqué** | `filter-rr=65` |
| DNS sur ports alternatifs 5353, 5300, 5053, 8053, 1053, 5453 | **Bloqué** *(depuis la correction)* | Ports ajoutés au DNAT, hors réseau local |
| Ligne ajoutée dans `/etc/hosts` | **Passe**, sauf si `BLOCKER_LOCK_HOSTS` verrouille | NSS lit le fichier avant le DNS |
| DNS sur un port totalement arbitraire (5555, 9953…) | **Passe** | Seuls les ports DNS connus sont redirigés |
| DoH vers une IP non listée dans `doh_ipv4` | **Passe** | Indistinguable d'un HTTPS ordinaire |
| Accès direct par adresse IP, sans DNS | **Passe** | Limite structurelle de tout filtrage DNS |

Les quatre dernières lignes sont les vraies portes de sortie. Elles demandent
toutes de savoir précisément quoi faire — ce qui est exactement le niveau de
friction visé : pénible et délibéré, pas impossible.

### Le contenu à l'intérieur des plateformes généralistes

C'est la limite la plus proche de l'objectif réel, et la plus honnête à
énoncer : **le filtrage DNS ne peut rien** contre un subreddit, un compte X ou
un blog Tumblr. Ces domaines ne peuvent pas être bloqués sans casser un usage
légitime, et dériver depuis un onglet déjà ouvert est bien plus proche du geste
impulsif que reconfigurer un VPN.

Ce que l'outil fait déjà, partiellement :

| Navigateur | Filtrage au niveau URL |
|---|---|
| Chrome, Chromium, Brave | `SafeSitesFilterBehavior: 1` — filtre les URL adultes, y compris sur des plateformes généralistes |
| Firefox | **Aucun équivalent.** Mozilla ne fournit pas de policy comparable |

Ce que vous pouvez faire, si l'une de ces plateformes est un point de
vulnérabilité pour vous :

```bash
sudo blocker-block reddit.com        # bloque le domaine et ses sous-domaines
sudo blocker-block --liste           # voir votre liste
sudo blocker-block --retirer reddit.com
```

La liste vit dans `/var/lib/blocker-adulte/blocklists/50-perso.conf` et n'est
jamais écrasée par la mise à jour des listes ni par le self-heal. Le retrait
demande une simple confirmation : ce sont **vos** blocages, la friction des
quatre phases protège l'outil, pas une liste que vous tenez à la main.

Les front-ends alternatifs (`libreddit`, `teddit`, `redlib`…) sont des domaines
dédiés, donc blocables individuellement de la même façon.

### Ce qui reste ouvert, par ordre de facilité

Classé par ce qu'il en coûte réellement de l'emprunter — c'est la seule façon
honnête de présenter la chose.

| Contournement | Difficulté | Traité ? |
|---|---|---|
| Extension VPN/proxy de navigateur | Aucune compétence, aucun droit root | **Fermé** : permission `proxy` refusée (Chrome/Chromium/Brave), installation d'extensions interdite (Firefox) |
| Tor Browser (portable, sans installation) | Quelques minutes, aucun root | **Fermé au démarrage** : les 10 autorités d'annuaire sont bloquées, le bootstrap échoue. Contournable par bridges obfs4, à demander et saisir à la main |
| VPN système en configuration par défaut | Quelques minutes, root requis | **Fermé** : WireGuard 51820, OpenVPN 1194, IPsec 500/4500 + ESP/AH, L2TP, PPTP + GRE, proxys SOCKS/HTTP |
| VPN délibérément placé sur le port 443 | Compétence réelle | **Ouvert** — indiscernable d'une connexion HTTPS |
| Autre appareil (téléphone, partage 4G) | Immédiat | **Hors de portée** par nature |
| Live USB / autre système | Quelques minutes | **Hors périmètre** assumé (bootloader jamais touché) |
| Endpoint DoH privé sur IP inconnue | Compétence technique réelle | **Ouvert** |
| Accès direct par adresse IP | Compétence technique réelle | **Ouvert** — limite de tout filtrage DNS |

**Comment Tor est fermé.** Tor Browser est portable — il se télécharge, s'extrait
et se lance sans aucun droit root. Son point faible : pour démarrer, il doit
joindre l'une des dix autorités d'annuaire, dont les adresses sont **fixes,
publiques et codées en dur dans le logiciel lui-même**. Bloquées, le bootstrap
échoue et le navigateur reste sur « Établissement d'une connexion ». Il reste les
bridges obfs4, qu'il faut demander à Tor puis saisir à la main : c'est exactement
la démarche délibérée que l'outil n'a pas vocation à empêcher.

**Ce que le blocage VPN fait et ne fait pas.** Il ne bloque pas « les VPN » au
sens général — ce serait impossible sans refuser tout le trafic sortant, ce qui
rendrait la machine inutilisable. Il ferme les **configurations par défaut**, qui
couvrent la quasi-totalité des cas où l'on installe un client en trois clics. Un
tunnel délibérément placé sur le port 443 en TCP reste indiscernable d'une
connexion HTTPS et passera.

Les réseaux privés (`10/8`, `172.16/12`, `192.168/16`) sont épargnés : un VPN vers
la box ou une machine de la maison n'est pas un contournement. Si vous avez besoin
d'un VPN d'entreprise, `BLOCKER_BLOCK_TUNNELS="non"` désactive toute cette table
sans toucher au reste.

**Le fond du problème.** Ce système filtre au niveau réseau et DNS *de cette
machine*. Tout ce qui contourne ce niveau — chiffrement de bout en bout vers un
tiers, autre appareil, autre système — lui échappe par construction. Aucune
itération ne changera cela sans sortir du périmètre « un outil sur une seule
machine ». C'est une friction contre l'impulsion, pas une barrière contre une
décision délibérée de cinq minutes.

### Limites structurelles

- **Un accès root suffit.** N'importe laquelle des quatre phases peut être faite à
  la main. C'est voulu — c'est même le critère n°5. La friction vient du nombre
  d'endroits à connaître, pas d'une impossibilité technique.
- **auditd exige que l'audit soit actif au démarrage.** Sur certaines
  installations, le sous-système d'audit du noyau démarre désactivé : les 27
  règles se chargent (`auditctl -l` les liste) mais aucun événement n'est
  collecté. L'activer demande d'ajouter `audit=1` à la ligne de commande du
  noyau, donc de modifier GRUB — ce que cet outil ne fera **jamais** (hors
  périmètre explicite). À faire à la main si le composant 8 vous importe.
  Vérification : `auditctl -s` doit afficher `enabled 1` et un `pid` non nul.
- **Un live USB ou un autre système contourne tout.** Rien n'est fait à ce sujet :
  toucher au bootloader ou au firmware est explicitement hors périmètre.
- **DNS IPv6 en clair est abandonné, pas redirigé.** Le résolveur local n'écoute
  qu'en IPv4. Les requêtes DNS IPv6 vers le port 53 sont supprimées, ce qui fait
  basculer le client sur IPv4 où la redirection s'applique. Aucune fuite, mais
  une résolution légèrement plus lente sur certains réseaux IPv6.
- **Le DoH intégré à une application n'est pas toujours bloquable.** Les jeux
  `doh_ipv4`/`doh_ipv6` couvrent les fournisseurs publics connus. Une application
  parlant à un point d'accès DoH privé, sur une IP quelconque en 443, passerait.
  Le blocage n'est complet que pour les canaux documentés.
- **Les navigateurs en snap échappent aux triggers dpkg** (composant 5) et ne
  sont couverts que par le self-heal, avec jusqu'à 5 minutes de décalage. Les
  snaps Firefox et Chromium livrés depuis 2023 lisent bien `/etc/firefox/policies`
  et `/etc/chromium/policies` ; les versions plus anciennes les ignorent
  silencieusement — vérifier `about:policies` après le premier lancement.
- **`chattr +i` demande ext4, xfs ou btrfs.** Sur un autre système de fichiers,
  l'immuabilité est ignorée avec un avertissement dans le journal ; les sept
  autres composants restent actifs.
- **Un profil navigateur portable ou un binaire téléchargé à la main** ne lit
  aucun des quatre répertoires de policies. Il reste soumis au DNS et à
  nftables, donc au blocage réseau, mais pas aux restrictions applicatives.

---

## Dépannage

### Plus aucune résolution DNS

```bash
systemctl status blocker-resolver
journalctl -u blocker-resolver -n 50
sudo ss -ulpn | grep :53          # dnsmasq doit être là
sudo nft list table ip blocker_adulte_nat
```

Cause la plus fréquente : un autre service occupe déjà `127.0.0.1:53` (le
`dnsmasq` de la distribution, ou un `bind9`). `install.sh` désactive le premier ;
pour les autres, les arrêter ou changer le port du résolveur local.

### Une réinstallation du paquet échoue sur un fichier immuable

```bash
sudo /usr/lib/blocker-adulte/blocker-configure   # relance tout proprement
```

Si `blocker-configure` n'existe plus (paquet à moitié retiré) :

```bash
for f in $(grep -oE '^/etc/\S+' /usr/share/doc/blocker-adulte/README.md); do
    sudo chattr -i "$f" 2>/dev/null
done
sudo dpkg --configure -a
```

### Les services redémarrent en boucle

```bash
journalctl -u blocker-resolver -n 100 --no-pager
sudo dnsmasq --test --conf-file=/etc/dnsmasq.d/blocker-adulte.conf
```

Une liste de blocage corrompue est normalement rejetée avant mise en place. Pour
repartir de la liste de base seule :

```bash
sudo rm -f /var/lib/blocker-adulte/blocklists/[1-9][0-9]-*.conf
sudo systemctl restart blocker-resolver
```

### Un site légitime est bloqué

Ajouter une exception dans un fichier séparé, qui n'est jamais écrasé par la
mise à jour des listes (celle-ci ne touche que `[1-9][0-9]-*.conf`) :

```bash
echo 'server=/exemple.fr/1.1.1.3' | sudo tee /var/lib/blocker-adulte/blocklists/99-exceptions.conf
sudo systemctl restart blocker-resolver
```

### Un test échoue

Chaque test affiche la commande de diagnostic correspondante. Le plus révélateur :

```bash
sudo tests/test_no_hidden_files.sh   # cohérence manifeste ↔ disque
```

---

## Licence

Domaine public / CC0. Outil personnel, fourni sans garantie.
