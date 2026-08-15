# blocker-adulte

Blocage de contenu adulte pour une machine Ubuntu personnelle, **persistant et
distribué sur huit composants indépendants**.

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
| Réparer en silence | Chaque correction automatique est journalisée avec le préfixe `REPARATION:` dans `journalctl`. |

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
| 5 | **Hooks dpkg/apt** | `postinst` + triggers dpkg : réinstaller un navigateur ne perd pas sa policy | 7 |
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
| Pixabay | `safesearch.pixabay.com` | `pixabay.com` |

**Les adresses ne sont jamais codées en dur** : `blocker-safesearch` les résout à
chaque mise à jour quotidienne. Si la résolution échoue, le fichier en place est
conservé — jamais de retour silencieux à « pas de SafeSearch ».

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
/usr/lib/blocker-adulte/blocker-configure
/usr/lib/blocker-adulte/blocker-guard
/usr/lib/blocker-adulte/blocker-resolver-run
/usr/lib/blocker-adulte/blocker-selfheal
/usr/lib/blocker-adulte/blocker-list-update
/usr/lib/blocker-adulte/blocker-safesearch
/usr/lib/blocker-adulte/blocker-doh-refresh
/usr/lib/blocker-adulte/blocker-apply-policies
/usr/lib/blocker-adulte/blocker-apply-nftables
/usr/sbin/blocker-uninstall
/usr/sbin/blocker-status

# --- Modèles, listes, tests, documentation ---
/usr/share/blocker-adulte
/usr/share/doc/blocker-adulte

# --- Unités systemd ---
/lib/systemd/system/blocker-resolver.service
/lib/systemd/system/blocker-guard.service
/lib/systemd/system/blocker-selfheal.service
/lib/systemd/system/blocker-selfheal.timer
/lib/systemd/system/blocker-list-update.service
/lib/systemd/system/blocker-list-update.timer

# --- Configuration ---
/etc/blocker-adulte
/etc/dnsmasq.d/blocker-adulte.conf
/etc/nftables/blocker-adulte.nft
/etc/systemd/resolved.conf.d/blocker-adulte.conf
/etc/NetworkManager/dispatcher.d/90-blocker-adulte
/etc/audit/rules.d/blocker-adulte.rules

# --- Hooks initramfs ---
/etc/initramfs-tools/hooks/blocker-adulte
/etc/initramfs-tools/scripts/init-bottom/blocker-adulte

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

### Limites structurelles

- **Un accès root suffit.** N'importe laquelle des huit étapes peut être faite à
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
