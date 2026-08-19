# blocker-adulte — volet Android

> **Réponse courte : oui, ça peut marcher — mais beaucoup moins bien que sur
> Linux, et il faut savoir pourquoi avant de s'en servir.**

Sur Ubuntu, l'outil résiste à une désinstallation impulsive : huit composants
qui se relèvent mutuellement, un retrait en quatre phases. Sur Android sans
root, **rien de tel n'est possible**. Ce que cette première version apporte est
réel mais d'une autre nature : un filtrage qui couvre *tout* le téléphone, Wi-Fi
et données mobiles, sans rien installer — et qui se désactive en trois touches.

C'est utile contre le geste impulsif. Ce n'est pas une protection.

---

## Ce qui est livré

Un programme qui tourne **sur le PC** et pilote le téléphone par `adb`. Il
n'installe rien sur l'appareil : il écrit un réglage qu'Android expose déjà.

```bash
android/bin/blocker-android --etat        # ce que le téléphone applique vraiment
android/bin/blocker-android --sonde       # le vérifier par de vraies résolutions
android/bin/blocker-android --appliquer   # poser le DNS filtrant
android/bin/blocker-android --retirer     # tout remettre comme avant
android/bin/blocker-android --verrous     # ce qu'un device owner ajouterait
```

Le réglage posé est le **DNS privé** d'Android (DNS-over-TLS, Android 9 et
plus), pointé vers un résolveur filtrant. Concrètement, avec le résolveur par
défaut (`family.adguard-dns.com`) :

| | Couvert ? |
|---|---|
| Contenu adulte (domaines dédiés) | oui, filtré côté serveur |
| SafeSearch Google / Bing / DuckDuckGo | oui, **forcé côté serveur** |
| YouTube en mode restreint | oui |
| Publicités et traqueurs | oui |
| Wi-Fi **et** données mobiles | oui, c'est un réglage système |
| Toutes les applications, pas seulement le navigateur | oui |

Ce sont, à peu de chose près, les composants 1 et « SafeSearch forcé » du volet
Linux — obtenus sans écrire une ligne de code sur le téléphone, parce que le
travail est fait par le résolveur.

---

## Prérequis

- **Android 9 (API 28) ou plus.** Le DNS privé n'existe pas avant.
- **`adb` sur le PC** : `sudo apt install android-tools-adb` (Debian, Ubuntu),
  `sudo dnf install android-tools` (Fedora), `sudo pacman -S android-tools`
  (Arch).
- **Débogage USB activé** sur le téléphone : Paramètres → À propos → taper sept
  fois sur « Numéro de build », puis Options pour développeurs → Débogage USB.
- Le téléphone branché, déverrouillé, et l'autorisation acceptée.

`adb` n'a besoin d'aucun droit root, ni sur le PC ni sur le téléphone.

---

## Utilisation

```bash
cd safezone
./android/bin/blocker-android --etat
./android/bin/blocker-android --appliquer
```

`--appliquer` montre ce qui va changer, demande confirmation, écrit le réglage,
puis **vérifie que le téléphone résout encore des noms**. Cette vérification
n'est pas décorative : un nom d'hôte DoT erroné, ou un réseau qui bloque le port
853, laisse le téléphone **sans aucun DNS** — plus rien ne fonctionne, et on ne
fait pas forcément le lien. Si la validation échoue, le script **revient tout
seul à l'état précédent** et dit pourquoi.

Pour un autre résolveur :

```bash
./android/bin/blocker-android --appliquer --hote family-filter-dns.cleanbrowsing.org
```

`--hote` attend un **nom d'hôte**, jamais une adresse IP : c'est le nom qui
valide le certificat TLS.

### Applications qui contournent

`--etat` liste les applications installées connues pour passer à côté du DNS
privé — Opera et son VPN intégré, Tor Browser, Chrome et Firefox avec leur
« DNS sécurisé ». On peut les désactiver sans les désinstaller :

```bash
./android/bin/blocker-android --desactiver com.opera.browser
./android/bin/blocker-android --reactiver  com.opera.browser
```

