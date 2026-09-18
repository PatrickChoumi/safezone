# blocker-adulte

Adult-content blocking for a personal Linux machine, **persistent and spread
across eight independent components**.

> **Français :** ce document est l'édition anglaise. Le README de référence est
> [`README.md`](README.md) — c'est lui que lit `tests/test_no_hidden_files.sh`
> pour vérifier le manifeste, et lui qui fait foi en cas de divergence.

The tool is not designed to be impossible to remove. It is designed so that
removing it requires **knowing what you are doing, where, and in what order** —
enough to rule out an impulsive disable, without ever turning the machine into a
black box.

**No single command removes everything.** Removal happens in
[four phases](#uninstalling), eight commands in total, with a randomly drawn
token at each step. This is neither a timer nor a trap: the equivalent manual
procedure can be printed at any time with `blocker-uninstall --manual`.

Two commands worth remembering:

```bash
blocker-status              # is it working, right now?
blocker-status --probe      # prove it with real DNS queries (--sonde also works)
```

---

## Contents

- [Language](#language)
- [Supported distributions](#supported-distributions)
- [Philosophy and red lines](#philosophy-and-red-lines)
- [The eight components](#the-eight-components)
- [Installation](#installation)
- [Where everything goes](#where-everything-goes)
- [Uninstalling](#uninstalling)
- [Checking that it works](#checking-that-it-works)
- [Known limits](#known-limits)
- [Troubleshooting](#troubleshooting)

---

## Language

Every message the tool prints — command output, journal entries, the uninstall
procedure — is available in **French and English**. The language is chosen in
this order:

1. `BLOCKER_LANG` in `/etc/blocker-adulte/blocker.conf` (`fr`, `en`, or `auto`);
2. the environment: `LC_ALL`, then `LC_MESSAGES`, then `LANG`;
3. the system locale, read from `/etc/locale.conf` or `/etc/default/locale`;
4. English.

Step 3 matters more than it looks: systemd services start **without** `LANG`.
Without reading the system locale, the journal would speak English while the
terminal speaks French, on the same machine.

To force one language:

```bash
sudo sed -i 's/^BLOCKER_LANG=.*/BLOCKER_LANG="en"/' /etc/blocker-adulte/blocker.conf
sudo systemctl restart blocker-resolver.service blocker-guard.service
```

Or, for one command only: `BLOCKER_LANG=en sudo -E blocker-status`.

### How the translation works

Both texts live side by side in the code, through one function:

```sh
blocker_info "$(m "resolveur demarre" "resolver started")"
```

This is deliberate. Key-based catalogues, or gettext, would have added a build
dependency and the classic failure mode where a mistyped key silently prints
nothing. With both strings in place, a missing translation is visible when
reading the line, and `tests/test_i18n.sh` catches an incomplete call
mechanically. The trade-off — two languages only — is accepted: adding a third
would mean a rewrite, and nobody asked for one.

---

## Supported distributions

Two things are **required**, on any distribution:

| Requirement | Why there is no way around it |
|---|---|
| **systemd** | The eight components rest on units, timers and the systemd watchdog. There is no portable equivalent under OpenRC or runit, and building one would be a different project. |
| **nftables** | Component 2 *is* an nftables ruleset. iptables-legacy cannot express `meta skuid`, which is what exempts the resolver from its own redirection. |

Everything else adapts. `lib/blocker-os.sh` is the only file that knows the
differences; the rest of the project speaks in **roles** ("the package that
provides `dig`") and **actions** ("rebuild the initramfs").

| Family | Package manager | Initramfs | Package hook | Tested |
|---|---|---|---|---|
| Debian, Ubuntu, Mint | `apt` | initramfs-tools | dpkg triggers | **On real hardware** (Ubuntu 26.04) |
| Fedora, RHEL, Rocky, Alma | `dnf` / `yum` | dracut | systemd path unit | Adaptation layer only |
| Arch, Manjaro | `pacman` | mkinitcpio | pacman hook | Adaptation layer only |
| openSUSE, SLES | `zypper` | dracut | systemd path unit | Adaptation layer only |
| Alpine | `apk` | — | systemd path unit | Adaptation layer only |
| Anything else | detected if present | detected if present | systemd path unit | — |

**Read that last column honestly.** `tests/test_portabilite.sh` replays the
detection with the identity of each distribution and checks the chosen package
names, paths and commands. It does **not** prove that a real install succeeds on
Fedora or Arch — that can only be verified on the machine itself. An
unrecognised distribution is not refused: components that cannot be configured
are reported inactive, and the rest works.

### Package names, by role

Rather than a table per distribution version, the tool keeps a list of
candidates per role and picks the **first name the package manager actually
knows**. That is what survives renames (`dnsutils` → `bind9-dnsutils` on Debian,
`bind-tools` → `bind` on Arch) without maintenance.

| Role | Debian | Fedora / RHEL | Arch | openSUSE | Alpine |
|---|---|---|---|---|---|
| resolver | `dnsmasq-base` | `dnsmasq` | `dnsmasq` | `dnsmasq` | `dnsmasq` |
| firewall | `nftables` | `nftables` | `nftables` | `nftables` | `nftables` |
| stub resolver | `systemd-resolved` | `systemd-resolved` | *(in systemd)* | `systemd-network` | — |
| auditing | `auditd` | `audit` | `audit` | `audit` | `audit` |
| `dig` | `bind9-dnsutils`, `dnsutils` | `bind-utils` | `bind`, `bind-tools` | `bind-utils` | `bind-tools` |
| `chattr` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` | `e2fsprogs` |

### The Arch special case

`mkinitcpio` only runs hooks listed in `HOOKS=` in `/etc/mkinitcpio.conf`.
Dropping the files in place is not enough — but a broken `HOOKS` line makes the
machine unbootable. So `blocker-configure` **does not touch that file** unless
you ask:

```bash
# /etc/blocker-adulte/blocker.conf
BLOCKER_MKINITCPIO_HOOK="oui"
```

With that set, the file is backed up to `/etc/mkinitcpio.conf.avant-blocker-adulte`,
edited, and `mkinitcpio -P` is run. **If the rebuild fails, the backup is
restored and the image rebuilt from it.** Component 4 then reports itself
inactive rather than leaving you with an image you cannot boot.

Without it, `blocker-status` tells you exactly what one line to add.

---

## Philosophy and red lines

The technical inspiration is the *tamper protection* model of enterprise EDR
agents: watchdogs monitoring each other, periodic self-healing, deliberately
multi-step removal. The resistance comes from **distribution** and
**redundancy**, never from actively fighting the user.

### What the tool never does

These rules are held throughout the code and verified by
`tests/test_no_hidden_files.sh`:

| Forbidden | How it is guaranteed |
|---|---|
| Hiding a process, a file or a package entry | No `/proc` manipulation, no `LD_PRELOAD`, no kernel module. `ps aux`, `lsof` and the package manager show everything under real names. |
| Copying itself to undocumented locations | The manifest in `README.md` lists **every** location. Test 7 actively looks for copies elsewhere. |
| Fighting a deliberate removal | A voluntary-removal flag puts the watchdogs to sleep at the very first uninstall step. |
| Touching the bootloader or firmware | The initramfs hook only adds files to the initramfs image. No reference to GRUB, systemd-boot, `efibootmgr` or `/sys/firmware`: checked by `test_recovery_mode_hook.sh`. |
| Repairing silently | Every automatic fix is logged with the `REPARATION:` / `REPAIR:` prefix in `journalctl`. |

### The voluntary-removal flag

```
/run/blocker-adulte/uninstall-in-progress
```

Created **first of all** by `blocker-uninstall`. While it exists,
`blocker-guard`, `blocker-resolver-run`, `blocker-selfheal` and the
NetworkManager dispatcher stop repairing anything and say so in the journal.

A second, independent trigger: a unit passed to `systemctl disable` is also
treated as a voluntary removal. That is why the uninstall procedure always runs
`disable` **before** `stop`.

The tool therefore never tries to guess whether an `rm` is "legitimate": the
user announces it, and the tool steps aside.

---

## The eight components

| # | Component | Role | Recovered by |
|---|---|---|---|
| 1 | **Local DNS resolver** | `dnsmasq` on `127.0.0.1:53`, StevenBlack *porn-only* + Hagezi *doh-vpn-proxy-bypass* lists, **enforced SafeSearch**, filtering upstream as backstop | 6, 7 |
| 2 | **Forced network enforcement** | `systemd-resolved` → `127.0.0.1`, nftables DNAT of port 53, DoT/DoQ/DoH rejection, NetworkManager dispatcher | 4, 6, 7 |
| 3 | **Browser policies** | One independent file per detected browser (Firefox, Chrome, Chromium, Brave) | 5, 6, 7 |
| 4 | **Initramfs hook** | Base nftables rules loaded before the root filesystem is mounted, active in recovery mode | — (rebuilt at install time) |
| 5 | **Package-manager reaction** | dpkg triggers, pacman hook, and a systemd `path` unit watching the policy directories | 7 |
| 6 | **Two cross-monitored services** | `blocker-resolver.service` ↔ `blocker-guard.service`, each restarts the other | each other, and 7 |
| 7 | **Self-heal timer** | Full pass every 5 min: `chattr +i`, policies, nftables rules, services | systemd |
| 8 | **auditd logging** | Records every write to the protected files | — (prevents nothing, records) |

### Enforced SafeSearch — the most effective measure in the tool

A blocklist can do nothing about **Google Images, YouTube or Bing**: these are
domains you cannot block without making the machine unusable, and they serve
adult content on demand. That is the hole most of what a classic DNS filter
misses goes through.

All these engines publish a hostname "locked in strict mode". Resolving
`www.google.com` to the address of `forcesafesearch.google.com` therefore
enforces SafeSearch **at network level**: impossible to turn off from browser or
account preferences, valid for *every* browser and application at once, and
independent of being signed in.

| Engine | Redirected to | Domains covered |
|---|---|---|
| Google | `forcesafesearch.google.com` | `www.google.com` + 38 country domains |
| YouTube | `restrict.youtube.com` | `www.youtube.com`, `m.youtube.com`, the APIs |
| Bing | `strict.bing.com` | `www.bing.com`, `bing.com`, `cn.bing.com` |
| DuckDuckGo | `safe.duckduckgo.com` | `duckduckgo.com` and its search subdomains |
| Yandex | `familysearch.yandex.ru` | `yandex.com`, `yandex.ru` |

Addresses are **never hard-coded**: `blocker-safesearch` resolves them at every
daily update. If resolution fails, the file already in place is kept — never a
silent fallback to "no SafeSearch".

### Component 4 across three initramfs generators

nftables rules are **kernel state**. Loaded from the initramfs, they survive
`switch_root` and stay active even when the machine boots into recovery /
single-user mode, where `nftables.service` is not started.

Three generators, one behaviour. All three embed the **same two files**,
produced by the **same two scripts** — only the hook points differ:

| Generator | Build hook | Boot hook | Rebuild |
|---|---|---|---|
| initramfs-tools | `/etc/initramfs-tools/hooks/blocker-adulte` | `scripts/init-bottom/blocker-adulte` | `update-initramfs -u` |
| dracut | `/usr/lib/dracut/modules.d/99blocker-adulte/module-setup.sh` | `pre-pivot` hook | `dracut --force --regenerate-all` |
| mkinitcpio | `/etc/initcpio/install/blocker-adulte` | `/etc/initcpio/hooks/blocker-adulte` (`run_latehook`) | `mkinitcpio -P` |

The two boot hooks for dracut and mkinitcpio contain **no `exit`**: their init
*sources* them, so an `exit` would stop the boot. `test_portabilite.sh` checks
this explicitly — it is the worst defect possible here.

---

## Installation

```bash
git clone https://github.com/PatrickChoumi/safezone.git
cd safezone
sudo ./install.sh
```

`install.sh` detects the distribution, installs the missing dependencies with
the right package manager, lays down the files, enables the eight components and
runs the first list update. Expect two to three minutes, mostly the initramfs
rebuild.

Useful flags: `--dry-run` (show what would happen, change nothing) and
`--no-deps` (install no package).

On Debian and Ubuntu a `.deb` can also be built with `make deb`; its `postinst`
calls exactly the same `blocker-configure`, so both paths produce the same state.

### Updating

```bash
sudo blocker-update --verifier    # is there anything new?
sudo blocker-update               # review the diff, then apply
```

The update refuses to run on a dirty repository, shows the incoming commits,
verifies the fetched code with `make check` before installing it, and asks for
confirmation. Install `shellcheck` to give that check its teeth.

---

## Where everything goes

The authoritative manifest is in [`README.md`](README.md), between the
`MANIFEST-DEBUT` / `MANIFEST-FIN` markers. It is read automatically by
`tests/test_no_hidden_files.sh`, which compares it to `find / -name
'*blocker-adulte*'` and **fails** if a file exists without being declared there.

Keeping a single manifest, in one language, is deliberate: two copies would
drift, and the test would end up checking the stale one.

Summary of the top-level locations:

```text
/usr/lib/blocker-adulte/          executables and shared libraries
/usr/share/blocker-adulte/        templates, lists, tests
/usr/share/doc/blocker-adulte/    both READMEs
/usr/sbin/blocker-{status,block,update,uninstall}
/usr/lib/systemd/system/blocker-*.{service,timer,path}
/etc/blocker-adulte/              local configuration
/var/lib/blocker-adulte/          blocklists and state
/run/blocker-adulte/              runtime
```

Files belonging to other packages are modified in exactly two places, both
reversible and both backed up: the nftables persistence file (`/etc/nftables.conf`,
or `/etc/sysconfig/nftables.conf` on Fedora and RHEL) gains one `include` line,
and `/etc/mkinitcpio.conf` gains one hook name on Arch — only if you asked for it.

---

## Uninstalling

```bash
sudo blocker-uninstall --status     # where do we stand
sudo blocker-uninstall --phase 1    # what phase 1 does, plus a token
sudo blocker-uninstall --phase 1 --token XXXXXX
```

Four phases, two commands each. The token is drawn at random every time the
phase is described, so the sequence cannot be scripted in advance: you have to
read the screen. There is no timer and no hidden state — progress is derived
from the **actual state of the system**, so rebooting, skipping a phase or
redoing one cannot wedge the removal.

`sudo blocker-uninstall --manual` prints the equivalent commands, **for this
machine**: the package-removal command, the initramfs rebuild and the user
deletion are substituted from what is actually installed. A manual procedure
quoting `apt purge` on a Fedora box would be worthless.

---

## Checking that it works

```bash
sudo blocker-status              # the eight components
sudo blocker-status --probe      # real DNS queries against real domains
sudo tests/run_all.sh            # the full suite
sudo tests/run_all.sh --tout     # including the intrusive watchdog test
```

| Test | What it proves |
|---|---|
| `test_no_hidden_files.sh` | Complete manifest, nothing hidden |
| `test_portabilite.sh` | The adaptation layer is right for every supported family |
| `test_i18n.sh` | Both languages, no incomplete translation call |
| `test_dns_leak.sh` | DNS cannot leave the machine except through the local resolver |
| `test_doh_blocked.sh` | DoH, DoT, Tor and default VPNs are blocked |
| `test_safesearch.sh` | SafeSearch enforced, legitimate services untouched |
| `test_uninstall_phases.sh` | No single command removes everything, and it is not a trap |
| `test_browser_reinstall.sh` | A reinstalled browser gets its policy back |
| `test_recovery_mode_hook.sh` | The initramfs image really carries the base rules |
| `test_watchdog_cross_restart.sh` | Each service restarts the other — and neither fights a voluntary removal |

---

## Known limits

These will not go away; they are consequences of the design, and
`blocker-status` prints them every time rather than letting you forget:

- root access is enough to remove everything, in four documented phases;
- a live USB or another operating system bypasses everything;
- direct access by IP address escapes any DNS filtering;
- a private DoH endpoint on an unknown IP would get through;
- a deliberate VPN on port 443 is indistinguishable from HTTPS;
- Tor via obfs4 bridges entered by hand bypasses the block;
- another device (phone, 4G hotspot) is out of reach;
- adult content **inside** general-purpose platforms (Reddit, X, Tumblr) is not
  covered by the lists — that is what `blocker-block` is for:

```bash
sudo blocker-block reddit.com x.com    # block these and all their subdomains
sudo blocker-block --liste             # show your personal list
```

### Unofficial streaming platforms

MovieBox, found on a machine running this tool and **resolving with no
obstacle at all**. Not a failure of the tool: a blind spot in what public
blocklists admit.

Every list used here — StevenBlack porn-only, Hagezi NSFW — classifies by
**dedicated domain**: a domain gets in because that is all the site does. An
unofficial streaming platform is not one. It is a movie site whose catalogue
is unrated and whose ad network is not.

Measured against the Hagezi NSFW list of 18/09/2026:

| Platform | Entries in a list of 74,633 adult domains |
|---|---|
| `moviebox` | 1 — `moviebox.com`, none of the domains it is actually distributed through |
| `123movies`, `soap2day`, `hdtoday`, `putlocker` | 0 |
| `primewire`, `vidsrc`, `streameast`, `netmirror` | 0 |

Two mechanisms answer this, neither replacing the other.

**1. A category list shipped with the package.**
`/var/lib/blocker-adulte/blocklists/02-plateformes.conf` holds the confirmed
domains of these platforms, grouped by family: the MovieBox application
itself, clients of the same kind, pirate streaming sites with adult ad
networks, and the embedded players that serve those ads. It works offline from
the moment it is installed, and self-heal puts it back if it disappears.

**2. Pattern blocking, for mirror rotation.**
These platforms change domain faster than any list updates: the name stays,
the extension moves — `fmovies.to` becomes `fmovies.co`, then `fmoviesz.to`.
Enumerating is therefore not enough. `--motif` blocks the **name** rather than
the domain:

```bash
sudo blocker-block --motif moviebox   # 2,668 domains covered at once
sudo blocker-block --motifs           # show active patterns
sudo blocker-block --retirer-motif moviebox
```

The name is written across a hundred extensions (`.ng`, `.to`, `.pro`, `.icu`,
`.sbs`…) and across its numbered and suffixed variants (`moviebox7`,
`movieboxhd`, `moviebox-pro`), offline, without waiting for a public list to
notice the new mirror. The generated file lives in `51-motifs.conf`, and
`blocker-block --motif moviebox.ng` accepts a full domain too — the pattern is
derived from it.

**What a pattern does not cover, deliberately:** a change of *name*. It follows
extension rotation, not a platform that rebrands itself. It does not replace
looking at what actually opens on the machine.

The honest summary: **yes for everyday impulse, no against someone who spends
five minutes deliberately working around it.** That was the goal.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing resolves at all | `journalctl -u blocker-resolver -n 30` — an invalid list is refused *before* startup, so this is usually the upstream |
| A legitimate site is blocked | `sudo blocker-block --retirer <domain>` if you added it; otherwise `grep -rn '<domain>' /var/lib/blocker-adulte/blocklists/` |
| SafeSearch not applied | `sudo systemctl restart blocker-resolver.service` — a SIGHUP does not reload `address=` entries |
| A browser ignores its policy | `about:policies` in Firefox, `chrome://policy` in Chromium. Snap and Flatpak builds only read `/etc/…/policies` on recent versions |
| Component 4 inactive on Arch | Add `blocker-adulte` to `HOOKS` in `/etc/mkinitcpio.conf`, or set `BLOCKER_MKINITCPIO_HOOK="oui"` |
| Everything looks broken | `sudo /usr/lib/blocker-adulte/blocker-configure` re-runs the whole configuration, idempotently |
