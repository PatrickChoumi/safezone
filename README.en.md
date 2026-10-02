# blocker-adulte

Adult-content blocking for a personal Linux machine, **persistent and spread
across eight independent components**.

> **Français :** ce document est l'édition anglaise. Le README de référence est
> [`README.md`](README.md) — c'est lui que lit `tests/test_no_hidden_files.sh`
> pour vérifier le manifeste, et lui qui fait foi en cas de divergence.

The tool is not designed to be impossible to remove. It is designed so that a
moment of craving is not enough to undo it: **whatever weakens the protection
waits for a delay** (48 hours by default), then must be confirmed. A craving
lasts twenty minutes, not two days. Nothing is hidden: every request, its due
date and what it will do are shown by `blocker-delai`.

**No single command removes everything.** Removal starts with a request, waits
for the delay, then happens in [four phases](#uninstalling) with a randomly
drawn token at each step. It is not a trap: the equivalent manual procedure can
be printed at any time with `blocker-uninstall --manual`.

Three commands worth remembering:

```bash
blocker-status              # is it working, right now?
blocker-status --probe      # prove it with real DNS queries (--sonde also works)
blocker-delai               # what is waiting for the delay
```

---

## Contents

- [Language](#language)
- [Supported distributions](#supported-distributions)
- [Philosophy and red lines](#philosophy-and-red-lines)
- [What holds against someone who knows everything](#what-holds-against-someone-who-knows-everything)
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
| Fighting a deliberate removal | A requested uninstall is **deferred, never fought**: once the delay has passed, the watchdogs stand down. |
| Touching the bootloader or firmware | The initramfs hook only adds files to the initramfs image; its scripts never reference GRUB, systemd-boot, `efibootmgr` or `/sys/firmware` (checked by `test_recovery_mode_hook.sh`). `blocker-status` *reads* the GRUB configuration to report a missing password; nothing writes it. |
| Repairing silently | Every automatic fix is logged with the `REPARATION:` / `REPAIR:` prefix in `journalctl`. |

### The voluntary-removal flag

```
/run/blocker-adulte/uninstall-in-progress
```

Set by phase 1 of `blocker-uninstall`. It is honoured only if **an uninstall
request has passed its delay** (`blocker-uninstall --request`, then 48 h).
Then `blocker-guard`, `blocker-resolver-run`, `blocker-selfheal` and the
NetworkManager dispatcher stop repairing anything and say so in the journal. A
unit passed to `systemctl disable` counts the same way, under the same
condition.

Without a request past its delay, a flag set by hand is removed, a disabled or
masked unit is re-enabled and a stopped timer is restarted — each time with a
`REPAIR:` line and the command that does work. The user announces the removal,
through the request, and the tool steps aside when it falls due.

---

## What holds against someone who knows everything

The tool used to rely on complexity: you had to know where things were and in
what order to undo them. But its user is its author, who knows every file.
Against them complexity holds almost nothing, and it wears out. Three things
hold better.

### 1. The delay

Every action that weakens the protection becomes a **request**, applicable
after `BLOCKER_DELAI_HEURES` (48 h by default, 24 h minimum), then **to be
confirmed within seven days**; unconfirmed, it expires. Whatever strengthens the
protection applies at once.

| Action | How it goes through the delay |
|---|---|
| Editing `/etc/blocker-adulte/blocker.conf` | This file is now a **proposal**. The configuration in force is `/var/lib/blocker-adulte/conf/blocker.conf`, immutable and audited. A strengthening proposal applies at the next self-heal pass; a weakening one becomes a request. When in doubt (a changed DNS upstream, say), a change counts as weakening. |
| Removing a domain from the personal list | `blocker-block --remove` files a request (it used to ask for a single "y"). |
| Lifting a block that comes from the lists | `blocker-block --exception`, same thing. |
| Disabling a service, uninstalling | `blocker-uninstall --request`; phases 1 to 3 and `apt purge` wait for the due date. |

```bash
sudo blocker-delai                    # pending requests, due dates
sudo blocker-delai --confirm ID       # after the due date
sudo blocker-delai --cancel ID        # any time, immediate
```

The age of a request is read from the **ctime** of its file, which the kernel
maintains and no ordinary command can backdate. A proposal is **never
executed**: it is read by a strict parser that only accepts assignments of
known variables, with no `$`, backtick or backslash.

### 2. Another person

The strongest measure, and one the tool cannot take for you:

1. **Use an account without administrator rights day to day**, and give the
   administrator password to someone you trust.
2. **Set a GRUB password and a BIOS/UEFI password.** Ubuntu's recovery mode
   opens a root shell without a password; without both passwords, the account
   without rights does not hold.

The tool never touches the boot loader. `blocker-status` **checks**, read-only:
human accounts in `sudo`/`wheel`/`admin`, a GRUB password (`set superusers`),
`editor no` for systemd-boot. The BIOS password cannot be checked from the
system.

### 3. Someone who sees the logs

auditd records everything, but nobody read those logs. `blocker-rapport` sends
**every week** to a trusted person: the tool's status, repairs, delayed
requests, changes to protected files and sensitive commands run as root, machine
boots (a recovery-mode boot is flagged). It goes out **even when nothing
happened**, and it is numbered: if the reports stop, they notice. Each request
that weakens the protection is also reported **when it is filed**, i.e. during
the delay. The report contains no visited address.

```bash
# /etc/blocker-adulte/blocker.conf
BLOCKER_RAPPORT_DESTINATAIRE="friend@example.org"
BLOCKER_RAPPORT_EXPEDITEUR="me@example.org"
BLOCKER_RAPPORT_SMTP="smtps://smtp.example.org:465"
```

```bash
echo 'user:password' | sudo tee /etc/blocker-adulte/rapport-smtp.secret
sudo chmod 600 /etc/blocker-adulte/rapport-smtp.secret
sudo blocker-delai                                     # adding a recipient applies at once
sudo /usr/lib/blocker-adulte/blocker-rapport --test    # test message
sudo /usr/lib/blocker-adulte/blocker-rapport --apercu  # preview the report
```

---

## The eight components

| # | Component | Role | Recovered by |
|---|---|---|---|
| 1 | **Local DNS resolver** | `dnsmasq` on `127.0.0.1:53`, StevenBlack *porn-only* + Hagezi *doh-vpn-proxy-bypass* lists, shipped categories, **enforced SafeSearch**, filtering upstream as backstop | 6, 7 |
| 2 | **Forced network enforcement** | `systemd-resolved` → `127.0.0.1`, nftables DNAT of port 53, DoT/DoQ/DoH rejection (community address list), NetworkManager dispatcher | 4, 6, 7 |
| 3 | **Browser policies** | One independent file per detected browser (Firefox and forks, Chrome, Chromium, Brave, Edge, Vivaldi); proxy locked to "direct", guest mode off | 5, 6, 7 |
| 4 | **Initramfs hook** | Base nftables rules loaded before the root filesystem is mounted, active in recovery mode | — (rebuilt at install time) |
| 5 | **Package-manager reaction** | dpkg triggers, pacman hook, and a systemd `path` unit watching the policy directories | 7 |
| 6 | **Two cross-monitored services** | `blocker-resolver.service` ↔ `blocker-guard.service`, each restarts the other; the guard also watches the timers | each other, and 7 |
| 7 | **Self-heal timer** | Full pass every 5 min: delay, `chattr +i`, state-file hashes and quarantine, policies, nftables rules compared with a reference, services | 6, systemd |
| 8 | **auditd logging** | Records writes to the protected files and sensitive root commands; summarised in the weekly report | — (prevents nothing, records) |

Highlights of the latest hardening, detailed in `README.md`:

- **lists**: a list that fails keeps its previous version, a list less than
  half its previous size is refused, and an outside list only supplies domain
  names — the tool writes `address=/domain/#` itself, so a third-party
  `server=` line can no longer redirect a domain. The personal list
  `50-perso.conf` is no longer deleted by the daily cleanup;
- **nftables**: the active ruleset is compared table by table with a reference
  loaded in a throwaway network namespace (`unshare -n`); foreign NAT rules on
  port 53 are reported; the resolver's exemption is limited to its upstreams on
  port 53; DoH addresses come from a community list and are saved to a file
  reloaded with the rules;
- **self-heal**: every state file has a reserve copy; a hand edit is restored
  (added blocks are accepted), an unknown file in `blocklists/` is quarantined;
- **categories**: search engines whose strict mode cannot be forced by DNS, and
  alternative YouTube and Reddit front-ends, blocked by default.

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
| Google | `forcesafesearch.google.com` | every domain of the official list (`google.com/supported_domains`), merged with a built-in copy |
| YouTube | `restrict.youtube.com` | `www.youtube.com`, `m.youtube.com`, the APIs |
| Bing | `strict.bing.com` | `www.bing.com`, `bing.com`, `cn.bing.com` |
| DuckDuckGo | `safe.duckduckgo.com` | `duckduckgo.com` and its search subdomains |
| Yandex | `familysearch.yandex.ru` | `yandex.ru`, `yandex.com`, 18 country domains, `ya.ru` (exact names only) |

Addresses are **never hard-coded**: `blocker-safesearch` resolves them at every
daily update. An engine whose strict host does not answer **keeps its previous
entry** instead of dropping out of SafeSearch until the next update.

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
/usr/sbin/blocker-{status,block,update,uninstall,delai}
/usr/lib/systemd/system/blocker-*.{service,timer,path}
/etc/blocker-adulte/              proposed configuration, SMTP secret
/var/lib/blocker-adulte/          lists, configuration in force, requests, reserve, reports
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
sudo blocker-uninstall --request    # the request; the trusted person is told
# ... 48 hours later ...
sudo blocker-uninstall --phase 1    # what phase 1 does, plus a token
sudo blocker-uninstall --phase 1 --token XXXXXX
```

A request first, then the delay, then four phases of two commands each. The
token is drawn at random every time the phase is described, so the sequence
cannot be scripted in advance. Phases 1 to 3 require the request past its due
date; phase 4, which gives the machine normal DNS back, is never blocked.
Progress is derived from the **actual state of the system**, so rebooting or
redoing a phase cannot wedge the removal. `apt purge` follows the same rule: the
package's `prerm` refuses without a request past its delay.

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
| `test_uninstall_phases.sh` | Removal waits for the delay, no shortcut, and it is not a trap |
| `test_delai.sh` | A proposal is never executed, changes are classified correctly, a request cannot be backdated |
| `test_listes.sh` | An outside list can only bring in valid blocks |
| `test_coherence.sh` | Browsers, units, tables and constants are present everywhere they must be |
| `test_nftables_reference.sh` | The check detects a removed rule, an emptied set, a foreign NAT rule (in a throwaway namespace) |
| `test_browser_reinstall.sh` | A reinstalled browser gets its policy back |
| `test_recovery_mode_hook.sh` | The initramfs image really carries the base rules |
| `test_watchdog_cross_restart.sh` | Each service restarts the other — and a removal flag without a request past its delay is removed |

---

## Known limits

Earlier versions listed the remaining ways around the tool, ranked by how easy
they were. For the person the tool protects, such a list becomes, in a moment
of craving, exactly the manual they are trying not to have at hand. It was
removed. What remains are structural limits, stated without instructions:

- root can do anything, including undoing the tool without going through it —
  hence the account without rights and the administrator password in someone
  else's hands; the delay, the hashes and the report make it slow and visible,
  not impossible;
- whatever does not go through this machine escapes it: another device,
  another system;
- DNS filtering only sees names, not content, and network blocks only cover
  known addresses and protocols;
- the filtering upstream is reached in plaintext: a network that hijacks DNS can
  replace it — `blocker-status --probe` detects this, it cannot prevent it;
- adult content **inside** general-purpose platforms (Reddit, X, Tumblr) is not
  covered by the lists — that is what `blocker-block` is for:

```bash
sudo blocker-block reddit.com x.com    # block these and all their subdomains, at once
sudo blocker-block --liste             # show your personal list
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing resolves at all | `journalctl -u blocker-resolver -n 30` — an invalid list is refused *before* startup, so this is usually the upstream |
| A legitimate site is blocked | `sudo blocker-block --exception <domain>` (or `--remove` if you added it): a request, subject to the delay |
| A blocker.conf change is ignored | `sudo blocker-delai` says whether it strengthens (applied), weakens (request and due date) or contains a rejected line |
| SafeSearch not applied | `sudo systemctl restart blocker-resolver.service` — a SIGHUP does not reload `address=` entries |
| A browser ignores its policy | `about:policies` in Firefox, `chrome://policy` in Chromium. Snap and Flatpak builds only read `/etc/…/policies` on recent versions |
| Component 4 inactive on Arch | Add `blocker-adulte` to `HOOKS` in `/etc/mkinitcpio.conf`, or set `BLOCKER_MKINITCPIO_HOOK="oui"` |
| Everything looks broken | `sudo /usr/lib/blocker-adulte/blocker-configure` re-runs the whole configuration, idempotently |
