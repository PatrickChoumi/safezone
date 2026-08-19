# blocker-adulte — Android side

> **Short answer: yes, it can work — but far less well than on Linux, and you
> should know why before relying on it.**

> **Français :** l'édition de référence est [`README.md`](README.md).

On Ubuntu the tool resists an impulsive uninstall: eight components that pick
each other back up, removal in four phases. On Android without root, **none of
that is possible**. What this first version brings is real but different in
kind: filtering that covers the *whole* phone, Wi-Fi and mobile data, without
installing anything — and that switches off in three taps.

Useful against the impulse. Not a protection.

---

## What is shipped

A program that runs **on the PC** and drives the phone over `adb`. It installs
nothing on the device: it writes a setting Android already exposes.

```bash
android/bin/blocker-android --status      # what the phone actually applies
android/bin/blocker-android --probe       # prove it with real name resolutions
android/bin/blocker-android --apply       # set the filtering DNS
android/bin/blocker-android --remove      # put everything back
android/bin/blocker-android --locks       # what a device owner would add
```

The setting is Android's **Private DNS** (DNS-over-TLS, Android 9+), pointed at
a filtering resolver. With the default resolver (`family.adguard-dns.com`):

| | Covered? |
|---|---|
| Adult content (dedicated domains) | yes, filtered server-side |
| SafeSearch on Google / Bing / DuckDuckGo | yes, **enforced server-side** |
| YouTube restricted mode | yes |
| Ads and trackers | yes |
| Wi-Fi **and** mobile data | yes, it is a system setting |
| Every app, not just the browser | yes |

That is roughly components 1 and "enforced SafeSearch" of the Linux side —
obtained without a line of code on the phone, because the resolver does the work.

---

## Requirements

- **Android 9 (API 28) or later.** Private DNS does not exist before that.
- **`adb` on the PC**: `sudo apt install android-tools-adb`,
  `sudo dnf install android-tools`, or `sudo pacman -S android-tools`.
- **USB debugging enabled**: Settings → About → tap "Build number" seven times,
  then Developer options → USB debugging.
- Phone plugged in, unlocked, and the authorisation accepted.

`adb` needs no root, neither on the PC nor on the phone.

---

## Use

```bash
cd safezone
./android/bin/blocker-android --status
./android/bin/blocker-android --apply
```

`--apply` shows what will change, asks for confirmation, writes the setting, and
then **checks that the phone still resolves names**. That check is not
decoration: a wrong DoT hostname, or a network blocking port 853, leaves the
phone **with no DNS at all** — nothing works any more, and the connection with
what you just did is not obvious. If validation fails, the script **reverts by
itself** and says why.

`--host` expects a **hostname**, never an IP address: the name is what validates
the TLS certificate.

### Apps that bypass it

`--status` lists installed apps known to slip past Private DNS — Opera with its
built-in VPN, Tor Browser, Chrome and Firefox with their "Secure DNS". They can
be disabled without uninstalling:

```bash
./android/bin/blocker-android --disable com.opera.browser
./android/bin/blocker-android --enable  com.opera.browser
```

### Automatic reapplication (optional)

Two **user** systemd units put the setting back whenever the phone is plugged
into the PC:

```bash
mkdir -p ~/.config/systemd/user
cp android/systemd/blocker-android.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now blocker-android.timer
```

**Its limit is total**: it only protects while the phone is plugged in. If you
charge it overnight, a setting switched off during the day is restored the same
evening. If you never plug it in, this part does nothing.

---

## What it does not protect

Read all of it. It is the useful half of this document.

| Gap | Why |
|---|---|
| **Three taps on the phone** — Settings → Network → Private DNS → Off | Android offers no way to prevent it without a device owner. That is *the* difference with the Linux side. |
| "Secure DNS" in Chrome, DoH in Firefox | The browser resolves over its own encrypted channel; the system setting never sees it. |
| An app with a built-in VPN (Opera, Tor, some browsers) | Traffic leaves through its own tunnel, DNS included. |
| A VPN installed by the user | It replaces the system DNS while it is active. |
| Direct access by IP address | No DNS filtering can do anything about it. |
| Adult content **inside** Reddit, X, Tumblr, Discord | Lists target dedicated domains. Blocking `reddit.com` outright would break normal use. |
| Another profile, or guest mode | Private DNS is global, but a disabled app is only disabled for the current profile. |
| Another device (second phone, tethering) | Out of reach, as on Linux. |