### Remise en place automatique (optionnel)

Deux unités systemd **utilisateur** remettent le réglage quand le téléphone est
branché au PC :

```bash
mkdir -p ~/.config/systemd/user
cp android/systemd/blocker-android.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now blocker-android.timer
```

**Sa limite est entière** : ça ne protège que pendant que le téléphone est
branché. Si vous le rechargez la nuit, un réglage désactivé dans la journée est
remis le soir même. Si vous ne le branchez jamais, cette partie ne sert à rien.

Le service ne fait rien tant que `--appliquer` n'a pas été lancé une fois sur
cet appareil : il ne remet en place que ce qui a été demandé.

---

## Ce que ça ne protège pas

À lire en entier. C'est la moitié utile de ce document.

| Trou | Pourquoi |
|---|---|
| **Trois touches sur le téléphone** — Paramètres → Réseau → DNS privé → Désactivé | Android ne permet pas de l'empêcher sans device owner. C'est *la* différence avec le volet Linux. |
| « DNS sécurisé » dans Chrome, DoH dans Firefox | Le navigateur fait sa propre résolution chiffrée, le réglage système ne la voit pas. |
| Une application avec VPN intégré (Opera, Tor, certains navigateurs) | Le trafic sort par son propre tunnel, DNS compris. |
| Un VPN installé par l'utilisateur | Il remplace le DNS du système tant qu'il est actif. |
| L'accès direct par adresse IP | Aucun filtrage DNS ne peut y quelque chose. |
| Le contenu adulte **à l'intérieur** de Reddit, X, Tumblr, Discord | Les listes visent des domaines dédiés. Bloquer `reddit.com` en entier casserait l'usage normal. |
| Le navigateur d'un autre profil, ou le mode invité | Le DNS privé est global, mais une application désactivée ne l'est que pour le profil courant. |
| Un autre appareil (deuxième téléphone, partage de connexion) | Hors de portée, comme sur Linux. |

Et une limite propre au moyen employé : **le résolveur voit toutes vos requêtes
DNS**. C'est déjà le cas du volet Linux avec le même amont, mais sur téléphone
il n'y a pas de liste locale pour amortir — tout part chez AdGuard ou
CleanBrowsing.

---

## Les trois niveaux possibles sur Android

| Niveau | Ce qu'il faut | Résistance | État |
|---|---|---|---|
| **1. DNS privé forcé** | rien, juste `adb` | trois touches pour le retirer | **livré** |
| **2. Application de filtrage (VpnService)** | un APK à construire | trois touches (désactiver le VPN) | phase 2 |
| **3. Device owner** | remise à zéro du téléphone + un APK | remise à zéro pour l'enlever | phase 3 |

Le niveau 1 est livré parce qu'il apporte l'essentiel du filtrage pour un coût
nul. Les deux autres demandent une application Android que **je ne peux ni
construire ni éprouver ici** : la machine sur laquelle ce code est écrit n'a ni
SDK Android, ni appareil. Livrer du Kotlin non compilé serait livrer une
promesse, pas un outil.

### Phase 2 — l'application de filtrage

Ce qu'elle apporterait par rapport au niveau 1 : **des listes locales et une
liste personnelle**, l'équivalent de `blocker-block`. C'est ce qui manque le
plus aujourd'hui — bloquer un subreddit précis est impossible avec un résolveur
public.

L'architecture, pour qui voudra l'écrire :

- un `VpnService` qui crée une interface TUN et ne route **que** le DNS
  (`addDnsServer("10.0.0.1")` + routes /32 vers le faux résolveur) ; router tout
  le trafic serait inutile et coûteux en batterie ;
- une boucle qui lit les paquets UDP à destination du port 53, décode la
  question, et répond elle-même `0.0.0.0` pour un domaine bloqué ;
- pour les autres, une requête DoT sortante vers le résolveur amont ;
- la réécriture SafeSearch se fait exactement comme sur Linux : répondre à
  `www.google.com` l'adresse de `forcesafesearch.google.com` ;
- les listes StevenBlack et Hagezi, les mêmes que sur Linux, chargées dans une
  table de hachage.

