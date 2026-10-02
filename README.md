# blocker-adulte

Blocage de contenu adulte pour une machine Linux personnelle, **persistant et
distribué sur huit composants indépendants**.

Fonctionne sur toute distribution offrant **systemd** et **nftables** :
Debian, Ubuntu, Fedora, RHEL, Arch, openSUSE, Alpine. Messages en **français ou
en anglais**, selon la locale. Voir
[Distributions supportées](#distributions-supportées) et
[Langue](#langue--français-et-anglais).

L'outil n'est pas conçu pour être impossible à retirer. Il est conçu pour
qu'un moment d'envie ne suffise pas à le défaire : **tout ce qui affaiblit la
protection attend un délai** (48 heures par défaut), puis doit être confirmé.
Une envie dure vingt minutes, pas deux jours. Rien n'est caché : chaque demande,
son échéance et ce qu'elle fera sont affichés par `blocker-delai`.

**Aucune commande ne retire tout.** Le retrait commence par une demande, attend
le délai, puis se fait en [quatre phases](#désinstallation) avec un jeton tiré
au hasard à chaque étape. Ce n'est pas un piège : la procédure manuelle
équivalente est affichable à tout moment par `blocker-uninstall --manuel`.

Trois commandes à retenir :

```bash
blocker-status              # est-ce que ça marche, là, maintenant ?
blocker-status --sonde      # le vérifier par de vraies requêtes DNS
blocker-delai               # ce qui attend le délai
```

---

## Sommaire

- [Langue : français et anglais](#langue--français-et-anglais)
- [Distributions supportées](#distributions-supportées)
- [Philosophie et ligne rouge](#philosophie-et-ligne-rouge)
- [Ce qui tient face à quelqu'un qui connaît tout](#ce-qui-tient-face-à-quelquun-qui-connaît-tout)
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
| Combattre une suppression volontaire | Une désinstallation demandée est **différée, jamais combattue** : passé le délai, les watchdogs se mettent en retrait. Voir [ci-dessous](#le-drapeau-de-retrait-volontaire). |
| Toucher au bootloader ou au firmware | Le hook initramfs n'ajoute que des fichiers à l'image initramfs. Aucune référence à GRUB, systemd-boot, `efibootmgr` ou `/sys/firmware` dans ses scripts : vérifié par le test n°7 de `test_recovery_mode_hook.sh`. `blocker-status` *lit* la configuration de GRUB pour signaler l'absence de mot de passe ; rien ne l'écrit. |
| Réparer en silence | Chaque correction automatique est journalisée avec le préfixe `REPARATION:` (ou `REPAIR:` en anglais) dans `journalctl`. |

### Le drapeau de retrait volontaire

C'est le mécanisme qui rend la désinstallation fiable plutôt qu'un bras de fer.

```
/run/blocker-adulte/uninstall-in-progress
```

Ce fichier est posé par la phase 1 de `blocker-uninstall.sh` (et par le
`prerm` du paquet). Il n'est respecté que si **une demande de désinstallation a
passé le délai** (`blocker-uninstall --demander`, puis 48 h). Alors
`blocker-guard`, `blocker-resolver-run`, `blocker-selfheal` et le dispatcher
NetworkManager cessent toute réparation et le disent dans le journal.

Second déclencheur, aux mêmes conditions : une unité passée à `systemctl
disable`.

Sans demande arrivée à échéance, un drapeau posé à la main est retiré, une
unité désactivée ou masquée est réactivée, un timer arrêté est relancé — chaque
fois avec une ligne `REPARATION:` et la commande qui aboutit. L'outil ne
cherche toujours pas à deviner si un geste est « légitime » : c'est
l'utilisateur qui l'annonce, par la demande, et l'outil s'écarte à l'échéance.

---

## Ce qui tient face à quelqu'un qui connaît tout

L'outil comptait sur la complexité : il fallait savoir où sont les choses et
dans quel ordre agir pour le défaire. Mais c'est son auteur qui s'en sert, et
il connaît chaque fichier. Contre lui, la complexité ne retient presque rien,
et elle s'use : un obstacle contourné une fois se contourne en deux minutes la
fois suivante. Trois choses tiennent mieux.

### 1. Le délai

Toute action qui affaiblit la protection devient une **demande**, applicable
après `BLOCKER_DELAI_HEURES` (48 h par défaut, 24 h au minimum), puis **à
confirmer dans les sept jours** ; sans confirmation, elle expire. Ce qui
renforce la protection s'applique tout de suite.

| Action | Comment elle passe par le délai |
|---|---|
| Modifier `/etc/blocker-adulte/blocker.conf` | Ce fichier est désormais une **proposition**. La configuration en vigueur est `/var/lib/blocker-adulte/conf/blocker.conf`, immuable et suivie par auditd. Une proposition qui renforce est appliquée à la passe de self-heal suivante ; une proposition qui affaiblit devient une demande. Dans le doute (un amont DNS changé, par exemple), une modification est classée « affaiblit ». |
| Retirer un domaine de la liste personnelle | `blocker-block --retirer` dépose une demande (il ne demandait qu'un « o »). |
| Lever un blocage venu des listes | `blocker-block --exception`, même chose. |
| Désactiver un service, désinstaller | `blocker-uninstall --demander` ; les phases 1 à 3 et le retrait par `apt purge` attendent l'échéance. |

```bash
sudo blocker-delai                     # demandes en cours, échéances
sudo blocker-delai --confirmer ID      # après l'échéance
sudo blocker-delai --annuler ID        # à tout moment, effet immédiat
```

Trois précautions rendent le délai difficile à raccourcir sur un coup de tête :

- **la date qui fait foi est le `ctime` du fichier de la demande**, que le noyau
  tient à jour et qu'aucune commande ordinaire ne peut antidater ;
- **une proposition n'est jamais exécutée** : `blocker.conf` est un fichier
  shell, mais une proposition est lue par un analyseur strict qui n'accepte que
  des affectations de variables connues, sans `$`, accent grave ni barre
  oblique inverse. Une ligne non reconnue fait refuser toute la proposition ;
- **modifier la configuration en vigueur à la main ne sert à rien** : le
  self-heal la compare à sa copie de réserve et la restaure.

### 2. Une autre personne

C'est la mesure la plus solide, et l'outil ne peut pas la prendre à votre
place :

1. **Utilisez au quotidien un compte sans droits administrateur.** Créez un
   second compte administrateur et confiez-en le mot de passe à quelqu'un de
   confiance. Le délai et les verrous ne tiennent qu'à condition que la
   personne qui veut les défaire n'ait pas `sudo` sous la main.
2. **Posez un mot de passe sur GRUB et sur le BIOS/UEFI.** Le mode recovery
   d'Ubuntu ouvre un shell root sans mot de passe ; un menu GRUB modifiable
   permet d'ajouter `init=/bin/bash`. Sans ces deux mots de passe, le compte
   sans droits ne tient pas. (Ubuntu : `grub-mkpasswd-pbkdf2`, puis
   `set superusers` et `password_pbkdf2` dans `/etc/grub.d/40_custom`, puis
   `update-grub`.)

L'outil ne touche jamais au chargeur de démarrage — c'est hors périmètre, et
une erreur rendrait la machine non démarrable. `blocker-status` **vérifie** en
revanche, en lecture seule : comptes humains membres de `sudo`/`wheel`/`admin`,
mot de passe GRUB (`set superusers`), `editor no` pour systemd-boot. Le mot de
passe BIOS ne se vérifie pas depuis le système.

### 3. Quelqu'un qui voit les journaux

auditd enregistre tout, mais un journal que personne ne lit ne retient rien.
`blocker-rapport` envoie **chaque semaine** à une personne de confiance :
l'état de l'outil, les réparations, les demandes soumises au délai, les
modifications des fichiers protégés et les commandes sensibles lancées en root
(auditd), les démarrages de la machine — un démarrage en mode recovery est
marqué « À VÉRIFIER ». Le rapport part **même quand rien ne s'est passé**, et il
est numéroté : si les rapports s'arrêtent, elle le remarque.

Chaque demande qui affaiblit la protection lui est en plus signalée **au moment
où elle est déposée**, donc pendant le délai.

Le rapport ne contient aucune adresse de site visité : il dit ce que l'outil a
vu et fait.

```bash
# /etc/blocker-adulte/blocker.conf
BLOCKER_RAPPORT_DESTINATAIRE="ami@exemple.org"
BLOCKER_RAPPORT_EXPEDITEUR="moi@exemple.org"
BLOCKER_RAPPORT_SMTP="smtps://smtp.exemple.org:465"
```

```bash
echo 'utilisateur:mot-de-passe' | sudo tee /etc/blocker-adulte/rapport-smtp.secret
sudo chmod 600 /etc/blocker-adulte/rapport-smtp.secret
sudo blocker-delai                                       # applique (ajout = immédiat)
sudo /usr/lib/blocker-adulte/blocker-rapport --test      # message de vérification
sudo /usr/lib/blocker-adulte/blocker-rapport --apercu    # le rapport, sans l'envoyer
```

Sans serveur SMTP, le `sendmail` local est utilisé s'il existe. Ajouter un
destinataire s'applique tout de suite ; le changer ou le retirer attend le
délai, et le destinataire actuel en est prévenu.

---

## Les huit composants

| # | Composant | Rôle | Se relève grâce à |
|---|---|---|---|
| 1 | **Résolveur DNS local** | `dnsmasq` sur `127.0.0.1:53`, listes StevenBlack *porn-only* + Hagezi *doh-vpn-proxy-bypass*, catégories livrées, **SafeSearch forcé**, amont filtrant en secours | 6, 7 |
| 2 | **Application réseau forcée** | `systemd-resolved` → `127.0.0.1`, DNAT nftables du port 53, rejet DoT/DoQ/DoH (liste communautaire d'adresses), dispatcher NetworkManager | 4, 6, 7 |
| 3 | **Policies navigateur** | Un fichier indépendant par navigateur détecté (Firefox et dérivés, Chrome, Chromium, Brave, Edge, Vivaldi) | 5, 6, 7 |
| 4 | **Hook initramfs** | Règles nftables de base chargées avant le montage de la racine, actives en mode recovery | — (regénéré à l'installation) |
| 5 | **Réaction à la réinstallation** | Triggers dpkg, hook pacman, et une unité `path` systemd qui surveille les répertoires de policies | 7 |
| 6 | **Deux services à surveillance croisée** | `blocker-resolver.service` ↔ `blocker-guard.service`, chacun relance l'autre ; la garde surveille aussi les timers | l'un l'autre, et 7 |
| 7 | **Timer de self-heal** | Passe complète toutes les 5 min : délai, `chattr +i`, empreintes des fichiers d'état, policies, règles nftables comparées à une référence, services | 6, systemd |
| 8 | **Journalisation auditd** | Trace toute écriture sur les fichiers protégés et les commandes sensibles lancées en root ; résumée dans le rapport hebdomadaire | — (n'empêche rien, enregistre) |

### 1. Résolveur DNS local

`dnsmasq` écoute sur `127.0.0.1:53`, séparément du stub `systemd-resolved`
(`127.0.0.53:53`) — les deux coexistent sans conflit de port. Il tourne sous
l'utilisateur système `blocker-adulte`, ce qui permet aux règles nftables de le
distinguer du reste du trafic et d'éviter une boucle de redirection.

Les listes sont mises à jour quotidiennement par `blocker-list-update.timer`,
validées par `dnsmasq --test` **avant** d'être mises en place. Une liste
corrompue ne peut donc pas empêcher le résolveur de démarrer — priver la machine
de DNS serait le plus sûr moyen de pousser à tout désinstaller.

Trois règles tiennent la mise à jour :

- **une liste qui échoue garde sa version précédente**, de même qu'une liste
  de moins de 100 entrées ou de moins de la moitié de sa taille précédente
  (téléchargement tronqué, page d'erreur). Chaque liste a un nom de fichier
  stable, dérivé de son URL : `10-liste-<empreinte>.conf` ;
- **une liste extérieure ne fournit que des noms de domaine.** Chacun est
  validé, et l'outil écrit lui-même la directive, toujours
  `address=/domaine/#`. Une ligne `server=/domaine/IP` d'une liste tierce
  n'est plus recopiée : elle aurait pu rediriger la résolution de ce domaine ;
- **la liste personnelle n'est jamais touchée.** L'ancien nettoyage visait
  `[1-9][0-9]-*.conf` et effaçait chaque jour `50-perso.conf` au passage.

#### Catégories livrées

| Catégorie | Contenu |
|---|---|
| `moteurs-sans-filtre` | Moteurs dont le mode strict ne peut pas être forcé par le DNS : Brave Search, Yahoo, Startpage, Ecosia, Qwant, Mojeek… |
| `frontends-alternatifs` | Interfaces alternatives de YouTube (Invidious, Piped) et de Reddit (Redlib, Libreddit, Teddit), et les services qui redirigent vers une instance |

Toutes deux actives par défaut (`BLOCKER_CATEGORIES`). En retirer une est
soumis au délai.

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
| Google | `forcesafesearch.google.com` | tous les domaines de la liste officielle (`google.com/supported_domains`, réunie avec une copie intégrée de 190 domaines) |
| YouTube | `restrict.youtube.com` | `www.youtube.com`, `m.youtube.com`, `youtube.com`, les API |
| Bing | `strict.bing.com` | `www.bing.com`, `bing.com`, `cn.bing.com` |
| DuckDuckGo | `safe.duckduckgo.com` | `duckduckgo.com` et ses sous-domaines de recherche |
| Yandex | `familysearch.yandex.ru` | `yandex.ru`, `yandex.com` et 18 domaines nationaux, `ya.ru` |

**Les adresses ne sont jamais codées en dur** : `blocker-safesearch` les résout à
chaque mise à jour quotidienne. Un moteur dont l'hôte strict ne répond pas
**garde son entrée précédente** — il disparaissait auparavant du nouveau
fichier, et donc du SafeSearch, jusqu'à la mise à jour suivante.

Les domaines nus de Yandex sont redirigés pour le **nom exact** seulement
(`host-record=`) : la recherche est servie sur `yandex.ru`, mais
`mail.yandex.ru` et les autres sous-domaines restent intacts.

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

Vérification :

```bash
sudo blocker-status --sonde
dig +short @127.0.0.1 www.google.com    # doit donner l'IP de forcesafesearch
```

Désactivable par `BLOCKER_SAFESEARCH="non"` — modification soumise au délai.

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

**L'exemption du résolveur est étroite.** Le résolveur tourne sous
l'utilisateur `blocker-adulte`, seul exempté de la redirection — sinon il se
redirigerait vers lui-même. Cette exemption couvrait tout le trafic de cet
utilisateur. Elle ne vaut plus que **vers les résolveurs amont, sur le port
53** ; les tables de filtrage (DoT, DoH, tunnels) s'appliquent à lui comme aux
autres. Une correspondance par cgroup du service a été écartée : nftables
résout le cgroup au chargement, alors qu'il n'existe pas encore au démarrage, et
il change d'identifiant à chaque redémarrage du service — la règle couperait le
DNS à chaque fois.

**La table nat passe en priorité -110**, juste avant celle d'iptables (-100) :
une connexion n'est traduite qu'une fois, par la première chaîne qui le fait.

**Contrôle complet.** Le contrôle se contentait de vérifier que les tables
existaient et contenaient « dport 53 » et « dport 853 ». Le jeu de règles actif
est désormais comparé, table par table, à une **référence** : les mêmes
fichiers chargés dans un espace réseau jetable (`unshare -n`), où ils ne
touchent à rien. Une règle retirée, une exemption élargie, un jeu d'adresses
vidé sont détectés et rechargés. Une règle NAT d'une autre table qui vise le
port 53 est signalée — jamais modifiée.

**Adresses DoH.** Les jeux `doh_ipv4`/`doh_ipv6` gardent un socle écrit en dur,
complété chaque jour par une liste d'adresses maintenue par la communauté
(`BLOCKER_DOH_IP_URLS`) et par la résolution des noms connus. Ces adresses
vivaient en mémoire du noyau seulement et disparaissaient au premier
redémarrage ; elles sont maintenant dans
`/var/lib/blocker-adulte/nft/doh.nft`, rechargé avec les règles. Les réseaux
privés et les préfixes trop larges en sont écartés.

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
| Firefox | `/etc/firefox/policies/policies.json` | `DNSOverHTTPS.Enabled=false` + `Locked=true`, `network.trr.mode=5` verrouillé, `DisablePrivateBrowsing`, `BlockAboutConfig`, proxy verrouillé sur « aucun » |
| Dérivés de Firefox | `/etc/firefox-esr/`, `/etc/librewolf/`, `/etc/waterfox/`, `/etc/floorp/` + `policies/policies.json` | la même policy |
| Chrome | `/etc/opt/chrome/policies/managed/blocker-adulte.json` | `DnsOverHttpsMode=off`, `QuicAllowed=false`, `SafeSitesFilterBehavior`, navigation privée et session invité désactivées, proxy `direct` verrouillé |
| Chromium | `/etc/chromium/`, `/etc/chromium-browser/` (snap Ubuntu) **et** `/etc/opt/chromium/` + `policies/managed/` | idem — les trois emplacements sont écrits, la disposition varie selon l'origine du paquet |
| Brave | `/etc/brave/policies/managed/blocker-adulte.json` | idem + `TorDisabled`, `BraveVPNDisabled` (qui contourneraient entièrement le résolveur) |
| Edge | `/etc/opt/edge/policies/managed/blocker-adulte.json` | idem, avec `InPrivateModeAvailability` et `ForceBingSafeSearch` |
| Vivaldi | `/etc/vivaldi/policies/managed/blocker-adulte.json` | idem |

**Le proxy est verrouillé sur « aucun proxy »** (`ProxyMode: direct`,
`Mode: none` pour Firefox) au lieu de suivre le réglage du système, qu'un proxy
système ou une variable d'environnement pouvaient décider.

**Vérifier qu'une policy est lue** : `chrome://policy`, `edge://policy`,
`about:policies`. Un navigateur installé **hors de ces répertoires** — flatpak,
snap qui ne lit pas `/etc`, programme extrait dans un dossier personnel — ne
reçoit aucune policy ; `blocker-status` le signale.

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
et l'événement apparaît dans `journalctl`. Le timer de self-heal, que la garde
surveille à son tour, relance les deux au plus tard cinq minutes après. Une
unité désactivée ou masquée sans demande de désinstallation arrivée à échéance
est réactivée.

### 7. Timer de self-heal

`blocker-selfheal.timer` déclenche une passe complète toutes les 5 minutes :
retrait commencé sans demande arrivée à échéance, demandes et proposition de
`blocker.conf` traitées, `chattr +i` réappliqué, fichiers de configuration
comparés à leur modèle, **fichiers d'état comparés à leur réserve**, policies
revérifiées, catégories, règles nftables comparées à la référence, ligne
d'inclusion dans `/etc/nftables.conf`, présence des services, des timers et des
hooks initramfs, règles auditd.

**Fichiers d'état.** Listes, adresses nftables et configuration en vigueur
changent au fil des mises à jour : on ne peut pas les comparer à un modèle
figé. Chaque écriture légitime les pose donc immuables et en garde une copie de
réserve sous `/var/lib/blocker-adulte/reserve`. Une différence avec la réserve
est une modification faite à la main : restaurée (des blocages *ajoutés* sont
acceptés). Un fichier inconnu dans `blocklists/` — tout `.conf` y est lu par le
résolveur — est mis en **quarantaine**, jamais détruit.

Chaque écart est journalisé **avec son détail** avant d'être corrigé. Un
compte-rendu est écrit à chaque passe, même quand rien n'a bougé : un watchdog
muet est indiscernable d'un watchdog mort.

Le self-heal ne relance **pas** `update-initramfs` tout seul (ce serait de
l'usure disque inutile toutes les 5 minutes) : il signale l'écart, la correction
est manuelle.

### 8. Journalisation auditd

`auditd` trace toute écriture, suppression ou changement d'attribut sur les
fichiers protégés, sur `/etc/blocker-adulte`, sur la zone d'état (écritures
faites par une personne seulement) et sur `/etc/systemd/system` (masquage,
surcharge d'une unité), ainsi que les appels à `chattr`, `nft` et `systemctl`
lancés en root par une personne. Ces règles **n'empêchent rien** : elles
enregistrent, et le [rapport hebdomadaire](#3-quelquun-qui-voit-les-journaux)
les résume.

Le fichier installé est généré à partir du modèle, en commentant les règles qui
visent un chemin absent : le noyau refuse une surveillance dont le répertoire
parent n'existe pas, et `auditctl -R` s'arrête à la première erreur — une
règle sur `/etc/brave` sans Brave installé empêchait de charger toutes les
suivantes. Le self-heal le régénère quand un navigateur apparaît.

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
sudo apt install ../blocker-adulte_*_all.deb
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
résolveur amont filtrant (AdGuard DNS Family) : la liste livrée avec le
paquet ne contient que des domaines de contournement (DoH, VPN, proxys), pas
d'énumération de sites adultes — un dépôt git n'est pas le bon endroit pour ça.

### Réglages

Tout se passe dans `/etc/blocker-adulte/blocker.conf` : résolveurs amont,
délai, rapport, catégories, URL des listes. Ce fichier n'est jamais écrasé par
une mise à jour. C'est une **proposition** : après l'avoir modifié, lancer
`sudo blocker-delai`. Ce qui renforce la protection s'applique tout de suite, ce
qui l'affaiblit attend le délai (voir [Le délai](#1-le-délai)). À la première
installation, le fichier est approuvé tel quel ; une réinstallation ou
`blocker-update` ne réapprouve rien. Ce fichier n'étant jamais écrasé, une
installation ancienne ne contient pas la documentation des nouveaux réglages :
le modèle commenté à jour est `/usr/share/blocker-adulte/conf/blocker.conf`.

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
/usr/lib/blocker-adulte/blocker-delai.sh
/usr/lib/blocker-adulte/blocker-listes.sh
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
/usr/lib/blocker-adulte/blocker-categories
/usr/lib/blocker-adulte/blocker-rapport
/usr/sbin/blocker-uninstall
/usr/sbin/blocker-status
/usr/sbin/blocker-update
/usr/sbin/blocker-block
/usr/sbin/blocker-delai

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
/usr/lib/systemd/system/blocker-rapport.service
/usr/lib/systemd/system/blocker-rapport.timer

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
/etc/firefox-esr/policies/policies.json
/etc/librewolf/policies/policies.json
/etc/waterfox/policies/policies.json
/etc/floorp/policies/policies.json
/etc/opt/chrome/policies/managed/blocker-adulte.json
/etc/chromium/policies/managed/blocker-adulte.json
/etc/chromium-browser/policies/managed/blocker-adulte.json
/etc/opt/chromium/policies/managed/blocker-adulte.json
/etc/brave/policies/managed/blocker-adulte.json
/etc/opt/edge/policies/managed/blocker-adulte.json
/etc/vivaldi/policies/managed/blocker-adulte.json

# --- État et exécution ---
# /var/lib/blocker-adulte contient : blocklists/ (listes lues par le
# résolveur), nft/ (adresses chargées avec les règles), conf/ (configuration
# en vigueur, exceptions), delai/ (demandes et leur journal), reserve/ (copies
# de contrôle), rapports/, quarantaine/.
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

Le rapport donne l'état des huit composants, celui des timers, les demandes en
attente du délai, l'envoi du rapport hebdomadaire, les garde-fous humains
(compte du quotidien administrateur, mot de passe GRUB), les navigateurs
installés hors des répertoires de policies, l'état du SafeSearch vérifié **par
une résolution réelle**, le nombre de domaines en liste, l'âge des listes, les
réparations des dernières 24 h, et deux sections franches :

- **« Ce qui ne protège pas »** : composant arrêté, listes périmées, `/etc/hosts`
  non verrouillé, auditd qui ne collecte rien, policies incomplètes — avec la
  commande exacte pour corriger.
- **« Limites permanentes »** : ce qui ne disparaîtra jamais, par conception.

Le code de sortie vaut `0` si tout est opérationnel ou dégradé, `1` si un
composant est hors service — utilisable dans un script de vérification.

Lancé en root, il en vérifie davantage : règles nftables comparées à la
référence, règles NAT étrangères, configuration de GRUB.

`--sonde` est le contrôle le plus parlant : il interroge réellement le résolveur
sur des domaines de contournement (doivent être bloqués), sur les moteurs de
recherche (doivent être en mode strict), sur **quelques domaines tirés au hasard
dans la liste adulte** (doivent être bloqués ; ils ne sont jamais affichés,
seul le compte l'est), sur les catégories, et sur des services légitimes (ne
doivent **pas** être cassés).

En root, il interroge aussi **directement le filtre amont**. Celui-ci est
joint en clair sur le port 53 : un réseau qui détourne le DNS peut lui
substituer un résolveur quelconque sans que rien ne le montre. Si l'amont
renvoie de vraies adresses pour la plupart des domaines adultes testés, la
sonde le dit : « amont changé, ou DNS détourné par le réseau ».

---

## Désinstallation

### Il n'y a pas de commande unique

C'est le point central de la conception, et il est délibéré : **aucune commande
ne retire tout**. Le retrait commence par une **demande**, qui n'ouvre la
phase 1 qu'après le délai (48 h par défaut), puis pendant sept jours. Viennent
ensuite quatre phases, chacune demandant deux commandes — une pour voir ce
qu'elle fera et obtenir un jeton, une pour l'exécuter avec ce jeton. Le jeton
est tiré au hasard à chaque affichage : aucun script préparé à l'avance ne peut
enchaîner les phases.

```bash
sudo blocker-uninstall --etat       # où en est-on
sudo blocker-uninstall --demander   # la demande ; la personne de confiance est prévenue
# ... 48 heures plus tard ...
sudo blocker-uninstall --phase 1    # ce que la phase fera + son jeton
sudo blocker-uninstall --phase 1 --jeton A7K2M9
```

Les phases 1 à 3 exigent la demande arrivée à échéance — la phase 1 seule ne
suffirait pas, des services arrêtés à la main la feraient passer pour faite. La
phase 4, qui rend à la machine un DNS normal, n'est jamais bloquée.

### Ce que ce découpage n'est pas

| Ce n'est pas… | Pourquoi |
|---|---|
| **un piège** | Passé le délai, les quatre phases fonctionnent jusqu'au retrait complet, et `--manuel` affiche la procédure équivalente. |
| **un état caché** | L'avancement est **déduit de l'état réel du système** ; la demande est un fichier lisible, son échéance est affichée. Redémarrer ou refaire une phase déjà faite ne peut pas coincer la désinstallation. |
| **un refus définitif** | Le délai diffère la désinstallation, il ne l'empêche pas. Qui veut vraiment retirer l'outil le peut — deux jours plus tard. |

`tests/test_uninstall_phases.sh` vérifie les deux moitiés de cette promesse : que
c'est pénible (pas de raccourci, ordre imposé, jeton non rejouable) **et** que ce
n'est pas un piège (procédure manuelle complète, aucun fichier compteur).

### Les quatre phases

| Phase | Ce qu'elle fait | Effet visible |
|---|---|---|
| **0** | `--demander`, puis le délai | Rien ne change ; la personne de confiance est prévenue |
| **1** | Pose le drapeau de retrait, désactive puis arrête `blocker-guard` **d'abord** (c'est elle qui relance le résolveur), puis `blocker-resolver`, puis les timers et l'unité path | Le filtrage s'arrête. Les règles nftables pointent encore vers un résolveur éteint : **la résolution DNS est cassée jusqu'à la phase 4.** C'est normal et temporaire. |
| **2** | `chattr -i` sur chaque fichier protégé et sur la zone d'état | Sans elle, ni `apt` ni `rm` ne peuvent supprimer ces fichiers |
| **3** | `apt purge` (ou suppression manuelle), les commandes de `/usr/sbin`, les policies navigateur, les liens d'activation systemd pendants | Le paquet et les policies disparaissent |
| **4** | Hook initramfs + `update-initramfs -u`, les six tables nftables chargées en mémoire, ligne d'inclusion, règles auditd, utilisateur système | **La résolution DNS redevient normale** |

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

Elle commence par la demande et le délai — avant l'échéance, les watchdogs
remettent tout en place — puis couvre les quatre phases : `chattr -i` sur
chaque fichier listé, `apt purge` ou la suppression manuelle, les policies
navigateur, le retrait du hook initramfs suivi de `update-initramfs -u`, les six
tables nftables à décharger, la ligne d'inclusion de `/etc/nftables.conf`, les
règles auditd, les liens d'activation systemd et l'utilisateur système.

### Purge directe par apt

`sudo apt purge blocker-adulte` sans passer par `blocker-uninstall` suit la même
règle : sans demande arrivée à échéance, le `prerm` refuse et affiche la
commande à lancer. Avec elle, il pose le drapeau de retrait, arrête les
watchdogs dans le bon ordre et lève l'immuabilité ; le `postrm` décharge les
tables nftables, retire les policies navigateur et régénère l'initramfs.

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
| `test_uninstall_phases.sh` | Retrait soumis au délai, sans raccourci, jeton non rejouable, **et** sans piège |
| `test_delai.sh` | Proposition jamais exécutée, classement renforce/affaiblit, demande impossible à antidater, plancher de 24 h |
| `test_listes.sh` | Une liste extérieure ne fait entrer que des blocages valides |
| `test_coherence.sh` | Navigateurs, unités, tables et constantes présents partout où il le faut |
| `test_nftables_reference.sh` | Le contrôle détecte une règle retirée, un jeu vidé, une règle NAT étrangère (dans un espace réseau jetable) |

Codes de sortie : `0` conforme, `1` échec, `77` test ignoré (prérequis absent).

Les tests savent où ils tournent. Sans systemd en PID 1 (conteneur, chroot,
image en construction), `test_watchdog_cross_restart.sh` s'ignore proprement et
les contrôles de service se rabattent sur le processus, au lieu d'échouer à
tort.

`make check` complète la suite par une analyse statique : `bash -n` / `sh -n` sur
tous les scripts, `shellcheck -x` en niveau *warning*, et validation JSON des
fichiers de policies. Un avertissement shellcheck fait échouer la cible.

`test_listes.sh`, `test_delai.sh` et `test_coherence.sh` tournent depuis le
dépôt, sans installation ni root.

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

# Demandes soumises au délai, et leur journal
blocker-delai
cat /var/lib/blocker-adulte/delai/historique

# Le rapport que recevra la personne de confiance
sudo /usr/lib/blocker-adulte/blocker-rapport --apercu
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

Elles sont réelles et assumées : l'outil est un dispositif de friction et de
délai, pas une mesure de sécurité contre un adversaire déterminé disposant du
mot de passe root.

### Pas de liste des portes de sortie

Les versions précédentes de ce README classaient les contournements restants
par ordre de facilité, avec la façon de s'y prendre. Pour la personne que
l'outil protège, une telle liste devient, dans un moment d'envie, exactement le
mode d'emploi qu'elle cherche à ne pas avoir sous la main. Elle a été retirée.

Ce qui suit dit **ce que l'outil ne peut pas faire, par construction**, sans
dire comment en tirer parti.

### Contrôles effectués contre une installation complète

| Tentative | Résultat |
|---|---|
| Changer le serveur DNS de la machine ou de NetworkManager | **Bloqué** — la redirection nftables ramène tout au résolveur local |
| Interroger directement un résolveur public | **Bloqué** — la réponse vient du résolveur local |
| DNS-over-TLS, DNS-over-QUIC | **Bloqué** — rejet franc |
| DNS-over-HTTPS vers les fournisseurs connus | **Bloqué** — adresses refusées (liste communautaire) + noms filtrés |
| Bascule automatique vers DoH (enregistrements HTTPS/SVCB) | **Bloqué** — `filter-rr=65` |
| Extension VPN ou proxy de navigateur | **Bloqué** — permission `proxy` refusée, installation d'extensions interdite (Firefox), proxy verrouillé |
| Tor Browser, VPN système en configuration par défaut | **Bloqué** — table `blocker_adulte_tunnels` |
| Moteurs sans mode strict, interfaces alternatives de YouTube et Reddit | **Bloqué** — catégories livrées |
| Ligne ajoutée dans `/etc/hosts` | **Bloqué** si `BLOCKER_LOCK_HOSTS` verrouille, sinon tracé par auditd |
| Modifier une liste, un fichier de configuration, une règle nftables | **Restauré** par le self-heal, tracé, résumé dans le rapport |
| Désactiver un service ou désinstaller | **Différé** — demande, délai, personne de confiance prévenue |

### Le contenu à l'intérieur des plateformes généralistes

C'est la limite la plus proche de l'objectif réel : **le filtrage DNS ne peut
rien** contre un subreddit, un compte X ou un blog Tumblr. Ces domaines ne
peuvent pas être bloqués sans casser un usage légitime, et dériver depuis un
onglet déjà ouvert est bien plus proche du geste impulsif que reconfigurer un
réseau.

| Navigateur | Filtrage au niveau URL |
|---|---|
| Chrome, Chromium, Brave, Edge, Vivaldi | `SafeSitesFilterBehavior: 1` — filtre les URL adultes, y compris sur des plateformes généralistes |
| Firefox et dérivés | **Aucun équivalent.** Mozilla ne fournit pas de policy comparable |

Si l'une de ces plateformes est un point de vulnérabilité pour vous :

```bash
sudo blocker-block reddit.com        # bloque le domaine et ses sous-domaines, tout de suite
sudo blocker-block --liste           # voir votre liste
sudo blocker-block --retirer reddit.com   # une demande, soumise au délai
```

La liste vit dans `/var/lib/blocker-adulte/blocklists/50-perso.conf` et n'est
jamais écrasée par la mise à jour des listes. Ajouter est immédiat ; retirer
passe par le délai, comme tout ce qui affaiblit la protection.

### Limites structurelles

- **Un accès root suffit.** Root peut tout faire, y compris défaire l'outil sans
  passer par lui. C'est pour cela que le compte du quotidien doit être sans
  droits, et le mot de passe administrateur entre d'autres mains (voir
  [Une autre personne](#2-une-autre-personne)). Le délai, les empreintes et le
  rapport rendent un tel geste lent et visible ; ils ne le rendent pas
  impossible.
- **Ce qui ne passe pas par cette machine lui échappe** : un autre appareil, un
  autre système démarré sur la même machine. Toucher au chargeur de démarrage
  ou au firmware est hors périmètre ; les mots de passe GRUB et BIOS sont à
  poser à la main.
- **Le filtrage DNS ne voit que des noms.** Il ne voit ni le contenu, ni une
  connexion qui n'a pas besoin de lui. Les blocages réseau (DoH, tunnels) ne
  couvrent que des adresses et des protocoles connus.
- **Le filtre amont est joint en clair.** Un réseau qui détourne le DNS peut le
  remplacer ; `blocker-status --sonde` le détecte, il ne peut pas l'empêcher.
- **auditd exige que l'audit soit actif au démarrage.** Sur certaines
  installations, le sous-système d'audit du noyau démarre désactivé : les règles
  se chargent mais aucun événement n'est collecté. L'activer demande `audit=1`
  sur la ligne de commande du noyau, donc de modifier GRUB — ce que l'outil ne
  fera pas. `blocker-status` et le rapport le signalent.
- **DNS IPv6 en clair est abandonné, pas redirigé.** Le résolveur local n'écoute
  qu'en IPv4. Les requêtes DNS IPv6 vers le port 53 sont supprimées, ce qui fait
  basculer le client sur IPv4. Aucune fuite, mais une résolution légèrement plus
  lente sur certains réseaux IPv6.
- **Les navigateurs en snap échappent aux triggers dpkg** (composant 5) : ils
  sont couverts par l'unité path et le self-heal. Les snaps Firefox et Chromium
  récents lisent `/etc/firefox/policies` et `/etc/chromium-browser/policies` ;
  vérifier `about:policies` ou `chrome://policy` après le premier lancement.
- **Un navigateur installé hors des répertoires de policies** (flatpak,
  programme extrait dans un dossier personnel) reste soumis au DNS et à
  nftables, mais pas aux restrictions applicatives. `blocker-status` le signale.
- **`chattr +i` demande ext4, xfs ou btrfs.** Sur un autre système de fichiers,
  l'immuabilité est ignorée avec un avertissement ; les empreintes et la réserve
  continuent de détecter les modifications.

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
sudo chattr -R -i -a /var/lib/blocker-adulte
sudo dpkg --configure -a
```

### Les services redémarrent en boucle

```bash
journalctl -u blocker-resolver -n 100 --no-pager
sudo dnsmasq --test --conf-file=/etc/dnsmasq.d/blocker-adulte.conf
```

Une liste de blocage corrompue est normalement rejetée avant mise en place, et
une liste modifiée à la main est restaurée depuis sa réserve par le self-heal.
Si le doute persiste, relancer la mise à jour : elle revalide tout avant de
remplacer quoi que ce soit.

```bash
sudo systemctl start blocker-list-update.service
```

### Un site légitime est bloqué

Une exception retire le domaine des listes générées et le confie à l'amont, qui
reste filtrant. Elle lève un blocage : elle passe donc par le délai.

```bash
sudo blocker-block --exception exemple.fr
sudo blocker-delai                          # échéance, puis --confirmer
```

Un fichier déposé à la main dans `/var/lib/blocker-adulte/blocklists/` est mis
en quarantaine par le self-heal (`/var/lib/blocker-adulte/quarantaine/`).

### Une modification de blocker.conf n'est pas prise en compte

```bash
sudo blocker-delai
```

Il dit si la proposition renforce (appliquée), affaiblit (demande et échéance)
ou contient une ligne refusée, avec son numéro.

### Un test échoue

Chaque test affiche la commande de diagnostic correspondante. Le plus révélateur :

```bash
sudo tests/test_no_hidden_files.sh   # cohérence manifeste ↔ disque
```

---

## Licence

Domaine public / CC0. Outil personnel, fourni sans garantie.