And one limit inherent to the method: **the resolver sees every DNS query**.
That is already true of the Linux side with the same upstream, but on a phone
there is no local list to absorb part of it — everything goes to AdGuard or
CleanBrowsing.

---

## The three possible levels on Android

| Level | What it takes | Resistance | State |
|---|---|---|---|
| **1. Enforced Private DNS** | nothing but `adb` | three taps to remove | **shipped** |
| **2. Filtering app (VpnService)** | an APK to build | three taps (turn the VPN off) | phase 2 |
| **3. Device owner** | factory reset + an APK | factory reset to remove | phase 3 |

Level 1 is shipped because it delivers most of the filtering at zero cost. The
other two need an Android app that **I can neither build nor test here**: the
machine this code is written on has no Android SDK and no device. Shipping
uncompiled Kotlin would ship a promise, not a tool.

### Phase 2 — the filtering app

What it would add over level 1: **local lists and a personal list**, the
equivalent of `blocker-block`. That is what is missing most today — blocking one
specific subreddit is impossible with a public resolver.

The architecture, for whoever writes it:

- a `VpnService` creating a TUN interface routing **only** DNS
  (`addDnsServer("10.0.0.1")` plus /32 routes to the fake resolver); routing all
  traffic would be pointless and costly in battery;
- a loop reading UDP packets bound for port 53, decoding the question, and
  answering `0.0.0.0` itself for a blocked domain;
- for the rest, an outgoing DoT query to the upstream resolver;
- SafeSearch rewriting works exactly as on Linux: answer `www.google.com` with
  the address of `forcesafesearch.google.com`;
- the StevenBlack and Hagezi lists, the same as on Linux, in a hash table.

This is what AdGuard, Blokada, NetGuard, RethinkDNS and personalDNSfilter do:
the path is well marked, nothing about it is experimental.

Its limit stays the same as level 1: **Android allows only one VPN at a time**,
and the user can switch it off from the quick settings.

### Phase 3 — device owner

The only level with resistance comparable to the Linux side, and it is
**sanctioned by Android** — not a workaround, not a hidden trick:

```
setGlobalPrivateDnsModeSpecifiedHost()    Private DNS enforced, unchangeable
setAlwaysOnVpnPackage(pkg, lockdown=true) always-on VPN, nothing leaks beside it
addUserRestriction(DISALLOW_CONFIG_VPN)   VPN configuration forbidden
addUserRestriction(DISALLOW_SAFE_BOOT)    safe-mode boot forbidden
setUninstallBlocked()                     the app can no longer be uninstalled
```

The price is high and belongs up front:

- the phone must be **factory reset**, or at least have **no account**
  registered — `dpm set-device-owner` fails otherwise;
- it needs an app embedding a `DeviceAdminReceiver`;
- **removal goes through a factory reset of the phone.**

That last line is consistent with the project's philosophy: the way out always
exists, it is documented, it is simply not comfortable. It is not a trap — but
it wipes the phone, which is a good deal heavier than the Linux side's four
phases.

---

## What this side will never do

The project's red lines apply here too, and Android adds one.

| Refused | Why |
|---|---|
| An accessibility service reading the screen and closing the browser | The method of most Play Store "blockers". It hands one app everything displayed, passwords included. The risk/benefit is bad, and it is exactly the kind of concealment this project forbids itself. |
| Root, Magisk, `/system` modification | Breaks security updates and integrity attestation. We protect someone from themselves, not at the cost of an unpatched phone. |
| Hiding the app or the setting | Same red line as on Linux: nothing is concealed. |

---

## Verify

```bash
./android/tests/test_android.sh
```

34 checks, **with no phone**: a simulated `adb` (`android/tests/faux-adb`) plays
the device. That is what makes it possible to exercise the paths you cannot
trigger at will on a real phone — in particular the automatic rollback when the
resolver does not answer.

**What this test does not prove**: that a real phone behaves like the
simulation. It checks the driver's logic — the commands sent, the verdicts
reached, the rollback. Android's own behaviour can only be verified with a
device attached, and `--probe` is there for that.

---

## Honestly, is it worth it?

For everyday impulse: **yes**. Private DNS covers the whole phone, including on
mobile data, including inside apps, and enforced SafeSearch closes the gap
through which most of what a classic DNS filter misses gets through.

Against someone who decides, in cold blood, to work around it: **no**, not
remotely. Three taps. The Linux side asked for eight commands and a randomly
drawn token at every step; this one asks for nothing.

If that difference matters to you, the only answer is phase 3 — device owner,
phone factory reset. Everything else is convenience.