C'est ce que font AdGuard, Blokada, NetGuard, RethinkDNS et personalDNSfilter :
le chemin est balisé, il n'a rien d'expérimental.

Sa limite reste la même que celle du niveau 1 : **Android n'autorise qu'un seul
VPN à la fois**, et l'utilisateur peut le couper depuis les paramètres rapides.

### Phase 3 — device owner

C'est le seul niveau qui apporte une résistance comparable au volet Linux, et
il est **sanctionné par Android** — pas un contournement, pas une astuce cachée.
Une application déclarée propriétaire de l'appareil peut :

```
setGlobalPrivateDnsModeSpecifiedHost()   DNS privé imposé, non modifiable
setAlwaysOnVpnPackage(pkg, lockdown=true) VPN toujours actif, rien ne sort à côté
addUserRestriction(DISALLOW_CONFIG_VPN)   configuration VPN interdite
addUserRestriction(DISALLOW_SAFE_BOOT)    démarrage en mode sans échec interdit
setUninstallBlocked()                     l'application ne se désinstalle plus
```

Le prix est élevé et il faut le dire d'avance :

- le téléphone doit être **remis à zéro**, ou du moins n'avoir **aucun compte**
  enregistré — `dpm set-device-owner` échoue sinon ;
- il faut une application embarquant un `DeviceAdminReceiver` ;
- **le retrait passe par une remise à zéro du téléphone.**

Cette dernière ligne est cohérente avec la philosophie du projet : la sortie
existe toujours, elle est documentée, elle n'est simplement pas confortable.
Elle n'est pas un piège — mais elle efface le téléphone, ce qui est autrement
plus lourd que les quatre phases du volet Linux.

`--verrous` affiche tout cela sur la machine, avec les commandes.

---

## Ce que ce volet ne fera pas

Les lignes rouges du projet valent ici aussi, et Android en ajoute une.

| Refusé | Pourquoi |
|---|---|
| Service d'accessibilité qui lit l'écran et ferme le navigateur | C'est la méthode de la plupart des « bloqueurs » du Play Store. Elle donne à une application la lecture de tout ce qui s'affiche, mots de passe compris. Le rapport bénéfice/risque est mauvais, et c'est exactement le genre de dissimulation que le projet s'interdit. |
| Root, Magisk, modification de `/system` | Casse les mises à jour de sécurité et l'attestation d'intégrité. On protège quelqu'un de lui-même, pas au prix d'un téléphone sans correctifs. |
| Cacher l'application ou le réglage | Même ligne rouge que sur Linux : rien n'est masqué. |
| Se faire passer pour une application système | Idem. |

---

## Vérifier

```bash
./android/tests/test_android.sh
```

34 contrôles, **sans téléphone** : un `adb` simulé (`android/tests/faux-adb`)
tient lieu d'appareil. C'est ce qui permet d'éprouver les chemins qu'on ne peut
pas provoquer à volonté sur un vrai téléphone — en particulier le retour arrière
automatique quand le résolveur ne répond pas.

**Ce que ce test ne prouve pas** : qu'un vrai téléphone se comporte comme la
simulation. Il vérifie la logique du pilote — les commandes envoyées, les
verdicts rendus, le retour en arrière. Le comportement d'Android lui-même ne se
vérifie qu'avec un appareil branché, et `--sonde` est là pour ça.

---

## Honnêtement, est-ce que ça vaut le coup ?

Pour l'usage impulsif du quotidien : **oui**. Le DNS privé couvre le téléphone
entier, y compris en 4G, y compris dans les applications, et le SafeSearch forcé
ferme le trou par lequel passe l'essentiel de ce qu'un filtre DNS classique
laisse échapper.

Face à quelqu'un qui décide, à froid, de le contourner : **non**, et de loin.
Trois touches. Le volet Linux demandait huit commandes et un jeton tiré au
hasard à chaque étape ; celui-ci ne demande rien.

Si cette différence compte pour vous, la seule réponse est la phase 3 — device
owner, téléphone remis à zéro. Tout le reste est du confort.
