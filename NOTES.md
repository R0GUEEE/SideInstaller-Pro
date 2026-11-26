# SideInstaller — build notes

Raw, full-featured on-device sideloader. Combines StikPair's RPPairing, a
LocalDevVPN-loopback lockdown connection, and SideStore's install/refresh model
into one app. The UI is a deliberately raw test harness (buttons + log console);
everything below the UI is the real pipeline.

## How to build

```sh
./build-rust.sh        # cross-compiles rust-core -> SideInstallerFFI.xcframework
xcodegen generate      # regenerates SideInstaller.xcodeproj from project.yml
# then open SideInstaller.xcodeproj, or:
xcodebuild build -project SideInstaller.xcodeproj -scheme SideInstaller \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

Toolchain used here: Xcode 27.0 beta (iOS 27.0 SDK), Rust 1.96 with targets
`aarch64-apple-ios` + `aarch64-apple-ios-sim`, xcodegen.

### Checks (what every pull request runs)

`.github/workflows/checks.yml` runs three jobs on each pull request and push to
main, each a script that runs the same on a Mac:

```sh
scripts/test-rust.sh            # rust-core's tests, then the vendored crates' (idevice, isideload, apple-codesign-quick)
(cd rust-core && cargo clippy --all-targets -- -D warnings)
scripts/check-ios.sh            # simulator build + SideInstallerTests (ios-tests/), in a clean clone or worktree
scripts/check_translations.py   # every L("…") string against each *Strings.swift table
```

- The vendored crates aren't workspace members (siboot, in
  [FrizzleM/siboot](https://github.com/FrizzleM/siboot), builds them from outside
  rust-core through a submodule of this repository), so `test-rust.sh` tests each from
  its own folder with the features the app's build gives it, rust-core's
  `[patch.crates-io]` entries and a copy of `rust-core/Cargo.lock`, put back
  after. idevice's `test_pairing_file_roundtrip` is skipped: it reads
  `/var/lib/lockdown/test.plist` from the machine running it.
- `check-ios.sh` builds only the Rust library's simulator slice
  (`DEVICE=0 ./build-rust.sh`) and runs the tests inside the app on the newest
  iPhone simulator. With `-quiet`, xcodebuild names a failing test only; the
  script prints each failure from the result bundle.
- The translation check fails on a duplicate key (Swift stops the app on the
  first lookup in that table), a translation whose `%@`/`%d` differ from its
  key, a key built with `\(…)`, and, given `--base`, a string untranslated now
  that wasn't at that commit. Gaps a language already had are listed, not
  failed: as of 2026-11-09, Turkish lacks 32 strings and Spanish, Italian and
  Vietnamese lack "Beta". Names read the same everywhere (Discord, Wi-Fi,
  LocalDevVPN…) are in its `SAME_IN_EVERY_LANGUAGE`; labels translated later
  with `L(value)` are found through `EXTRA_KEY_SOURCES`.

## Pins

| dependency | pin | features |
|---|---|---|
| idevice (jkcoxson) | rev `7bd551c16c6dd2e058740d85a2d9399a51a776e9` | `remote_pairing tunnel_tcp_stack rsd tcp xpc core_device_proxy installation_proxy installcoordination_proxy afc house_arrest misagent heartbeat mobile_image_mounter pair usbmuxd aws-lc` |
| idevice-ffi (vendored) | same rev, `vendor/idevice-ffi` | `full aws-lc` |
| isideload (nab138, vendored) | rev `e319d93`, `vendor/isideload` | `fs-storage` (no keyring, no `install`) |

The idevice rev matches StikPair's (RPPairing host) and StikDebug's
(`tunnel_create_rppairing` loopback connection), so both replicated mechanisms
track known-good implementations.

### Architecture decision: reuse idevice's own FFI for connection/install

Rather than re-implement idevice's threading-sensitive RSD tunnel + service
clients by hand (untestable here, high risk), `rust-core` depends on **both**:

- `idevice` (library) — for our forked RPPairing host (`pairing.rs`) and the
  logging spine.
- `idevice-ffi` (the crate StikDebug ships) — for the proven C-FFI
  (`tunnel_create_rppairing`, `installation_proxy_*`, `afc_*`, `lockdownd_*`,
  `rsd_*`, `rp_pairing_file_*`). `extern crate idevice_ffi as _;` re-exports its
  `#[no_mangle]` symbols into our single staticlib; cargo unifies the one
  `idevice` instance (no duplicate symbols — verified with `nm`).

idevice-ffi is **vendored** under `rust-core/vendor/idevice-ffi`. The first
change was `crate-type = ["rlib"]` (upstream is `staticlib+cdylib+rlib`; rustc
emits all in one pass and the standalone **cdylib** link fails on the iOS
*device* target); it has since gained `tunnel_create_rppairing_multihost` and a
few build fixes, all listed in `rust-core/vendor/idevice-ffi/README.md`.
Swift gets both headers via the module map and calls idevice's
FFI directly from `DeviceConnection.swift`, exactly as StikDebug does.

The generated `idevice.h` (8948 lines, cbindgen, plist.h appended) is copied to
`rust-core/include/idevice.h`.

## Environment limits (important, honest)

The four make-or-break **runtime** steps cannot be tested in this build
environment — they need a physical iOS 17.4+ device with Developer Mode, the
LocalDevVPN app, and a real Apple ID. A simulator has none of that. So:

- Steps that are **device-independent** (FFI/log spine, IPA download, project
  build) are verified here.
- Steps that are **device-dependent** (RPPairing PIN, loopback connect,
  install, Apple ID sign-in) are written as real code but **unverified** until
  run on hardware. No fake success is stubbed anywhere.

## Progress (gate-by-gate)

### Step 1 — scaffold + logging spine ✅ (runtime-verified in simulator)

- `rust-core/` C-FFI crate: `si_log_init` installs a global `tracing`
  subscriber whose writer forwards every formatted line to a Swift callback;
  `si_ping` exercises `tracing::info!`.
- `build-rust.sh` + `project.yml` mirror StikPair; produce
  `SideInstallerFFI.xcframework` (ios-arm64 + ios-arm64-simulator).
- `ios-app/`: `Engine` (all logic, singleton so the C log callback can target
  it), raw `ContentView` (inputs / per-stage buttons / scrollable monospaced
  log console with Copy + Clear), `SideInstallerApp`.
- **Gate result:** built for the simulator and launched; the console shows Rust
  tracing output live, e.g.
  `[rust]  INFO sideinstaller_ffi: si_ping: Rust core alive (idevice @7bd551c linked)`.
  Transport/pairing-record types: N/A at this step.

### Step 2 — pairing + connection — code complete; device steps unverified

**Pairing (RPPairing host, make-or-break #1).** `pairing.rs` ports StikPair's
`run_host` (FFI `si_pairing_run_host`); `PairingController.swift` requests Local
Network, keeps the app alive with silent audio (works iOS 17.4+, vs StikPair's
iOS-26 `BGContinuedProcessingTask`), advertises over Bonjour via `NetService`,
runs the host off-thread, surfaces the PIN, and writes the pairing file to
`Application Support/rp_pairing_file.plist`. Reports every step into the log
console.

**Re-read against StikPair 1.1.0 (2026-08-24).** `pairing.rs` is still a faithful
port — same bind, same `RpPairingSocket::new_device`, same TXT records from
`PairableHostInfo::mdns_txt_records`, same callback shape — plus the milestone
logging and the zero-byte guard, which StikPair doesn't have. **StikPair has no
tunnel code at all**: it pairs, writes the file, and stops, so it has nothing to
say about the `createListener` failure below. Two other differences are
deliberate and stay as they are: silent audio instead of
`BGContinuedProcessingTask` (iOS 17.4+ vs 26+), and no Apple TV path, which needs
`RemotePairingClient` as a *client* and is out of scope here.

One real defect came out of the comparison, and it was in both apps. StikPair's
own comment — *"A production app should persist both the pairing file and
`host_info.alt_irk` so already-paired devices keep working"* — describes what
neither did:

- `PairableHostInfo::generate` mints a **random `alt_irk` every run**, and the
  `authTag` in the Bonjour TXT record is derived from it
  (`compute_auth_tag(alt_irk, identifier)`). A device that has paired before can
  therefore never recognise this host.
- `RpPairingFile::generate` mints a **fresh Ed25519 key pair every run**. The
  identifier doesn't move (it's `Uuid::new_v3(NAMESPACE_DNS, name)` — which is
  why `d8442cca-…` is constant in every log), but the keys do. That costs
  SideInstaller much more than it costs StikPair, because SideInstaller *writes
  its pairing file into other apps*: every re-pair silently invalidated the copy
  already placed in SideStore, Feather and StikDebug, while the file on disk
  still looked fine.

Both are now carried across pairings. `si_pairing_run_host` takes the
`host_alt_irk_hex` a previous run returned (`PairingController` keeps it in
`UserDefaults` under `rpPairingHostAltIRK`; it was already being returned and
thrown away, exactly as in StikPair), and `run()` loads the existing
`rp_pairing_file.plist` and reuses its key pair instead of generating one,
falling back to generation when there isn't a usable file. Safe because
`pair_setup` only ever *reads* `e_private_key`/`e_public_key`/`identifier` — to
sign M6 — and the one field it writes is `pairing_file.alt_irk`, the **device's**
IRK (responder.rs:402), which is cleared before a re-pair so a different iPhone
can't inherit the last one's. Re-presenting a stable key across a pair-setup is
what a real Mac does; the device replaces its record for the identifier and every
previously placed file keeps working.

`si_pairing_run_host` gained a parameter, so `rust-core/include/sideinstaller.h`
had to be hand-edited alongside it — there is no cbindgen for that header.

**LocalDevVPN's actual shape** (read from its source, `TunnelProv/PacketTunnelProvider.swift`).
`NEIPv4Settings(addresses: [ifaceIP])` puts the tunnel's own end on the `utun`, with
`includedRoutes` = the peer's route only and `excludedRoutes = [.default()]`. We connect
to the peer, which is on no interface — the provider swaps source and destination on every
packet it reads, so anything sent to the peer comes back to the tunnel's own address.

**Its 2026-08 rewrite changed the address model, and broke our tunnel detection.** Before
it, `TunnelDeviceIP` = **10.7.0.0** with a separate user-editable subnet mask (/24) and
`TunnelFakeIP` = **10.7.0.1**. After it, the mask field is gone — addresses are CIDR now,
validated by a new `TunnelProv/CIDRValidator.swift` — and the defaults are
`TunnelIfaceIP` = **10.7.1.1/32**, `TunnelPeerIP` = **10.7.0.1/32**. The keys were renamed
with no migration, so upgrading users silently land on those defaults. Two things follow:

- A **/32 on the `utun` can never contain the peer**, so "is `deviceIP` inside a tunnel
  interface's subnet" — which is all `NetworkStatus` used to ask — reads a perfectly
  healthy point-to-point tunnel as "no tunnel". This is not a LocalDevVPN bug; a /32
  interface plus a host route is the correct shape for a P2P tunnel. `NetworkStatus`
  therefore asks the **routing table** first (`tunnelCarriesRoute`, a UDP `connect` that
  sends nothing and only resolves a source address), and keeps the subnet test as a
  fallback so wider tunnels still answer. The user workaround going round the community —
  setting the tunnel IP to `10.7.0.2/30` so its mask reaches the peer — only widens the
  mask far enough to satisfy the old test, and is unnecessary once the route test lands.
- LocalDevVPN now **prints its addresses with the prefix attached** (`10.7.0.1/32`), so a
  Device IP copied out of it arrives here as a CIDR string. `Engine.deviceHost` strips the
  suffix. Untreated, that string failed `ipv4Value`, fell through to the broad
  tunnel-name check — which iOS's own always-up `utun` satisfies — and reported a tunnel
  that wasn't there, before failing much later in `inet_pton`.
- Its **main screen shows the wrong address to copy**: the status line is
  `connected_to_ip` filled with `TunnelIfaceIP`, i.e. “Connected to 10.7.1.1/32”, this
  iPhone's own end. Only its Settings label the peer (“Device IP 10.7.0.1/32”). Users
  copy the status line into our Device IP, and iOS answers an app's `connect` to any of
  the iPhone's own addresses with **EPERM** at once (`Socket(Os { code: 1, kind:
  PermissionDenied })`, as with `127.0.0.1` and the Wi-Fi address in
  [iOS 27: lockdownd won't pair on-device](#ios-27-lockdownd-wont-pair-on-device-over-any-route)).
  `Engine.deviceIPIsUsable` runs before every tunnel use (Install,
  `ensureNetwork`, `ensurePairingConnection`): when the tunnel carries 10.7.0.1 it switches
  Device IP back to it, otherwise it stops with the address to use.
  `DeviceConnection.connect` turns any remaining EPERM into a `TunnelError` (kind
  `RsdUnreachable`, so nothing re-pairs) with plain advice. Device-tested 2026-10-21
  (iPhone 16, iOS 27, LocalDevVPN up as `utun6` = 10.7.1.1/32): a raw `connect` to
  10.7.1.1:62078 or 127.0.0.1:62078 fails with EPERM in 0 ms, while 10.7.0.1:62078
  connects in 1 ms; with Device IP set to 10.7.1.1 the Pairing scan switched to 10.7.0.1
  and found its apps. The RPPairing route behaves differently on the own address:
  10.7.1.1:49152 accepts, then resets (ECONNRESET), which the Rust side classifies as
  `PairVerify` — “The device rejected this pairing file … pair again”, wrong advice that
  would also make an install re-pair. Another reason the check runs before any dial.

Two further consequences of the shape itself:

- The tunnel routes nothing off-device, so it needs **no Wi-Fi**. Only pairing does
  (Bonjour on the local network). `Engine.needsFreshPairing` is what gates the Wi-Fi
  requirement now.
- Its config sets `isOnDemandEnabled = true` with `NEEvaluateConnectionRule(matchDomains:
  [tunnelIfaceIP, tunnelPeerIP])`, and never disables it. Those are **DNS domain** matches and
  we connect by raw IP, so they can never fire for our traffic — iOS is left free to tear
  the tunnel down whenever it likes. That is the mechanism behind the 0.6.5 "adapter
  closed (NetworkUnreachable)" failures. **Never trust `DeviceConnection.isConnected` to
  mean the tunnel is alive** — it only says our handles are non-null. Re-establish before
  any device work; a pair-verify is cheap and needs no PIN.

Since 0.7.0 the pairing file and isideload's `FsStorage` root both live in
Application Support rather than Documents — `UIFileSharingEnabled` exposes the
whole of Documents in Files (so an IPA can be dropped in), and that's no place
for a pairing record or a signing certificate. `PrivateStore` in
`SideStoreDownloader.swift` owns both paths and migrates 0.6.x's copies across
on first use, falling back to the Documents location if the move can't complete.

**Connection (loopback lockdown, make-or-break #2).** `DeviceConnection.swift`
drives idevice's FFI on the StikDebug recipe:
`rp_pairing_file_read` → `tunnel_create_rppairing(deviceIP:49152, pairing)` →
`(AdapterHandle, RsdHandshakeHandle)`; device info via
`lockdownd_connect_rsd` + `lockdownd_get_value(nil)` → plist
(ProductVersion/ProductType/UDID/…); apps via `installation_proxy_connect_rsd`
+ `installation_proxy_get_apps`. Default device IP `10.7.0.1` (LocalDevVPN
default), configurable in the UI.

**Transport used:** RPPairing pair-verify over the LocalDevVPN Wi-Fi loopback →
TLS-PSK tunnel → in-process software TCP stack (`tunnel_tcp_stack`) → RSD
handshake → services over RSD. Pairing-record type for **our own connection**:
**RPPairing** (`rp_pairing_file.plist`), not a classic lockdown record. The file
handed to *other* apps carries both records — see the format section under
step 4.

**Verified here (simulator):** project builds for device + sim; app launches;
network scan works; the idevice FFI is callable and errors surface raw —
a connect attempt with no pairing file returned
`idevice FFI error code=1 sub=0: NotFound` and was handled gracefully (no crash).

**NOT verifiable here (needs a physical iOS 17.4+ device + LocalDevVPN):** the
actual RPPairing PIN approval, the loopback tunnel, real device info, and the
app list. These are real code, unverified until run on hardware.

#### Connect transport — `Socket(ENOENT)` was NOT usbmuxd

On-device `Connect` failed instantly with
`Socket(Os { code: 2, NotFound, "No such file or directory" })`. ENOENT on a
socket op *looks* like a usbmuxd Unix-socket attempt — but there is **no
usbmuxd anywhere** in the connect path (`grep` confirms; the transport is
`tunnel_create_rppairing`, pure TCP). The real cause, from idevice's own
source: `IdeviceError::Socket(#[from] io::Error)` maps **every** `io::Error` to
the `Socket` variant, and `RpPairingFile::read_from_file` is just
`tokio::fs::read(path)`. So the ENOENT is `rp_pairing_file_read` failing because
`rp_pairing_file.plist` **didn't exist** — pairing never completed.

Fixes applied (connect path + pairing gate only):
- `Connect` now refuses to run unless the pairing file exists and is non-empty,
  with a clear message — never calls into idevice with a missing file.
- The RPPairing step logs explicit milestones (device connected on advertised
  port → PIN issued → handshake complete → **pairing file path + byte size**),
  and fails loudly if the written file is zero bytes.
- **Proven TCP, not usbmuxd:** with a valid pairing file, connecting to a dead
  `127.0.0.1:49152` returns `InternalError("connect: Connection refused (os
  error 61)")` — ECONNREFUSED, a real TCP error, **never ENOENT**. (Verified in
  the simulator via a temporary helper, since removed.)

#### Tunnel dial — the candidate sweep is breadth-first, and why

`createListener` returns the port the device opened and **no host**, so
`finish_tunnel` (`tunnel_provider.rs`) guesses: the RSD peer address first, then
`127.0.0.1`, then the local interface addresses the Swift side passes in.

On a 2026-08-24 nightly log the three guesses behaved as three different
failures at once — `10.7.0.1` (the LocalDevVPN fake IP) black-holed the SYN,
`127.0.0.1` refused it, and the device's own Wi-Fi address `192.168.31.125`
accepted it, completed the TLS-PSK handshake (`Server Finished verified!`) and
then answered the CDTunnel request with a TLS alert. So the listener really is
bound to the local-network interface only, and the session key really is the
right one — the connection just arrived too late. The sweep used to be
**depth-first**: each candidate got its whole retry window before the next was
looked at, which spent **10.2s** — two black-holed SYNs waited out, then a
refusal re-tried six times at 700ms apart — before dialling the one address that
answers. Both runs in that log took the same 10.2s and failed the same way.

The sweep is now **breadth-first**: one attempt at every candidate, then round
again, up to `DIAL_MAX_ROUNDS` within the same 18s `DIAL_BUDGET`. Every
candidate is a local address, so `DIAL_ATTEMPT_TIMEOUT` dropped from 3s to
800ms — it is not a latency allowance, only a cap so a black-holed SYN can't
stall the candidates behind it. Same log, same candidates: the live listener is
now reached ~0.85s after `createListener` instead of 10.2s, and a listener that
genuinely isn't accepting yet still gets its six attempts.

Two smaller changes fall out of the same log:

- **A rejected handshake re-dials the same host immediately.** That connection
  burns the listener, so a replacement has to be requested either way; the
  replacement is at its youngest right now, so the sweep steps back onto the
  same candidate instead of advancing. Bounded by `DIAL_MAX_HANDSHAKES` (3).
- **`CACHED_TUNNEL_HOST` records a host that merely *accepted*,** not only one
  that completed a tunnel. It was written on full success only, so the second
  run in that log re-walked all three dead guesses in the same order. The cache
  decides ordering alone, so a weaker signal is the right thing to store.

None of that made the tunnel come up, and the next log said why. `read_app_data`
now decrypts the alert body and names it (`describe_alert`, from 36fc210 — which
**had never been built**: `build-rust.sh` last ran 2026-08-19, so every Rust
change from 36fc210 onwards was missing from the shipped `.a` while the Swift
half of that commit shipped. **Check `strings
SideInstallerFFI.xcframework/ios-arm64/libsideinstaller_ffi.a` against the source
before reading any FFI log as evidence.**) The alert is
`warning close_notify` — an *orderly* shutdown, not a rejection.

#### The RPPairing `createListener` route cannot work on-device

With the sweep fixed, the live listener is dialled 13ms after `createListener`
and still gets `close_notify`, three times in a row on three fresh listeners.
That kills the expiry reading and leaves a much simpler one. Put the three
candidates' behaviour together:

| candidate | tunnel port | what it means |
|---|---|---|
| `127.0.0.1` | refused (RST) | the listener is **not** bound to `0.0.0.0` |
| `10.7.0.1` (LocalDevVPN) | no answer, no RST | not on the VPN's address either |
| `192.168.31.125` (en0) | accepts, TLS-PSK completes | bound to the **local network interface** |

So `createListener` opens the tunnel listener on the Wi-Fi interface alone —
which is coherent, since the same response carries a Bonjour `serviceName`. Two
consequences, and they close the route off:

1. Over the loopback VPN the tunnel port is **unreachable by construction**. The
   VPN can forward the fixed RSD port all it likes; the tunnel port is a fresh
   ephemeral one the listener never binds on that interface.
2. Over en0 it is reachable, but the peer is this iPhone's own address — the
   device is being asked to build a tunnel to itself. It completes the TLS
   handshake (the PSK is genuinely right: `Server Finished verified!` compares
   real `verify_data`) and then hangs up cleanly, before it has even read the
   `clientHandshakeRequest` — the `close_notify` arrives in the same millisecond
   as the write.

Nothing the client sends changes that, which is why re-pairing, retrying, fresh
listeners and candidate ordering all failed identically. The whole point of the
loopback VPN is to present a peer address that is *not* the device's own; the
en0 fallback quietly threw that away and only looked like progress.

#### The way through: mint the classic record, take CoreDeviceProxy

CoreDeviceProxy needs no inbound listener at all — it rides the lockdown
connection that already works (see [Two tunnel routes](#step-2--pairing--connection--code-complete-device-steps-unverified)).
`DeviceConnection.connect` already prefers it whenever the pairing file carries a
classic lockdown record. On-device pairing produces only the RPPairing half, so
that route was never offered, and `lockdownPairRecord` — which mints the classic
half — runs *inside* the RSD tunnel, so it could never break the deadlock.

`DeviceConnection.pairOverLockdown` breaks it: `idevice_new_tcp_socket` →
`lockdownd_new` → `lockdownd_pair` against **lockdownd's own port (62078)**, no
tunnel, no provider, no pre-existing pair record. All three symbols were already
exported. `connect` falls back to it when every route the pairing file supports
is spent, stores the record (minting is interactive and spends a device pairing
slot), and retries CoreDeviceProxy with it.

**The open question is whether lockdownd answers on 62078 from on-device**, and
on which address — `enableWirelessLockdown`'s own comment says lockdownd answers
over USB only until `EnableWifiDebugging` is set, and setting it needs a session,
which needs a record. That is why `lockdownPairRecordDirect` takes a *list* of
hosts and tries the VPN peer and plain loopback in turn, logging each. If neither
answers, the record can't be minted on-device at all and an imported pairing file
stays the only way through for this iPhone.

**Answered for iOS 27 (2026-09-30): neither answers.** The VPN peer resets the
first request and loopback is refused by iOS, so on iOS 27 `connect` no longer
tries this fallback — see
[iOS 27: lockdownd won't pair on-device](#ios-27-lockdownd-wont-pair-on-device-over-any-route).

#### Side by Side: iOS 27's lockdownd won't pair over Wi-Fi (issue #52)

Side by Side pairs another iPhone with `lockdownPairRecordDirect` against
`<their IP>:62078`. On iOS 27 targets that never gets anywhere: lockdownd accepts
the TCP connection and resets it (`ECONNRESET`, error 54) the moment the first
request arrives — `GetValue(DevicePublicKey)`, the opening of `lockdownd_pair` —
so no Trust prompt ever appears. Reproduced on two networks by the reporter. The
way iOS 27 pairs over a network is the device-initiated one this app already uses
for itself: the target taps a `_remotepairing-pairable-host._tcp` host under
Settings › Privacy & Security › Developer Mode and types the PIN that host shows.

So `SideBySideManager` keeps the lockdown attempt (it costs one round trip) and,
when lockdownd answered but wouldn't pair — any failure of the `Pair` exchange
except `UserDeniedPairing`, or a refused connection — runs
`PairingController.pairPeer` instead, shows the instructions and the PIN on the
Side by Side page, and tunnels with the resulting RPPairing file. A connection that
never answers at all is the address or the network, and stops there.
`DeviceConnection.LockdownPairError` carries which stage failed.

Things the peer run must not do, all of which the plain `startAndWait` path does:

- **Write this iPhone's pairing file.** `pairPeer` writes
  `peer-pairings/remote-<ip>.plist`; the stored `altIRK`, `Engine.pairingStatus`,
  `pairingPIN`, the imported-file mark and the merged file are left alone. Going
  through `startAndWait` would have overwritten `rp_pairing_file.plist` with the
  target's `alt_irk` — and replaced an *imported* file outright, since the Rust
  side regenerates keys when the file isn't an RPPairing one.
- **Share the host identifier.** A new file's identifier is
  `uuid_v3(NAMESPACE_DNS, name)`, and every SideInstaller self-pairs as
  `SideInstaller` (`d8442cca-…`). Pairing a target under that identifier would
  replace the record *their* SideInstaller pairs itself with, breaking the files it
  placed in SideStore and the rest. Side by Side's host is
  `SideInstaller (Side by Side)` (`cd4b8503-…`) — never rename it.
- **Mint a lockdown record.** `connect` falls back to minting one for an
  RPPairing-only file, which stores *this* iPhone's record and dials its own
  lockdownd on 127.0.0.1. Side by Side passes `allowLockdownMinting: false`.

`cancelPeer` resolves the wait, stops advertising, and connects to the host's own
listener on 127.0.0.1 and hangs up, so a host still blocked in `accept()` fails its
handshake and returns — otherwise the next run would find the host busy. A target
that has already connected keeps the host until it finishes or gives up.

Verified here in the simulator against an address that refuses :62078: the switch
to Remote Pairing, the advertisement (seen from a Mac with `dns-sd`), the
instructions, Cancel ending the host, and a second run starting cleanly. The PIN
exchange and the tunnel need a second iPhone; the reporter ran the same mechanism
(pairable host → RPPairing tunnel → RSD → install) end to end on two iOS 27 iPhones.

#### Side by Side, step by step: SideStore and LiveContainer too

Side by Side is a wizard (`SideBySideManager.Stage`): a welcome, four numbered pages (what to
install, whether they have their iPhone's IP address, the Apple ID, getting their iPhone ready,
with an editable summary), then the run and its outcome on the same page. Pages slide in the
direction of travel
(`movingForward` is published a beat before `stage`, so the leaving page is drawn with it). The
pairing code, the Trust prompt, errors and the last steps are inline, so `RootView` no longer
stacks Side by Side popups. The page keeps the screen awake while a run goes.

It installs `SideBySideApp`: SideInstaller (its latest release, as before), or SideStore /
LiveContainer + SideStore, downloaded exactly as the Install tab does
(`SideStoreDownloader.downloadLatest`, shared Documents copy, imported IPAs used as they are;
`$reportProgress` reports the download's fraction). Every app gets a `setUp` step that hands it
the pair record the run connected with (XML, UDID stamped into a lockdown record):

- **SideStore builds** get what `Engine.performWritePairing` writes: `ALTPairingFile`, the split
  files and `isPairingReset`/`activePairingProtocol`, the anisette settings, and `Account.sideconf`.
- **SideInstaller** (2026-11-06, user's request) gets it as an imported pairing file, as
  `Engine.importPairingFile` leaves one: the record at
  `Library/Application Support/rp_pairing_file.plist` (`PrivateStore.pairingFile`, written with
  `house_arrest_vend_container`, `DeviceConnection.writeFile(intoBundleID:containerPath:data:)`),
  `combined_pairing_file.plist` deleted, and `importedPairingFileName` = `SideBySide.plist` in
  `Library/Preferences/<bundle id>.plist`. Release 1.6.5 reads the same paths and key. Not
  Documents: `PrivateStore.migrate()` moves a Documents copy in only when Application Support has
  none, and deletes it otherwise, so a reinstall would keep the old file. The mark also makes it
  ask for Local Network before connecting on iOS 27 (`ensureLocalNetworkForImportedPairing`), and
  it connects with the file without pairing itself, so the "Needs iOS 27" label is gone: it works
  wherever the record does (below 26.4 with a lockdown record, on 27 with an RPPairing one). On
  26.4 to 26.x a lockdown-only record can't get through LocalDevVPN, so SideInstaller is installed
  without it (`pairingLeftOutOn`) and the last page asks for a computer-made file.
- **Each record lives on in an app on their iPhone**, so each pairing gets an identity of its
  own: a fresh UUID identifier for Remote Pairing (`pairPeer(outPath:identifier:)`, always into a
  fresh `remote-new.plist`, since an existing file lends its identifier) and a fresh HostID for
  the lockdown `Pair` (SystemBUID stays this install's). With a shared one, a later Side by Side
  pairing of the same iPhone would replace the record and break the file an app holds. This
  iPhone still forgets its copy once the run succeeds.
- **No certificate for an Apple ID saved on this iPhone.** `Account.sideconf` carries the
  certificate's private key; handing the user's own over would leave it on someone else's iPhone.
  Their SideStore then asks to resign itself on first sign-in.
- **The IP address is a Yes/No question** ("Do you have the device's IP?", Optional; the field
  shows under Yes). Without it the run pairs from their Settings, which only iOS 27 offers; with
  it, lockdown `Pair` with a Trust prompt, which is how iPhones below 27 pair. For a "No" run,
  the address their iPhone was reached at stays in memory (`pairedAddress`): a retry probes it
  (6 s, port 62078) and reuses the record saved for it, and silence or a record that no longer
  opens a link falls back to pairing from Settings again. A typed address is corrected to the one
  their iPhone paired from.
- **Lockdown-only on 26.4+:** a SideStore build can't use a lockdown record through LocalDevVPN
  from 26.4 on (see below), so `checkCompatibility` stops before anything is signed; SideInstaller
  goes on without the record (above).
- **A typed address is probed first** (`NetworkStatus.probeConnect`, 6 s, port 62078): silence
  fails at once with the unreachable advice instead of after the system's ~75 s connect timeout,
  and a refusal goes straight to Remote Pairing. The Trust card only shows once lockdownd has
  answered (`lockdownPairRecordDirect(onConnected:)`), after 1.2 s, so a lockdownd that resets the
  connection at once (iOS 27) never flashes it.
- The step 1 app cards have no description lines, and the Side by Side copy, its translations
  and its log lines use no dashes (hyphens inside words such as Wi-Fi stay), at the user's request
  (2026-11-06).
- A blocking call that ends in an error after Cancel counts as the cancel.

Verified in the iPhone 17e simulator (iOS 27.2): every page and run state, English, Italian and
Japanese; a real run against 192.0.2.1 (fails in ~6 s; Try again and Change details); a real
Remote Pairing wait with the per-run identifier seen in the advertisement from the Mac, then
Cancel. **Not run on a second iPhone**: the pairing itself, sign-in, install and the SideStore
hand-off on their side.

#### Side by Side: someone else's Apple ID signs in from a temporary folder

isideload's `FsStorage` folder holds the signing key (`<sha256(email)>/key`) and
the anisette identities (`anisette_state*`, `anisette_slots.json`). Side by Side
used to sign the other person in from `PrivateStore.isideload`, this iPhone's own
folder, so their private key stayed here after the run, able to sign as them with
the certificate it made. Now an Apple ID that isn't saved in Settings › Account
signs in from `tmp/peer-sign-ins/<UUID>/` (`PrivateStore.newPeerSignInFolder`).
`SideBySideManager.signOut` deletes it with the session: when the Apple ID
changes, at the end of a successful run (`finishSuccess` signs out now) and on
Clear their details. Folders left by a launch that ended mid-run go when the next
launch creates the manager (`RootView`'s `@StateObject`). A failed or cancelled
run keeps both, so a retry signs with the same key and finds the certificate it
made.

- **The key is needed until the run ends, not just until the install.** `setUp`
  builds SideStore's `Account.sideconf` from it (`si_account_config` reads the
  session's `storage_dir`), so the folder goes in `finishSuccess`, after `setUp`;
  the deletion is queued on `signQueue`, behind anything still signing. The
  signed `.app` isn't in the folder: isideload unpacks it into
  `tmp/<name>_extracted`.
- **Install another app signs in again.** The finished run signed out, so someone
  else's Apple ID gets a new folder: a new anisette identity, so Apple may ask
  their iPhone for a code again, and a new certificate. Keeping the session until
  Done would save both, but the key would then stay on this iPhone for as long as
  the done page is left open, and Done is easy to skip. The run already forgets
  the pairing at the same point, so Install another app pairs again anyway.
- **A saved Apple ID still uses `PrivateStore.isideload`**, so "My Apple ID" keeps
  reusing this iPhone's own key and certificate instead of minting a certificate
  for a key that is thrown away. It gets no `Account.sideconf` (see above).
- **Each new session mints a certificate on their account**, since the key that
  matched the last one is gone. A free account has three; when they're taken, the
  run stops with 7460 (`MaxCertsBehavior::Error`, nothing is revoked) until one is
  revoked. Never revoke the run's certificate at the end: the app just installed
  on their iPhone is signed with it, and their SideStore was handed it.
- **The server it signed in through doesn't become the Auto pick.**
  `anisetteSignedIn` moves Auto to a server because it keeps this iPhone's
  identity and the saved token with it; a temporary folder's identity is thrown
  away, so only the server's recent failure is cleared.

Keys earlier versions left in `isideload` stay: nothing tells them apart from
the folders of Apple IDs removed from Settings › Account, whose keys still match
certificates.

Checked in the iPhone 17e simulator (iOS 27.2) with a hook in a scratch copy and
no anisette server, so nothing reached Apple: the real sign-in step making,
reusing and replacing the folder, `start()` with another Apple ID, `finishSuccess`,
Install another app, Clear, a saved Apple ID signing in from `isideload`, `deinit`,
and the launch sweep. Not run with a real Apple ID or a second iPhone, so a real
key and the SideStore certificate hand-off before the deletion are unchecked.

#### The pairing Live Activity

Pairing this iPhone means typing a code SideInstaller shows into a prompt in
Settings, with SideInstaller behind it. `PairingLiveActivity` puts the code over
Settings instead: `PairingController` starts the activity when the host goes up
(the app is still in front then, which `Activity.request` needs), updates it with
the code from `presentPin`, and ends it when the run does. The updates come from
the background, which works because pairing's keep-alive audio keeps the app
running. Both the code and "Paired" go out with an `AlertConfiguration`: that is
what opens the Dynamic Island, and on an iPhone without one it drops the Lock
Screen card down as a banner for about six seconds. Side by Side doesn't use it:
that code is typed into the other iPhone, with this app in front.

A Live Activity's views have to live in a widget extension, so there is a second
target, `SideInstallerLiveActivity` (`ios-live-activity/`), embedded as
`PlugIns/SideInstallerLiveActivity.appex`. It shares
`ios-app/PairingActivityAttributes.swift` with the app and nothing else: the copy
arrives in the content state, already translated, since the extension has neither
the tables nor the language setting.

An extension needs an application-identifier of its own, under the app's.
`scripts/sign_with_all_certs.sh` (in FrizzleM/SideInstaller-Signed) therefore signs it only under a wildcard profile
(`TEAM.*`), renamed to sit under the app's new bundle id; under an explicit
profile, which covers one id, it removes `PlugIns/`. Every certificate in the pool
on 2026-10-11 had an explicit profile, so none of those builds carry the
extension. Xcode's automatic signing and SideStore/AltStore give the extension
its own App ID, which on a free Apple ID counts against the weekly limit.

Those builds get the code as a local notification instead (`PairingNotification`):
"Pairing code" with the code as its subtitle, replaced by "Paired" under the same
identifier, and cleared when the app is back in front. That costs the system's
"would like to send you notifications" prompt, which comes up when the first
pairing starts, with a step added to the guide saying why. `PairingController`
picks the Live Activity or the notification once, on
`PairingLiveActivity.hasExtension`, and `PairingNotification` checks it again
before it asks or posts: a build with the extension never asks, also when Live
Activities are switched off for the app. A refusal leaves the old wording and
the popup in the app.

Verified in the iOS 27 simulator with a staged run (start → code → paired): the
compact and expanded island on an iPhone 17 (not the minimal one, which takes a
second app's activity), the Lock Screen card, the banner on an iPhone 17e, and the
activity ending 15 s after "Paired". The
signing paths were run against the built app with an ad-hoc identity (wildcard,
wildcard with `FORCED_BUNDLE_ID`, explicit). The notification path was staged the
same way on a build with `PlugIns/` deleted: the prompt, both banners over
Settings, one delivered notification going to none on return, and no prompt on
the second run; the build with the extension stayed at "not determined"
throughout. Not verified: a real pairing on a device, an install of a build
signed through the wildcard path, and a refused prompt.

#### Install progress outside the app

A one-click run left the app's foreground and was suspended within seconds:
nothing kept it going, and nothing showed where it was. `InstallActivity` does
both now, started by `runOneClick` and told how the run ended.

**iOS 26 and later: `BGContinuedProcessingTask`.** The run is submitted as one,
which keeps the app running in the background and has iOS draw the title,
subtitle and progress in a Live Activity of its own (with a stop button). The
title is "Installing <build>", the subtitle the checklist's current step (or, while
the run needs the user, what it needs and what to do; see below), and the progress
the Install tab's percentage out of 1000 units. Info.plist permits
`$(PRODUCT_BUNDLE_IDENTIFIER).install.*` (replacing the `.pairing` entry left
over from StikPair's port, which nothing registered); each run registers and
submits `<bundle id>.install.<UUID>`, since registering an identifier twice ends
the app. The header requires the identifier to start with the bundle ID, so a
build re-signed under another bundle ID without its Info.plist rewritten can't
have one, and is told so in the log. `strategy = .fail`: a task iOS only queued
would start after the user stopped waiting. On iOS 27 the submission goes through
the async `submitTaskRequest(_:)` (the sync one is deprecated there, and the
header says not to call the new one on the main thread). If iOS ends the task
while the app is in the background, that's the stop button or iOS reclaiming the
time, which can't be told apart, and the run is cancelled; in front, the run just
carries on.

**Below 26, or when iOS turns the task down: a Live Activity.**
`InstallActivityAttributes` (shared with the extension like the pairing one) and
`InstallActivityWidget` draw the same title, step and percentage: a bar and a
percentage on the Lock Screen card, the Install tab's symbol and the percentage in
the compact island, a ring in the minimal one. A UIKit background task is held through the whole run, on every iOS: it is
the ~30 s any app gets, and the time to wind down after a cancel. When it runs
out the activity turns to "Paused · Open SideInstaller to finish the install"
before the time is handed back (within a second, whatever is still queued: iOS
kills an app that keeps it past the end), and back to the step once the app is
in front again. A run that ends in the background leaves "Installed" on the Lock
Screen, or "Install stopped" up in the Dynamic Island too, until the app is
opened; one that ends in front takes it down at once. Builds without the
extension get the background time without the activity.

**When the run needs the user, or stops.** `currentNeed()` reads it off the
engine: a 2FA prompt (`twoFactor` asking; the generic instruction, without the
number Apple masks, since this shows on the Lock Screen), the App ID go-ahead
(`appIDCost`), a Trust prompt (`AttentionGate`, which now posts `didChange` on
the main queue, below iOS 27), or the network step waiting on its guide (VPN,
Wi-Fi). Pairing isn't one: its own activity has that. The activity turns orange
(`waiting`, and `paused`) or red (`stopped`, with `lastError`): the need's own
symbol in the badge and the compact island, a mark where the percentage was, a
tinted glow and outline on the Lock Screen card, and "Tap to return to
SideInstaller" where the bar was. Coming into a need, or stopping, updates it
with an `AlertConfiguration` (not while the app is in front, where its popup
says so), which opens the Dynamic Island or drops a banner, and a relevance score
of 100, against 50 for progress. A stopped run's activity isn't ended, so it stays
in the Dynamic Island until the app is opened; iOS ends any after 8 hours, and
launch takes leftovers down.

On iOS 26 and later the task's UI takes only a title and a subtitle: they say the
need and the instruction, or "Install stopped" and the reason. A task the run
stopped on in the background isn't completed at once, since that takes its UI
down: it says so until the app is in front again, or for at most 3 minutes.
SideInstaller's own activity can't stand in there whenever it likes: iOS lets an
app start one only while it's in front. On the iPhone 16 (iOS 27, 2026-10-17)
with the task running, `Activity.request` worked at `willResignActive` and at
`didEnterBackground`, and failed with `visibility` 4 s and 12 s into the
background. So it's started at those two moments when the run needs the user
right then (the user left with the 2FA sheet up, say), comes down once it doesn't
or the app is in front, and turns red if the run stops meanwhile. A need that
comes up later in the background is in the task's title only. Running it for the
whole background stretch instead would put two activities up for every install.

**Not while pairing.** Both can only be started with the app in front, and
neither is while this iPhone still has to pair (no pairing file and the pair
step not done, or the pair step waiting): the pairing Live Activity needs the
Dynamic Island for its code, `KeepAlive` already keeps the app running, and a
task stuck at "Get pairing file" for a minute looks stalled, which iOS may
expire. On a first install the surface goes up when the user comes back from
Settings; the install doesn't carry on in the background before that. A stale
pairing file re-paired mid-run is the exception: the surface is already up and
stays, next to the pairing activity.


### Step 3 — Apple ID + signing — code complete; device/account steps unverified

`account.rs` wraps isideload behind three FFI calls:
- `si_apple_signin` — `AppleAccount::builder().anisette_provider(RemoteV3…)
  .login(password, 2fa_cb)` → `DeveloperSession::from_account` →
  `SideloaderBuilder` (team `First`, `FsStorage`, machine name) → opaque
  `SignSession`. 2FA is bridged to a Swift prompt via a blocking semaphore
  callback (`SITwoFactorCb`).
- `si_sign_ipa(session, ipa, udid, device_name, …)` — first calls
  `DeveloperSession::ensure_device_registered(team, name, udid)` so the team has
  the connected device, then `Sideloader::sign_app(ipa, None, memory_limit, …)` → signed
  `.app` bundle path. sign_app internally registers the App ID + provisioning
  profile and retrieves/creates the dev certificate, then signs with
  `apple-codesign`. **Device registration is mandatory here:** we use the
  sign-only path (not isideload's `install_app`, which is the only place
  isideload registers the device), so without this step a fresh/free team has no
  devices and the profile download fails with developer error **8220** ("Your
  team has no devices …"). The UDID comes from the lockdown handshake, captured
  by Swift during Connect and passed down; a registration failure is prefixed
  `device registration failed for UDID <udid>:` so Swift can surface the UDID.
- `si_account_config(session, …)` — builds the `Account.sideconf` payload
  SideStore imports at launch: Apple ID, the signing certificate as a PKCS#12
  encrypted with its machine id (the convention AltStore-family apps expect),
  and the anisette identity the session signed in with (since 1.5.2 there is
  one per ADI library, Android and Windows, which can't use each other's:
  `remote_v3::state_key_for` names the session server's). Swift writes it into
  SideStore's Documents in the
  same step as the pairing file (step 8), and SideStore's
  `LaunchViewController.detectAndImportAccountFile` adopts it and deletes it.

  **Why:** SideStore only signs with a certificate it holds the private key for.
  Ours never leaves this app, so its first sign-in revokes ours, mints its own,
  and shows "Resign SideStore". Nothing else fixes that. In particular isideload
  *already* injects `ALTCertificate.p12` + `ALTCertificateID` into the bundle
  (`application.rs::apply_special_app_behavior`) — recent SideStore reads
  neither for itself, so that path is inert here. `Account.sideconf` is the one
  hand-off it still honours automatically.

  Two **vendored additions** back this: `CertificateIdentity::retrieve_existing`
  (isideload's `retrieve` mints a certificate when it finds no match, which on a
  free account means revoking the one in use — reading the identity must never
  be able to do that, so this returns `None` instead), and `pub mod state` in
  `anisette::remote_v3`, so the stored `AnisetteState` can be read back.
  `anisetteIdentifier`/`anisetteAdiBlob` are base64 of `keychain_identifier` and
  `adi_pb` — exactly the encoding both sides already send the anisette server.
  The Apple ID password is omitted: it isn't needed to keep the certificate, and
  the file is plaintext JSON until SideStore consumes it.

  **Only builds that import it silently get the file.** SideStore's
  `ImportAccountAlertController` (2026-08-10) changed `detectAndImportAccountFile`:
  it now puts up an *Import Account* alert asking for a **file password**, accepts
  only the AES-GCM format `ImportExport.exportAccount` writes, never deletes the
  file, and records its checksum only once a decryption succeeds. Handing plaintext
  JSON to such a build means that alert on **every** launch, forever — it can never
  decrypt, so the checksum is never stored. iLoader shows no alert for the simple
  reason that it never writes the file (`install_sidestore_operation` places only
  `ALTPairingFile.mobiledevicepairing`), and step 8 now does the same when the
  hand-off can't land silently.

  `Engine.importsAccountConfigSilently()` decides, by scanning the SideStore
  binary in the signed bundle for `acctFileChecksum` — the `UserDefaults` key
  added in that same change, present as both a `#function` literal and an `@objc`
  accessor name. It is read off the binary rather than the version because the
  two don't track each other: LiveContainer's *stable* IPA bundles SideStore
  `0.6.4-20260714`, which still imports silently, while its nightly bundles
  `0.6.4-20260816`, which doesn't. Verified against all four shipping IPAs.
  Under LiveContainer the binary to read is the guest copy at
  `Frameworks/SideStoreApp.framework/SideStore`, where `build_github.sh` moves
  and dylibifies `SideStore.app`. When the check can't run, it errs towards not
  writing the file.

**Increased Memory Limit (since iLoader 2.4.1 does it):** the Install tab and
the Apps tab's refresh pass `si_sign_ipa` a `memory_limit` of 2, so isideload
enables that capability on the App ID before the profile is requested and the
app is signed with `com.apple.developer.kernel.increased-memory-limit`. If Apple
refuses, the app is signed without it. SideStore, LiveContainer+SideStore,
AltStore and StikStore are left out: they refresh themselves, and the App ID
SideStore registers each week doesn't get the capability on a free team
(SideStore issue #1616), so their next profiles would grant less than they're
signed with. Madeira passes 1 (required), Side by Side 0. See the vendored
isideload README, change 13.

**Which developer team signs:** an Apple Account is on the free team every
account has, and on a paid Apple Developer Program membership too when there is
one, its own or a company's. Until this change the first team Apple lists
signed. Now `si_apple_signin` and `si_cert_signin` take the team ID remembered
for the Apple ID (`AccountStore.team(for:)`, by email in lower case) and a
`SITeamCb`: the remembered team signs when the account is still on it, its only
team when it has one, and otherwise Rust asks the callback, which shows the team
sheet (`SigningTeams.swift`) in the sheet the 2FA prompt uses, takes it over once
the code has gone through, and blocks like a 2FA request. The pick is remembered
for an Apple ID saved in Settings › Account (swiping one there and tapping Team
forgets it, so the next sign-in asks again); Side by Side with someone else's
Apple ID keeps nothing. Closing the sheet stops the sign-in without trying other
anisette servers (`AppleSignInTicket.teamQuestionWasCancelled`).
- Free or paid is siboot's rule (`minis/src/team.rs` in FrizzleM/siboot), which
  is AltSign's, so AltStore and SideStore read teams the same way: a
  "Company/Organization" team is paid; an "Individual" one is free when its only
  membership's name contains "free", and paid with any other memberships;
  anything else is unknown and listed without a mark (`rust-core/src/team.rs`).
  isideload's `DeveloperTeam` drops `memberships`, so listTeams is asked once
  more for them, only when there's a question to ask. No two-team account has
  been seen yet, so the real membership names are unconfirmed.
- The sheet starts on the team that signed this SideInstaller, read from its own
  `embedded.mobileprovision` (`InstalledSigner`), when it's one of the account's
  teams, and otherwise on Apple's first. siboot asks the same question since
  0.19.0, and SideInstaller's bundle ID ends in the signing team's ID, so a copy
  siboot installed with another team keeps refreshing itself in place.
- Certificates and Entitlements sign in on the same team, so they show the
  certificates and App IDs of the team that signs.

**idevice version coexistence:** isideload pulls idevice **0.1.61** (crates.io,
behind its `install` feature, which is required because its feature-gating is
incomplete) while the rest of the app uses idevice **0.1.63** (git). The two
versions coexist as distinct crates (different symbol hashes, no collision). We
only call the sign-only path, which takes no provider and never touches
idevice, so isideload's 0.1.61 install code is compiled-but-unused.
*(2026-11-09: no longer true. The vendored isideload gates those uses behind
`install` (its README, change 15) and `rust-core` leaves `install` off, so only
the git idevice is built.)*

`SideStoreDownloader.swift` fetches the latest SideStore release IPA from the
GitHub API into `Documents/SideStore.ipa`.

**Verified here:** the account module compiles against isideload's API and the
whole tree cross-compiles for iOS; the SideStore download path is plain
URLSession (runs in the simulator).

**NOT verifiable here (needs a real Apple ID + 2FA + an Apple Developer
relationship):** the actual login, anisette handshake, cert/App ID/profile
creation, and signing. Real code, unverified until run with real credentials.

### Step 4 — install + finalize — code complete; device steps unverified

`DeviceConnection.swift` (idevice-ffi over the RSD tunnel from step 2):
- **Install:** `afc_client_connect_rsd` → recursively upload the signed `.app`
  bundle to `/PublicStaging/<name>.app` (afc_make_directory + chunked
  afc_file_write) → `installation_proxy_connect_rsd` →
  `installation_proxy_install_with_callback` (progress % streamed to the log).
- **Write pairing into SideStore:** `house_arrest_client_connect_rsd` →
  `house_arrest_vend_documents(bundleID)` → write the pairing file to
  `Documents/ALTPairingFile.mobiledevicepairing`. The bundle id is read from the
  signed bundle's Info.plist (isideload rewrites it to `<orig>.<teamID>`),
  falling back to `com.SideStore.SideStore`.
- **A custom IPA that is one of the app's own builds** (#108): where GitHub
  can't be reached, users bring the .ipa as a custom IPA.
  `IPALibrary.knownSource` tells SideStore, LiveContainer + SideStore and
  Madeira apart by the IPA's bundle id (published, or with a team id appended);
  LiveContainer counts only with `Frameworks/SideStoreApp.framework` inside,
  since plain `LiveContainer.ipa` carries no SideStore. The run then treats it
  as that build (`Engine.installedBuild`): pairing file and `Account.sideconf`
  where it reads them (under LiveContainer, `SideStore/Documents/`), the split
  pairing and anisette hand-offs, LiveContainer's certificate-import popup, and
  no App ID prompt, which the downloaded builds don't get either. The early,
  ahead-of-install pairing write stays off for custom IPAs; the one after the
  install covers it.

**Pairing-file format — resolved in 0.9.0 (was a documented caveat).** What the
RPPairing host produces is an **RPPairing** record (`public_key`,
`private_key`, `identifier`, `alt_irk`). That is all *our* tunnel needs, and all
StikDebug's sideloaded build reads — and nothing an AltStore-family app can
parse. SideStore hands its `ALTPairingFile.mobiledevicepairing` straight to
**minimuxer** (`AppBootManager.startMinimuxer`, via
`PairingFileManager.fetchPairingFile`), which wants a *classic* lockdown record:
`HostID`, `SystemBUID`, the host/root/device certificates and keys, `EscrowBag`,
`WiFiMACAddress`, `UDID`. Feather is the same.

iLoader ships **both records in one plist** (`pairing.rs::pairing_file` merges
`generate_lockdown_plist` with `generate_rppairing_plist`), and every reader
ignores the keys it doesn't know: idevice's `RpPairingFile::from_bytes` `remove`s
its four and drops the rest, and the classic side is a serde struct
(`RawPairingFile`) with no `deny_unknown_fields`.

We now build the same merged file, minting the missing half **on-device**:

- `DeviceConnection.lockdownPairRecord` runs the classic `Pair` handshake over
  the RSD tunnel that is already open — `lockdownd_connect_rsd` →
  `lockdownd_pair` → `idevice_pairing_file_serialize`. All of it is idevice-ffi
  that was already linked (`pair` is in our feature list); **no Rust change and
  no `build-rust.sh` run was needed**. idevice retries `Pair` internally on
  `PairingDialogResponsePending`, so the call blocks while the device shows its
  Trust prompt.
- Then `EnableWifiDebugging` in `com.apple.mobile.wireless_lockdown`, as iLoader
  does — without it lockdownd answers over USB only, and every app reading this
  record reaches it over a loopback. Tried **without** a session first: over USB
  (iLoader's route) `SetValue` in that domain needs `StartSession`, but over RSD
  the stream is already inside the RPPairing tunnel and the endpoint is the
  *trusted* one, while `StartSession` there would have to negotiate a second TLS
  session inside the first. A session attempt is the fallback.
- `CompositePairingFile` (in `PairingTargets.swift`) merges the two and stamps in
  the `UDID`, which the `Pair` response doesn't carry and minimuxer needs. Output
  is **XML, never binary**: SideStore reads the file with `String(contentsOf:)`
  and hands minimuxer the *string*.
- The classic half is cached (`Application Support/lockdown_pair_record.plist`,
  keyed on the device UDID) because minting it is interactive and spends a
  pairing slot; the merge itself is redone per write. A new RPPairing record
  invalidates the merged file but keeps the cached classic one.

Our lockdown half has the **same key set as iLoader's**: iLoader also
round-trips usbmuxd's record through `PairingFile::serialize()`, i.e. the same
`RawPairingFile` ten fields. Only the provenance differs — lockdown `Pair` over
RSD instead of a usbmuxd cache entry.

**Fallback, not a hard dependency:** if any of that fails, the write proceeds
with the RPPairing record alone — what shipped before — and says so in the log.

**Checked on hardware (iPhone 16, iOS 27, 2026-09-30): lockdownd refuses it.**
`Pair` on `com.apple.mobile.lockdown.remote.trusted` answers `InvalidHostID`
(FFI code 18) straight away, with no Trust prompt, and no variant of the request
does better (see
[iOS 27: lockdownd won't pair on-device](#ios-27-lockdownd-wont-pair-on-device-over-any-route)).
On iOS 27 the attempt is now skipped and every write hands over the RPPairing
record alone. SideStore nightlies from 2026-09-20 on can load that (see
[SideStore's split pairing files](#fix-sidestore-nightly-asks-for-the-pairing-file)).

**Transport used (whole pipeline):** the classic lockdown *transport* (usbmuxd,
port 62078) is **not** used — every device service (lockdown info,
installation_proxy, AFC, house_arrest) is reached over the in-process RSD tunnel
(`tunnel_create_rppairing` → software TCP stack → RSD handshake), authenticated
by the RPPairing record. The classic lockdown *protocol* is spoken over that same
tunnel for exactly one thing: minting the pair record other apps read
(`lockdownd_pair` on `com.apple.mobile.lockdown.remote.trusted`).

**Verified here:** full app builds for **both** the iOS *simulator* and a
*generic iOS device* (no undefined/duplicate symbols despite idevice 0.1.61 +
0.1.63 coexisting); launches; logging spine + ping + network scan + SideStore
download all run in the simulator.

**NOT verifiable here (needs a physical iOS 17.4+ device + LocalDevVPN + a real
Apple ID):** the AFC upload, installation_proxy install, and house_arrest write.
Real code, unverified until run on hardware.

#### Fix: house_arrest write double-free + write never committing

On-device, writing the pairing file crashed with `SIGABRT`
(`POINTER_BEING_FREED_WAS_NOT_ALLOCATED`) inside
`house_arrest_client_free`, and the file never landed. Root cause (confirmed in
idevice-ffi source): `house_arrest_vend_documents` does `Box::from_raw(client)`
— it **consumes** the HouseArrestClient (success *and* failure) and moves the
underlying `Idevice` into the returned AfcClient. The old code's
`defer { house_arrest_client_free(ha) }` then double-freed that `Idevice`. Fixes
(write path only):
- Never free the HouseArrestClient after vend (it's consumed); free only the
  AfcClient, once. `afc_file_close`/`afc_client_free` each consume their handle
  → called exactly once each.
- Check the `afc_file_close` error (AFC commits on close; the old defer ignored
  it — the silent-write bug).
- **Read-back verification:** re-open the path read-only and assert the byte
  length equals what was written (`afc_file_read_entire`); throw on mismatch.
  Returns the verified byte count, surfaced in the log.

#### Fix: house_arrest write `Afc(PermDenied)` — wrong AFC path

After the double-free fix, the install succeeded end-to-end (0→100%) but the
pairing write failed `Afc(PermDenied)` on the first `afc_file_open`. Cause:
idevice's `vend_documents` roots AFC at the app **container**, not at the
Documents dir, so writing bare `ALTPairingFile.mobiledevicepairing` targets the
(non-writable) container root. Fix (matches iLoader's `place_file`): write to
**`/Documents/ALTPairingFile.mobiledevicepairing`** (with the `/Documents/`
prefix), `mk_dir` the parent first, and open with `AfcWr`.

#### Fix: house_arrest `ApplicationLookupFailed` — wrong bundle id

In a session where the user hadn't just signed, `signedAppPath` was nil and the
code fell back to the hardcoded `com.SideStore.SideStore` — but isideload
installs the app as **`com.SideStore.SideStore.<teamID>`**, so `VendDocuments`
returned `ApplicationLookupFailed`. Fix: resolve the *installed* bundle id from
**installation_proxy** (`DeviceConnection.findInstalledBundleID(base:)` — exact
or `<base>.<teamID>` match), falling back to the signed bundle's id only if the
lookup finds nothing. The installation_proxy is the source of truth for what's
actually on the device.

#### Fix: LiveContainer nightly stopped shipping `LiveContainer+SideStore.ipa`

Checked 2026-09-02 against the live releases. Three of the four derived download
URLs answer 200; `releases/download/nightly/LiveContainer+SideStore.ipa` answers
**404**. LiveContainer's rolling `nightly` release now carries only
`LiveContainer.ipa` (4.7 MB) and `apps_nightly.json`, and that plain IPA has no
`Frameworks/SideStoreApp.framework` — verified by unzipping it — so it cannot
stand in. Its own `apps_nightly.json` advertises only the plain build, and
`apps_ss_lc.json` (release tag `1.0`) still points at 3.6.1, so upstream doesn't
treat a nightly combined build as a shipped product. The CI *artifact*
`LiveContainer+SideStore.ipa` (34 MB) does exist on the 2026-08-30 run, and every
step of that run reported success — it just never reaches the release.

`selectAsset` was already safe here: its loose fallback needs `"sidestore"` in
the asset name, so it does **not** silently pick the SideStore-less
`LiveContainer.ipa`. The run failed with `noIPAAsset` instead.

Fix: `SideStoreDownloader.fetchViaReleaseScan` — a third rung under the derived
URL and the `releaseAPI` lookup. On `noIPAAsset`/`noRelease` only (never a rate
limit, an outage or an undecodable body — see `DownloadError.isChannelEmpty`) it
reads `/releases?per_page=20` and takes the newest release whose assets
`selectAsset` matches. A `stable` request skips pre-releases, so asking for
stable is never answered with a nightly; a `nightly` request takes whatever is
newest. The file is filed under the *served* release's track (`Fetched.channel`),
so a tagged build is never listed in Downloads as a nightly.

Verified against the live API by compiling the real file with a test `main`
(there is no test target): LC nightly → release 3.8.0 →
`LiveContainer+SideStore.ipa` → filed as `LiveContainer+SideStore.ipa`; LC stable
→ 3.8.0; SideStore nightly → the `nightly` prerelease; SideStore stable → 0.6.3,
skipping the prerelease. Full `downloadLatest` run for LC nightly downloads 35.4
MB from 3.8.0 and logs each rung.

The fallback is a good one, not just a survivable one: 3.8.0's guest SideStore is
`0.6.4-20260714`, whose binary has **no** `acctFileChecksum`, so the certificate
hand-off still lands silently there — better than the nightly would have been.

#### Fix: SideStore nightly asks for the pairing file

SideStore nightly `0.7.0-20260920.1479+0dd743f7` (develop `0dd743f7`, "implement
dual pairing file support") changed how it finds the pairing file, and prompted
for a manual import right after a SideInstaller install. Its
`PairingFileManager.fetchPairingFile` now:

- reads only `Documents/PairingFile_Lockdown.plist` or
  `Documents/PairingFile_RemoteRP.plist`. `ALTPairingFile.mobiledevicepairing` is
  migrated only by `MaintenanceManager` pass 7, which runs once per app group
  (the counter lives there and outlives reinstalls) and *after* the boot check;
- returns nil while `isPairingReset` is true, which `registerDefaults` makes the
  default, and only an import sets it to false;
- picks the file through `preferredPairingProtocol`, then `activePairingProtocol`,
  and neither is set until an import;
- hands minimuxer the string, whose `PairingFileParser.parse(preferred: nil)`
  throws `.ambiguous` for a file with both records, i.e. our merged file.

Confirmed from the phone's own SideStore console log: `Minimuxer check completed`
1 ms after starting, with no `startMinimuxer` in between.

Fix: `SideStorePairingHandoff` (in `PairingTargets.swift`) splits the file into
a lockdown-only and an RPPairing-only record (XML, UDID stamped in), and
`Engine.handOffSplitPairing` writes each under its new name next to the legacy
file, then sets `isPairingReset = false` and `activePairingProtocol` (lockdown
when there is a complete record, else `rppairing`) in SideStore's preferences
plist. That is what SideStore's own import does. `preferredPairingProtocol` is left
alone. Standalone SideStore's plist is `Library/Preferences/<bundle id>.plist`,
reached with `house_arrest_vend_container` (development-signed apps only);
LiveContainer's guest keeps it at `Documents/SideStore/Library/Preferences/
com.SideStore.SideStore.plist` (signing leaves framework ids alone). Older
builds read `ALTPairingFile` from Documents regardless of `isPairingReset`, so
the extra files and keys are harmless there. LiveContainer nightly's guest is
still `0.7.0-20260918` (legacy).

**cfprefsd caches.** Once SideStore has run, editing its plist directly, even
via a staging file and rename, isn't seen on the next launch: cfprefsd keeps
serving its cached copy. A reinstall through installd drops that cache. Verified
on the iPhone 16: after a full Nightly install the next launch logged
`startMinimuxer() entered`, then `connection test SUCCEEDED` in `.rppairing` mode,
and no prompt. The Pairing tab's write (no reinstall) says so in the log.

#### iOS 27: lockdownd won't pair on-device, over any route

Probed on the iPhone 16 (iOS 27, 2026-09-30) with a temporary hook that sent raw
lockdown requests over the working RPPairing tunnel and logged lockdownd's whole
reply, not just idevice's mapped error. `com.apple.mobile.lockdown.remote.trusted`
and `.remote.untrusted` (both listed in the tunnel's RSD) answered identically:

| `Pair` request | answer |
|---|---|
| no `PairRecord` | `MissingPairRecord` |
| empty `PairRecord` | `InvalidResponse` |
| any `PairRecord` with a `HostID`, `PairingOptions {ExtendedPairingErrors: true}` | `InvalidHostID` |
| the same without `ExtendedPairingErrors` (absent or false; `ProtocolVersion` "2", "1" or absent) | `PasswordProtected`, with the phone unlocked |

The `HostID`s tried: the stored `lockdownHostID`, and the RPPairing `identifier`
uppercased and as stored (lowercase). Each went with idevice's full record
(certificates plus `DevicePublicKey`, `RootPrivateKey`, `WiFiMACAddress`), with
libimobiledevice's set (certificates, `HostID`, `SystemBUID`), and as `HostID` +
`SystemBUID` with no certificates at all. Same answer every time, so lockdownd
decides before it looks at the certificates, and no request brought up a Trust
prompt.

So `InvalidHostID` isn't about the HostID. It is lockdownd's extended code for
"won't pair on this connection", and `PasswordProtected` is the legacy code for
the same refusal. Apple's own host side never asks: MobileDevice.framework logs
"Pairing over RemoteXPC is only supported for devices discovered via
MobileDevice" and pairs those through RemotePairing, and pymobiledevice3's
`RemoteLockdownClient.pair` raises `NotImplementedError` ("RemoteXPC lockdown
version does not support pairing operations"). A connection over RSD is trusted
because of its RPPairing record, and lockdown `Pair` isn't available on it.

lockdownd's own port (`lockdownPairRecordDirect`) is closed too:

- `10.7.0.1:62078` (the LocalDevVPN peer): the TCP connection opens, then
  lockdownd resets it on the first request, `QueryType`, which normally needs no
  pairing. `EnableWifiDebugging` and `EnableWifiConnections` were both already
  true (read over RSD from `com.apple.mobile.wireless_lockdown`), so they aren't
  the cause. This reset isn't new in iOS 27: it started with 26.4, see
  [iOS 26.4+: lockdownd hangs up on loopback connections](#ios-264-lockdownd-hangs-up-on-loopback-connections).
- `127.0.0.1:62078` and the phone's own Wi-Fi address: `connect` fails with EPERM
  (os error 1). iOS doesn't let an app reach them.

A classic record would therefore be useless on iOS 27 even if the app had one.
minimuxer and Feather reach lockdownd at `10.7.0.1:62078`, and
[SideStore#1532](https://github.com/SideStore/SideStore/issues/1532) reports
exactly this with a complete computer-made record on iOS 27: every connection
closed within 1–2 ms. Side by Side sees the same reset over Wi-Fi.

**What changed:** `Engine.canMintLockdownRecord` is false on iOS 27 and later
(since 2026-10-21 from iOS 26.4, see the next section).
There, `placementPairingFile` no longer attempts `Pair`: it hands over the
RPPairing record and logs one plain line, with no round trip and no ⚠️. And
`DeviceConnection.connect` no longer falls back to
`connectByMintingLockdownRecord` when the RPPairing tunnel fails. A pairing file
that already carries a lockdown record (imported) still goes over as it is. On
iOS 27, apps that only read a classic record can't be served: SideStore before
nightly 0.7.0-20260920, LiveContainer's built-in SideStore (0.7.0-20260918), and
Feather. They need a build that reads the RPPairing record. Before iOS 26.4 the
attempt still runs; it is only reachable with an imported RPPairing-only file,
and whether it works there is unverified (pymobiledevice3's refusal suggests it
doesn't).

#### iOS 26.4+: lockdownd hangs up on loopback connections

From iOS 26.4 beta 1 (February 2026) on, lockdownd hangs up on a connection that
reaches it through a loopback VPN, on its first request. A classic lockdown pair
record (jitterbugpair, `pymobiledevice3 lockdown pair`, idevice_pair's “Lockdown”)
can't open the CoreDeviceProxy route there, however fresh; re-pairing on a
computer only makes another one that fails the same way. It's the reset measured
at `10.7.0.1:62078` on iOS 27 above, which began with 26.4. An RPPairing record
connects, over `connectRemotePairing`.

**What the lockdown route sees (verified on the Mac, 2026-10-21).**
`tunnel_create_usb` → `CoreDeviceProxy::connect` → TCP to :62078 → `start_session`,
whose first request is a `GetValue(ProductVersion)` it doesn't check (`.ok()`),
then `StartSession`. A scratch probe (not committed) ran exactly that with the
vendored idevice against a stand-in lockdownd on 127.0.0.1:62078:

| stand-in | FFI message |
|---|---|
| RST on the first request (`GetValue`) | `Socket(Os { code: 32, kind: BrokenPipe, message: "Broken pipe" })` |
| FIN on the first request | `Socket(Custom { kind: UnexpectedEof, error: "early eof" })` |
| RST or FIN right after accept | `Socket(Os { code: 32, kind: BrokenPipe, … })` |

A reset that lands between a write and its read reads `ConnectionReset` instead,
as in AirCard's log below. `DeviceConnection.lockdownHungUp` matches all of them.

**Reported, not verified here (no iOS 26.x device; the iPhone 16 runs 27):**

- [StikDebug](https://github.com/StikDebug/StikDebug)'s README from 2026-02-26:
  on 26.4 beta 1 lockdownd “appears to be dropping connections”, breaking the
  device's loopback connection to itself. Dropped on 2026-03-30 with
  3.1.0, after jkcoxson's “Replace lockdown code with rppairing” (StikDebug#354,
  “tested it on my device”): `rp_pairing_file_read` +
  `tunnel_create_rppairing(10.7.0.1:49152)`, i.e. our `connectRemotePairing`, whose
  first candidate is the same address.
- [LiveContainer#1152](https://github.com/LiveContainer/LiveContainer/issues/1152)
  (hugeBlack, member, 2026-03-29): nightly LC+SS reads RPPairing files, which
  “bypasses 26.4 lockdownd connection limits”; users then refresh with LocalDevVPN
  alone on 26.4.
- [SideStore#1174](https://github.com/SideStore/SideStore/issues/1174) and
  [#1222](https://github.com/SideStore/SideStore/issues/1222) (26.4; members: the
  nightly “should work with no changes to LocalDevVPN”),
  [#1460](https://github.com/SideStore/SideStore/issues/1460) (26.6.1: a misagent
  BrokenPipe went away once a lockdown file was swapped for an RPPairing one from
  idevice_pair 0.1.14),
  [#1656](https://github.com/SideStore/SideStore/issues/1656) (“On versions iOS 26.4+,
  Lockdown is not supported”).
- [AirCard-iOS#67](https://github.com/Mak5er/AirCard-iOS/issues/67) (26.6.2,
  official LocalDevVPN 1.3.0 at 10.7.1.1/32 ↔ 10.7.0.1/32, fresh jitterbugpair file):
  `QueryType` gets `Socket(Os { code: 54, kind: ConnectionReset, … })`, then
  `StartSession` `Socket(Os { code: 32, kind: BrokenPipe, … })`; SideStore on the
  same phone, “Broken pipe / early eof”.

So the cutoff is 26.4 and it holds through 26.6.2 at least; nothing says why.

**Making an RPPairing record on a computer** (read in each tool's source, not run):

- idevice_pair from v0.1.9-rppairing (2026-03-28); in 1.x, Remote pairing → Create →
  Save to file… writes `pairingFile.plist` with `RpPairingFile::to_bytes`
  (`public_key`, `private_key`, `identifier`, `alt_irk`), which is what
  `rp_pairing_file_read` and `PairingFileKind` read. It pairs over USB through
  remotepairingdeviced's lockdown channel, for iOS 17.4+.
- iLoader from PR #360 (2026-04-04): Manage Pairing File › Export (Not Recommended)
  writes `pairingFile.plist` with its lockdown and RPPairing dicts merged (iOS 17.4+),
  the same shape as `CompositePairingFile`.
- pymobiledevice3 `remote pair`: its record holds `public_key`, `private_key` and
  `remote_unlock_host_key` but no `identifier` (the host id is `generate_host_id()`,
  never stored), so idevice refuses it (`missing_field("identifier")`). Not suggested.
- Neither idevice_pair nor iLoader writes into SideInstaller (both look apps up by
  display name in fixed lists), hence Save/Export and an import.
- SideStore answers `sidestore://pairing` with its active pairing file
  (`ExportPairingFileHandler` → `PairingFileManager.fetchPairingFile()`), so a
  SideStore nightly set up with an RPPairing file hands that over through “Get it
  from SideStore”.

**Workarounds for a lockdown record, not offered in the app:**

- An IKEv2 “Personal VPN” connected first, then LocalDevVPN (SideStore#1174, #1222,
  March–April 2026): many confirmations on 26.4 with SideStore stable, some
  failures, no explanation. It needs a third-party VPN carrying all traffic, and
  SideStore's members call it “just a workaround”.
- LocalDevVPN's addresses inside the Wi-Fi subnet: the fork
  [SiamSadik/LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN) (cdbc3299,
  1b9ff7a2, 2026-08-15/16, AI-assisted) says 26.4+ lockdownd “resets connections
  whose source IP is outside the WiFi subnet”, and puts the tunnel's own address and
  the peer on unused Wi-Fi addresses as /32s, the peer as a /32 included route so it
  beats the Wi-Fi /24. Its one release (v1.1.6-custom, 234 downloads, built on the
  pre-rewrite app) has no issues and no confirmations; a blog repeats it as early
  reports on 26.4 beta 2. Official LocalDevVPN 1.3.0 can make the same layout with no
  fork: its `PacketTunnelProvider` gives the utun `TunnelIfaceIP` with that address's
  own prefix and routes only `TunnelPeerIP`, and `CIDRValidator` takes any unicast
  address with an explicit prefix. In its Settings › Network Configuration, Tunnel IP
  and Device IP would be two unused Wi-Fi addresses with /32, and our Device IP the
  second one (`NetworkStatus` accepts it: the routing-table check sees a utun source).
  The first edit there raises a one-time Warning whose “I Understand” resets both
  fields to the defaults, so they have to be typed again after it. Not offered: it's
  unconfirmed, and the addresses would change with every Wi-Fi network.

**What changed:**

- `Engine.lockdownWorksOverLoopback`, false from 26.4.
- `DeviceConnection.connect`: with both records, RPPairing goes first from 26.4. A
  lockdown-route failure that `lockdownHungUp` matches becomes a `TunnelError` with
  `lockdownRouteClosed` and advice (`ErrorHelp.explained`), only for this iPhone's
  own link: Side by Side (`allowLockdownMinting: false`) reaches another iPhone,
  whose iOS may be anything, and still falls through to pairing again.
  `repairingCouldHelp` is `Engine.deviceCanSelfPair` for it: on iOS 27 Install's
  re-pair makes the RPPairing record that fixes it, and below 27 nothing pairs.
- `Engine.pairAndConnect`, below 27: `Guides.remotePairingNeeded` (idevice_pair's
  Remote pairing steps, “Get idevice_pair”) and a short error. On 27, a log line
  saying why, then the re-pair as before.
- `Guides.importPairing` from 26.4: the same idevice_pair steps instead of
  jitterbugpair's.
- `canMintLockdownRecord` false from 26.4 (was 27): no minting fallback in `connect`
  (its stored record and `lockdownPairRecordDirect` both go through :62078), and
  `placementPairingFile` hands over the RPPairing record alone, since other apps
  read a lockdown record through the loopback too.
- Developer Mode's lockdownd fallback is skipped from 26.4, and `adoptPairingFile`
  logs a warning for a lockdown-only import.

None of this has run on a 26.x device, and the new copy hasn't been seen on
screen.

#### Port 49152 refused on iOS 27 (issues #56, #100)

Both reports: an iOS 27 iPhone with a pairing file it made itself, LocalDevVPN
up, and `tunnel_create_rppairing` to 10.7.0.1:49152 answered with a reset
(ECONNREFUSED, kind `RsdUnreachable`), so nothing on the iPhone accepted on that
port. #56 says pairing again didn't help. #100's log shows SideInstaller running
inside LiveContainer: its Live Activity failed with “Target does not include
NSSupportsLiveActivities plist key” and its continued-processing task with
BGTaskScheduler error 3 (not permitted), although the released 1.6.1 IPA has both
keys. LiveContainer's own Info.plist has neither. What that does to the tunnel is
unknown. Local Network permission isn't it: TN3179 counts VPN interfaces out of
local network privacy.

49152 is just the first port iOS hands out. On a Mac, rapportd holds it. On an
iPhone remotepairingd normally gets it, which is why StikDebug and SideInstaller
can dial it blind, but whatever binds first at boot wins. The iPhone advertises
its real listener as `_remotepairing._tcp` (pymobiledevice3 takes the port from
there), and a local browse sees the iPhone's own services (on a Mac, `dns-sd -B`
lists the Mac's own adverts on interface 1). So after a refused 49152,
`DeviceConnection.connectRemotePairing` calls
`NetworkStatus.ownRemotePairingAdvert` (NetServiceBrowser on the main run loop,
3 s at most; only a service resolving to one of this iPhone's own addresses
counts), logs what it found, and dials the advertised port when it's another one.
Side by Side never does this, since its listener isn't this iPhone's.
`_remotepairing._tcp` is in NSBonjourServices, and LiveContainer's plist lists it
too.

The refusal advice now reads `security.mac.amfi.developer_mode_status`
(`Engine.developerModeIsOn`): off says so plainly, on drops the “turn on
Developer Mode” advice and suggests pairing again, then a restart. Where the
sysctl can't be read, the old text stays. Problem reports list Developer Mode,
Device IP and whether SideInstaller runs inside LiveContainer.

Checked in the iPhone Duo simulator (2026-10-27), with a fake advert from
`dns-sd -R … _remotepairing._tcp local. 49170` and a hook dialling a closed port
first: the refusal, the lookup (“port 49170”), the second dial and the Developer
Mode text (the simulator reads the Mac's sysctl, 1) all behaved. Never run on an
iPhone: whether its own advert is seen from inside the app, whether the sysctl
can be read there, and whether either report's iPhone had moved its port.

**Knocking for the listener (2026-11-18).** That day siboot users with Developer
Mode on and LocalDevVPN connected were refused at 10.7.0.1:49152, while another
iPhone on the same Wi-Fi advertised `_remotepairing._tcp` on 55021. iOS hands
TCP ports out in order from 49152, not at random (`net.inet.tcp.randomize_ports`
is 0, as on a Mac), so remotepairingd's listener gets 49152 only when it binds
first; started later, it gets the next free one. siboot 0.19.1 knocks on the
other dynamic ports for it, and SideInstaller now does the same when 49152
refuses and the advert gives no port, or its port refuses too:
`DeviceConnection.knockForListener` calls `si_find_pairing_port`
(`rust-core/src/pairing_port.rs`, siboot's `reach`/`search`/`knock` from
`minis/src/preflight.rs`). In Rust rather than Swift because the answer that
counts is RPPairing's handshake, which idevice already speaks, and because the
search can be tested against loopback stand-ins there.

- It knocks on 49152–65535 except lockdownd's 62078 and the ports already
  refused, in order, 32 connections at a time: 2 s to connect, then 3 s for the
  answer to RPPairing's first message (`attemptPairVerify`, which only the
  listener answers). The first port that answers is dialled with
  `tunnel_create_rppairing_multihost`, as before.
- It stops after 64 connections in a row that neither refuse nor connect
  (LocalDevVPN went), once more than 48 ports take the connection without
  answering (another VPN or a proxy answers for the address), and after running
  out of descriptors or buffers 256 times. Each of those (EMFILE, ENFILE,
  ENOBUFS, EADDRNOTAVAIL, EAGAIN) halves the width, down to 4, and the port is
  knocked on again later.
- From a Mac over Wi-Fi, iOS refused all 16,382 closed ports in 24 s at 32
  wide, with no rate limiting (siboot's measurement).
- The port found, by the advert or the knock, is remembered
  (`movedListenerPort`) for the next connect in the same run of the app, which
  dials it first and falls back to 49152 when it refuses; an install connects at
  least twice. A restart, which moves the listener, ends the run too.
- Side by Side never knocks (`findsMovedPort` is false there): its listener is
  another iPhone's.
- The log gets a line when the knock starts, one at each quarter of the ports,
  and the result, like the advert lookup's:

      Knocking on this iPhone's other ports: found on port 55021 (RPPairing, wire protocol 26) after 5869 of 16381 ports, in 9.2 s.

  A search that finds nothing ends on the same refusal advice as before, for
  49152 or the advertised port.

Tested in rust-core: a fake listener that answers the handshake as the iPhone
does, one that takes the connection and says nothing, one that answers HTTP, and
closed ports, plus scripted knocks for each stop and the narrower retry. The
simulator build compiles the Swift side. Never run on an iPhone: how fast
LocalDevVPN carries 32 knocks at once, and whether the app's descriptor limit is
ever reached, are unmeasured.

**Probing before the dial (2026-11-18).** Only a refusal started the search,
and `tunnel_create_rppairing_multihost` has no time limit. So when something
else held 49152 and took the connection without a word, as the iPhone's other
listeners do, the dial waited for its handshake answer for ever; when it
answered something else, the dial failed as `TunnelFailurePairVerify`, whose
advice is to pair again, and Engine paired again once for nothing when the
pairing file was a reused one. Now, on this
iPhone (`findsMovedPort`), `connectRemotePairing` probes each port before it
dials it: `probeListener` calls `si_probe_pairing_port`, the knock with siboot's
first-dial limits, 8 s to connect and 10 s for the answer to `attemptPairVerify`
(the message the dial sends first: `RemotePairingClient::connect` starts with
it).

- Answered: dialled. Refused, or failed at once some other way (no route,
  EPERM, out of descriptors): dialled too, since the dial gets the same answer
  at once and its error says why, so the refusal handling and its advice stay
  as they were.
- Took the connection without answering as the listener, by saying nothing
  within 10 s or something else: not dialled, and passed over like a refused
  port. The remembered port falls back to 49152, 49152 goes on to the advert
  and the knock, and the knock skips it. When the listener is on no port, the
  error is `RsdUnreachable`, so nothing pairs again, with advice of its own:
  something at the address took the connection but didn't answer as the
  pairing port; check that LocalDevVPN is the VPN that's on and that Developer
  Mode is on, then restart the iPhone. A new string, in all nine tables.
- Neither took nor refused the connection within 8 s: not dialled, and nothing
  else is tried. The error is the unreachable one (“Couldn't reach the device
  at … at all”), after 8 s where the dial waited for the OS to give up on the
  connect (`net.inet.tcp.keepinit`, 75 s on a Mac).
- A probe is logged only when the port doesn't answer, as in

      Port 49152 took the connection but didn't answer the RPPairing handshake within 10 s. This iPhone's remote pairing advertisement: …

  On the usual path it costs one more connection and round trip through
  LocalDevVPN before the dial: milliseconds.
- Side by Side isn't probed (`findsMovedPort` is false), so its dial still has
  no time limit.

Tested in rust-core with the same stand-ins: the probe's result and log line
for the RPPairing one, a closed port, the silent one and the HTTP one, the first
and second through the C call too, and the silence and failures from scripted
knocks. Never run on an iPhone. The dial comes milliseconds after the probe's
connection closes; siboot has probed before pairing since its first Open Minis
version (2026-11-10), and its 0.18.0 paired an iPhone, but its next connection
comes later.

## Resuming downloads

Every IPA download from GitHub — SideStore, LiveContainer + SideStore, the
LiveContainer mirror copy, a version picked under Advanced, Madeira's Actions
build — goes through `SideStoreDownloader.fetch`, which runs `ResumingDownload`
(since 2026-10-29; before, a single `URLSession.download` that started over on
any failure, retried twice by `perform`). Pasted links (`fetchDirect`) don't.

- One data task per attempt writes straight to a temp file. The start link
  (`github.com/<repo>/releases/download/…` or nightly.link) redirects to a
  signed storage URL (`response.url`), and a later attempt asks that URL for
  `Range: bytes=<saved>-`. When it refuses (expired), the next attempt goes back
  to the start link, the Range carried through the redirects, without a pause.
- The rest must be of the same file. A 206 has to start at the saved byte and
  carry the ETag the file began with; otherwise, and for a 200 or a 416, the
  saved part is dropped and the file starts over. `If-Range` is sent too, but
  GitHub's release storage ignores it: given a stale ETag it still answered
  206 (checked 2026-10-29), so the ETag comparison is what catches a nightly
  replaced mid-download.
- Until something has answered, it behaves as the download always did: a 60 s
  request timeout, a timeout fails at once (where GitHub is blocked, more waits
  would only multiply it), and a dropped or refused connection or a 5xx is
  tried again after 1 and 3 s. Once the file is arriving, the idle timeout is
  30 s and attempts in a row that get no new byte pause 2, 4, 8 and 15 s, then
  give up with the last error. An attempt that got new bytes pauses 1 s.
- A refusal that says when to come back (Retry-After, or GitHub's rate-limit
  headers) is passed on, not retried, as before. A 4xx from the start link (a
  missing asset: the API fallback takes over) fails at once, as does a TLS
  failure or any error `passing` doesn't list.
- The ETag ends up in the ledger, as before, so `unchangedDownload` still skips
  a file GitHub serves unchanged. The log's "HTTP 200 for … — N bytes, release
  …" line says 206 and "resumed n×" after a resume.

Release storage (`release-assets.githubusercontent.com`) answers Range through
both redirects with the asset's ETag; its links carried an expiry about 50
minutes out. Tested against a local server that drops, stalls, expires links
after one use, ignores or misplaces the Range, swaps the file's ETag, refuses
with 503 or 429 + Retry-After, never answers, or isn't there; and live against
SideStore, LiveContainer + SideStore and the mirror.

## Madeira

[Madeira](https://github.com/willfaust/Madeira) (Windows PC games through Wine and
FEX) is a fourth `InstallSource`. Four things differ from SideStore.

**The download.** Since 1.6.5 Madeira has both channels, like SideStore, but
only once upstream has a full release from 0.2.0 on
(`InstallSource.firstStableVersion`; `isStableRelease(tag:)` counts "v0.2.0",
"0.2.1" and "v1.0", not "v0.2.0-beta"). Until then `channels(stableReleased:)`
offers Nightly alone, so the picker stays hidden and Madeira installs its CI
build, as in 1.6.2–1.6.4. `Engine.checkStableRelease` asks GitHub whenever
Madeira is picked (`SideStoreDownloader.hasStableRelease`: one HEAD on
`releases/latest`, no API call) and keeps the answer in the `stableReleased`
default, so the picker shows straight away on the next launch; no answer keeps
what was known, and the answer isn't applied during a run. `latestAsset` also
refuses a stable download of an older release (`noRelease`).

Stable is upstream's newest full release: its tag is read off where
`github.com/willfaust/Madeira/releases/latest` redirects (no API call), and the
asset is named after it (`assetFileName(forTag:)`: `Madeira-0.1.3.ipa` on
`v0.1.3`), saved as `Madeira.ipa`; when that 404s, the releases API is asked,
as for the others. Nightly is the newest CI build of upstream's main branch
(`InstallSource.actionsBuild(.nightly)`): the `Madeira-ipa` artifact that
willfaust/Madeira's "Build IPA" workflow (`build.yml`) uploads on every push, a
zip holding `Madeira.ipa`. Upstream's newest release, 0.1.3, predates the
self-refresh (willfaust/Madeira#264, merged 28 October 2026) and lacks the
`MadeiraSigningAccountVersion` key, which is why Stable waits for 0.2.0. A
release without the key would be refreshed under Tools › Sideloaded apps like
any other app. In 1.6.2–1.6.4 Latest was the CI build and there was no channel
picker; before 1.6.2 Madeira came from releases of the fork FrizzleM/Madeira.

For Nightly: GitHub serves artifacts only to a signed-in account (the API's
`/zip` answers 401), so:
- One unauthenticated API call, `actions/artifacts?name=Madeira-ipa&per_page=100`,
  lists the uploads with each one's commit and the SHA-256 GitHub recorded
  (`digest`). Only runs of `main` in the repository itself count: pull requests
  upload the artifact too, and a fork's runs have the fork as head repository
  even from a branch named `main`. An upload without a digest is skipped. When
  the newest 100 uploads are all pull requests', `newestRunBuild` asks for the
  newest successful `main` run of the workflow, then its artifacts (two calls).
- The zip is downloaded through nightly.link
  (`nightly.link/<repo>/actions/artifacts/<id>.zip`), which redirects to the
  file in GitHub's own storage, and must match that digest before anything is
  kept, so nightly.link can't substitute a file. Mismatch: `unverifiedBuild`;
  nightly.link refusing or unreachable: `relayFailed`.
- `IPALibrary.extractIPA(fromArtifact:to:)` streams the IPA out of the zip
  (stored, as the workflow uploads it with `compression-level: 0`, or deflated)
  and the IPA is saved as `Madeira-nightly.ipa`. The ledger records the zip's
  digest as its ETag, so a later run that finds the same build skips the
  download. At launch, `IPALibrary.moveMadeiraCIBuildsToNightly` renames a CI
  build 1.6.2–1.6.4 saved under the stable names (`Madeira.ipa`,
  `Madeira (e96065a).ipa`) to the nightly ones, told apart by that bare 64-hex
  ETag (a release's is GitHub's quoted one).

The API's hourly limit (60 per address) applies, unlike the release downloads;
when it's hit, the download step falls back to the `Madeira-nightly.ipa` an
earlier run left, as for any failed download. GitHub's artifact storage was about 4×
slower than release downloads from here (0.8 against 3.6 MB/s on 28 October
2026, the same with four parallel ranges), so the 183 MB zip takes minutes;
the prefetch during pairing and sign-in hides part of it. Artifacts expire after
90 days without a push to `main`.

**Resuming.** A second run that evening crawled at 0.13 MB/s, then went
silent and failed on URLSession's 60 s idle timeout with half the file there.
Every download now resumes: see "Resuming downloads" below. For the artifact,
nightly.link's storage link is valid for ten minutes (`st`…`se`) and answers 403
once expired (checked on the real one), which sends the download back to
nightly.link for a new one.

Advanced lists the releases under Stable and, under Nightly, the `main` builds
from that same API call, one per commit, labelled with the short commit and
build date ("e96065a · 28 Oct 2026"); a picked one is saved as
`Madeira-nightly (e96065a).ipa`. Listing both costs two API calls
(`ReleaseCatalog(source:releases:builds:)`); pre-releases aren't offered, since
Nightly never installs one.
`minimumOSMajorVersion` stops a run below iOS 26, which Madeira's JIT helper
needs.

**Signing.** Madeira isn't ready to play without
`com.apple.developer.kernel.increased-memory-limit`. For it `si_sign_ipa` gets a
`memory_limit` of 1: isideload enables that capability on the app's App IDs
before the profile is requested, and signing fails if Apple refuses (other apps
get 2, which signs without it then) (`Engine.isMadeira` also catches a Madeira IPA imported as custom, or
refreshed from Documents, by its bundle id: `com.willfaust.madeora` or any id under
it, such as the `.test` one of a local development build). Its `MadeiraJITHelper.appex` is signed like every
extension here, with the main app's profile and entitlements, and renamed with the
app (`<id>.<team>.JITHelper`), which is how Madeira finds it. Madeira picks its
background task from `BGTaskSchedulerPermittedIdentifiers` by taking the first
entry ending in `.download.*`, so the rebased entries now go first (vendored
isideload README, change 9).

**The pairing file.** Madeira keeps it in its Keychain, which nothing outside can
write, but moves in a file it finds at `Documents/StikJIT/pairingFile.plist`
whenever it reads the pairing (`JITPairingFileStore.moveLegacyFile`, there for
its builds from before the Keychain). `MadeiraPairingHandoff` writes the RPPairing
record there, cut down to its own keys. Madeira refuses anything else and would
leave it lying in Documents, so a file without that record isn't written. A
failed hand-off doesn't fail the install: Madeira can pair itself on iOS 27. A
Madeira IPA imported as a custom IPA is recognised by its signed bundle id and
handled the same way.

**The refresh.** Madeira renews its own profile, so it doesn't depend on
SideInstaller staying installed. What it lacks is an Apple sign-in, and
`MadeiraSigningHandoff` gives it one without the password: `si_signing_account`
reads the session's `com.apple.gs.xcode.auth` token, its adsid, the team and the
anisette identity (identifier and `adi.pb`) — what SideStore's `AuthManager`
keeps to refresh from — and the engine adds the anisette servers a sign-in
tries that are on the same ADI library as the one in use (only those can use
that identity), the one in use first (HTTPS ones, six at most), so one server
going away doesn't strand Madeira. It goes
as a binary plist to `Library/Application Support/SigningAccount.plist` in
Madeira's container (not Documents, which Files shows), and only when the signed
bundle's Info.plist has `MadeiraSigningAccountVersion`, so a token is never left
in a build that won't take it in. Madeira moves it to its Keychain at launch,
then per refresh: anisette `v3/get_headers`, `listAppIds` (or `addAppId` once the
weekly App ID has run out, plus the Increased Memory Limit capability),
`downloadTeamProvisioningProfile`, and misagent over the RPPairing tunnel with
its pairing file. Because a re-registered App ID has no app group, `si_sign_ipa`
takes an `app_group` flag and Madeira is signed without one; otherwise its later
profiles would grant less than its signature claims. When Apple rejects the
token (expiry, or a password change), Madeira says to install again, which hands
over a new one. The token's real lifetime wasn't measured here: Apple states it
in the token, SideInstaller logs it at sign-in, and Madeira shows it.

The Madeira side is a patch on the fork (branch `sideinstaller-refresh`):
`SigningRefresh.swift`, one function in its Rust library, docs and checks.
SideInstaller itself no longer renews anything for Madeira beyond "Refresh all".

Verified on the Mac, 2026-10-11: the downloader against GitHub (tag from the
redirect, URL, ETag reuse, the version list); `IPALibrary.appInfo` on the real
`Madeira-0.1.3.ipa`; the vendored signer on that IPA with a test certificate and
profile (`codesign --verify --deep --strict` passes, bundle ids and task
identifiers as above, the entitlement present); the hand-over format through
both apps' code; and Madeira's portal client against a stubbed Apple. Not
verified, since they need the iPhone and an Apple ID: an install of Madeira,
Apple granting the capability, Madeira picking up the pairing file and the
sign-in, and a refresh in Madeira (Apple accepting the handed token, the tunnel,
misagent accepting the profile).

## AltStore

AltStore Classic is the fifth `InstallSource` (`.altStore`, 2026-11-10, on the
redesign branch), offered on the Install tab and in Side by Side.

**The download** isn't from GitHub, which only has a "Notarized" 2.3: it comes
from AltStore's own source, `https://apps.altstore.io` (it redirects to
`cdn.altstore.io/file/altstore/apps.json`), the list AltServer installs AltStore
from (`ALTDeviceManager+Installation.swift`, `altstoreSourceURL`). AltServer
takes the first listed version whose `minOSVersion` the device meets; so does
`SideStoreDownloader.listedVersions` (`InstallSource.feed`, `AltSourceFeed`),
with the target's iOS in Side by Side and this iPhone's on the Install tab. Only
`com.rileytestut.AltStore` is read: the beta is listed under `.Beta`, which the
vendored isideload doesn't treat as AltStore (no `ALTDeviceID`, certificate or
app group). Versions before 2.3 (no Remote AltServer, so a computer for
everything) are left out (`AltSourceFeed.oldestVersion`). Each listed version
carries a SHA-256, which the download must match (`DownloadError.unverifiedListing`);
the ledger keeps it as the file's ETag, so an unchanged listing reuses
`AltStore.ipa`. One channel, Stable; Advanced lists the other versions from the
same source (`ReleaseCatalog(listed:)`). Errors name AltStore's host, not GitHub
(`sourceUnreachable`, `sourceStatus`, `badSource`, `noListedVersion`), and the
"Bring the .ipa yourself" GitHub card isn't shown for it.

**The pairing file.** AltStore 2.3 read it from its bundle, sealed with the
certificate's machine ID (`ALTPairingFile.dat`, isideload change 9). On
2026-09-23 AltStore moved it (altstoreio/AltStore 5811912, in 2.3.1 and later):
AltServer now writes the RPPairing record, plain XML as idevice's
`rp_pairing_file_to_bytes` writes it, to `Documents/ALTPairingFile.plist` in
AltStore's container after the install, and AltStore takes it into its Keychain
when Remote AltServer is set up, which then skips pairing. The 2.3.3 binary has
`ALTPairingFile.plist` and no `ALTPairingFile.dat`. Step 8 does what AltServer
does (`AltStorePairingHandoff`: `identifier`, `private_key`, `public_key`,
`alt_irk`), and so does Side by Side's `setUp`. AltStore's `OnDeviceClient`
refuses a record without `private_key`, so a lockdown-only pairing file writes
nothing, and AltStore pairs during its Remote AltServer setup. The file is
optional, as for Madeira: failing to write it doesn't fail the install. Signing
still bundles the sealed copy for a 2.3 picked under Advanced. An imported
AltStore IPA is recognized (`IPALibrary.knownSource`) and set up the same way,
without the App ID popup a custom IPA gets.

Verified 2026-11-10: a Mac harness compiling `SideStoreDownloader.swift` and
the pairing types against the live source (list 2.3.3, 2.3.2, 2.3.1, 2.3;
iOS 17.0 gets `noListedVersion`; a real download matching the listed SHA-256;
the second run skipped; a wrong SHA-256 refused with nothing kept; the IPA
recognized as AltStore; the record split), and the simulator (picker, version
list, Side by Side choice). Not verified, since it needs the iPhone and an Apple
ID: signing and installing AltStore, and AltStore picking up the file.

## JIT

Tools › JIT (2026-11-23) turns JIT on the way StikDebug does, written from
StikDebug's source (`JITEnableContext.swift`, its scripts) in Swift on the
idevice FFI the app already links (`JIT.swift`, `JITView.swift`, the debugging
section of `DeviceConnection.swift`): no Rust change, every symbol was already
in the xcframework. Its tile sits between Pairing and Certificates.

**Pairing file.** With none on disk, Load apps and Enable JIT generate it on
iOS 27 before going on (`JITManager.ensurePairingFile`), through the Pairing
page's own manager (`PairingManager.shared.generateForPage`), so the same code
and Settings steps come up and closing them stops quietly. Developer Mode and
the tunnel are checked first, since JIT can't go on without them; opening the
page never pairs (its quiet load waits for a pairing file). Below iOS 27 the
connect reports the missing file, as on every Tools page.

**The recipe.** The page lists the apps whose entitlements have
`get-task-allow` (`JITApp`), which every development profile grants, so
whatever SideStore or SideInstaller signed. Enable JIT checks Developer Mode,
runs `ensurePairingConnection` and mounts the personalized disk image
(`Engine.prepareDeveloperDiskImage`, split out of location setup), then a
`JITSession` opens DVT (`remote_server_connect_rsd`, `process_control_new`) and
debugserver (`debug_proxy_connect_rsd`, `com.apple.internal.dt.remote.debugproxy`),
launches the app suspended (`process_control_launch_app`, KillExisting on, where
StikDebug passes false: an app checks for JIT as it starts, so a running copy
is restarted), acks twice, `QStartNoAckMode`, `vAttach;<pid>`. Up to iOS 18,
and from iOS 26 without TXM, `D` follows at once and JIT stays on until the app
quits.

**TXM.** From iOS 26 on A15/M2 and later (from iOS 27 everything but the A12Z
iPad Pros, as StikDebug's `hasTXM` has it; StikDebug's decimal model formula
also leaves out iPad14,1–14,4, A15 and M2, which `JITDevice` doesn't), a
debugged app still can't map writable and executable memory: it stops on a
breakpoint and the debugger prepares the region by writing a byte to each
16 KB page (`$M<addr>,1:69`, 128 written before their answers are read). The
debugger stays attached answering, in the ways StikDebug's scripts do, here in
Swift rather than JavaScriptCore (`JITProtocol`): universal (`brk #0xf00d`,
`x16` 0 detach, 1 prepare at `x0` or allocate with `_M<size>,rx`, address
back in `x0`; `#0x69` answered 0xE0000069 as universal.js does), legacy
(`brk #0x69` regions, then detach: 1 for UTM/DolphiniOS/Flycast/ARMSX2, 3 for
maciOS) and Geode (`#0x69`, `#0x70` copy ≤ 4 MB, `#0x71`). Auto picks by app
name from StikDebug's list (`JITApps`), the universal calls for any other app
on TXM; the menu under an app overrides it (`jitModes` in UserDefaults).
Differences from the scripts: a stop that isn't a known request passes its
signal on with `vCont;S<sig>:<tid>` and takes that reply as the next stop
(universal.js sends another `c` after it, dropping the stop), SIGINT/SIGSTOP
aren't passed, an unknown `brk` gets SIGTRAP passed so the app crashes as it
would without a debugger (the scripts loop on it), `#0x71` steps past the
breakpoint before detaching, and apps' own scripts (`x16 = 2`, `brk #0x68`)
aren't run, only logged.

**Its own tunnel.** A session runs on its own thread over a second
`DeviceConnection`, as StikDebug opens a fresh tunnel per session: the shared
connection reconnects for every page action, which would end a session lasting
as long as the app runs. On the RPPairing route the session answers the RSD
heartbeat (`heartbeat_connect_rsd`, as StikDebug does while attached). On the
lockdown route the two connections share one lockdown heartbeat
(`acquireHeartbeat`/`releaseHeartbeat`, keyed by device IP, counted), since a
second heartbeat would close the tunnels opened under the first; with one
connection every connect still starts a fresh heartbeat, as before. Silent audio
(`KeepAlive`) keeps SideInstaller running while the app is in front: an app
waits at each request until the debugger answers. Quit ends a session with
`process_control_kill_app` from another thread, the one call that doesn't need
debugserver, which a thread waiting on `c` owns.

Verified 2026-11-23: the simulator build, unit tests for the packet parsing,
TXM detection and modes (`JITTests.swift`, run by `check-ios.sh`), and the page
in the simulator with a staged app list and a staged running session (a
`SIMHOOK_JIT` hook in a scratch snapshot, never committed). 2026-11-24, in the
iOS 27.2 simulator with the hook counting the tunnel as up: Load apps with no
pairing file put up the Pairing page's steps and started its pairing run
(the Live Activity came up), and closing them ended it with no error. Not
verified, since it needs an iPhone: a pairing that completes and goes on to
load the apps, everything that talks to debugserver or DVT, the TXM answers,
and the shared lockdown heartbeat.

## Running on a device (what you do)

1. Install LocalDevVPN (App Store id 6755608044), connect it, keep Wi-Fi on.
2. Build SideInstaller in Xcode (`./build-rust.sh && xcodegen generate`, then
   run on the device with your signing team).
3. In the app: type your Apple ID email + password and tap **Install
   SideStore**. The one-click flow runs every step in order — connect VPN →
   pair (it shows a PIN to enter + tells you where) → connect → Apple ID sign-in
   (enter the 2FA code when prompted) → download → sign → install → write
   pairing file — with a progress bar and a contextual instruction card at each
   gate. When it finishes, follow the final card to trust the cert
   (Settings › General › VPN & Device Management) and open SideStore.
4. If a step stops, the card shows a plain-English reason; open **Advanced** to
   run any step individually and **Copy** the raw log (idevice FFI codes +
   isideload `Report`s) for debugging.

### UI (friend-ready)

The raw test harness was replaced by a guided installer (`ContentView.swift`):
one primary **Install SideStore** button drives the whole `Engine.runOneClick()`
orchestrator; per-step buttons + the log console moved into a collapsible
**Advanced** section. The one-click path and the per-step buttons call the same
async step cores in `Engine`, so they can never drift. State for the progress
bar/checklist (`Engine.stepStates`, `installProgress`, `pairingPIN`, `guide`)
is all `@Published`. Reused-pairing/sign-in/download are skipped when already
valid; a stale pairing file triggers one automatic re-pair before giving up.

#### Report a problem: GitHub's link limits (issue #100)

A new-issue link can't carry a file, and its length is capped twice (measured
2026-10-27 with curl): GitHub answers 414 from about 8 KB, and a browser that
isn't signed in (the in-app Safari keeps its own cookies) is redirected to
`/login?return_to=…`, which carries the whole link escaped again (each `%`, `&`,
`=`, `/` and `?` grows by two) and fails with GitHub's “Whoops, something went
wrong!” 500 from about 6.6 KB. The old 7,500-character cap hit that with an
ordinary log, and the saved report file was hardly ever attached (inside
LiveContainer it isn't under Files › SideInstaller at all).

`ProblemReport.issueDraft` now caps the sign-in link's length
(`signInLength`, 6,000) and puts the whole log in the issue. If it fits in the
link, it goes there. Otherwise the link carries the description, details, error and
the log's last lines, the rest is copied to the clipboard (log first, newest
lines kept, then a description or error the link had to cut, then crash logs,
within GitHub's 65,536-character body limit, counting line breaks twice), and an
alert says to paste it at the end of the issue, where the body says
“Paste below this line”. “Copy the full log” copies it again. A non-Latin
description can cost 15 sign-in characters a character, so the loop can cut the
description and error from the link entirely and the title to 30 characters.
Rust's `{:#?}` byte lists are put on one line by `LogRedactor` (a public key was
35 lines of #100), after the redaction rules.

## Honest status summary

Everything below the UI is real, wired end-to-end, and compiles for device +
sim. The pieces that need a physical device, LocalDevVPN, or a real Apple ID
(RPPairing PIN, loopback tunnel, Apple ID login/2FA, cert/profile creation,
signing, install, house_arrest write) are written but **unverified** — they
cannot run in this environment. No step fakes success; failures surface raw
errors in the log.

## Sources and the .ipa inspector

Two features added on top of the install pipeline: browsing AltStore sources, and reading an
`.ipa` before it's signed. Both reuse what was already there rather than adding a second path.

### Sources (`AltSource.swift`, `SourcesView.swift`)

- The format is decoded leniently: **every field is optional except `name`**, because v1 sources
  repeat the newest release at the app's top level (`version` / `downloadURL` / `size`) while v2
  keeps everything under `versions`, and community sources omit whatever they like. A source whose
  `apps` can't be decoded at all is reported as an error instead of being shown empty.
- Releases are ordered newest-first from `versions` (AltStore publishes oldest-first); a v1 app's
  top-level release stands in for a missing `versions` array. A release with no usable http(s)
  `downloadURL` is dropped, since there'd be nothing to install.
- The **raw JSON** is what's cached on disk, not the decoded models: the models only decode, and
  re-encoding would silently drop every field they ignore, turning a cached source into a thin one
  on the next launch. The cache lives in Caches/Sources, keyed by an FNV-1a hash of the URL.
- Install goes through `Engine.installLinkedIPA(url)`, the same entry point a
  `sideinstaller://install` link uses — so a source app gets the identical download → inspect →
  sign → install run, not a parallel implementation.
- `sideinstaller://source?url=…` is parsed in `DeepLink` and hands the URL to `Engine.sourceToAdd`,
  which `RootView` uses to switch to the Tools tab; `ToolsView` presents the add sheet with it
  filled in. Nothing acts on it until the user taps Add.

### Inspect .ipa (`IPAInspector.swift`, `IPAInspectorView.swift`)

- Reads through the zip central directory with `IPALibrary.archiveFiles` / `contents(of:in:)`, the
  reader the Downloads list already uses: only the members it needs are inflated.
- **Mach-O**: `cputype`/`cpusubtype` per slice (fat headers included) for the architecture list,
  `LC_BUILD_VERSION` (platform 2 = iOS) or `LC_VERSION_MIN_IPHONEOS` for the executable's own
  minimum iOS, and `LC_ENCRYPTION_INFO(_64)`'s `cryptid` for the App Store encryption flag.
  The magic is read big-endian, so `CFFAEDFE` — how every iOS arm64 binary starts — means the
  file's own fields are **little**-endian; getting that backwards reads `ncmds` from the wrong
  place and walks off the header.
- Verdicts are separated into blockers (can't work) and warnings (works, but probably not as
  expected) so the Install button can be disabled on blockers alone.
- `Engine.installLinkedIPA` runs the same inspector on the freshly downloaded custom import and
  refuses on a blocker before `runOneClick`, which is what keeps an encrypted App Store `.ipa`
  from registering an App ID.
- The inspector runs off the main actor (it may SHA-256 an 80 MB file) and the page keeps the
  parsed report in `@State`; nothing is written to disk.

### Fixes and the app configuration (second pass)

- **The source browser froze on big repositories.** Four separate costs, all fixed: `VStack`
  built every row eagerly (`LazyVStack` now); `installableApps` sorted and rebuilt release lists
  on every body pass (both are computed once, at decode); `AsyncImage` per row re-requested and
  re-decoded icons on each pass (a `NSCache`-backed `SourceIcon` instead); and the JSON was
  decoded on the main actor on fetch *and* on cached load (both now `Task.detached`). The
  `.cascadeItem(index)` entrance delay is 55 ms × index, which for row 400 is 22 seconds — list
  rows cap it at 7.
- **`Engine.beginFreshInstallMenu()`** runs on a successful import and does what `resetRun()`
  does, plus dropping the adopted IPA paths so the download step picks up the new file, selecting
  `.custom`, and bumping `installMenuRevision`, which `ContentView` watches to clear its own
  `@State` (link field, Advanced open, expanded steps).
- **`IPAPatch`** rewrites the `.ipa` itself rather than extracting and re-zipping: the central
  directory is read, unchanged members are copied as their compressed bytes (their local headers
  rewritten so a data descriptor is no longer needed), and only changed files are written stored.
  CRC-32 is computed in-app; the output is a plain zip with no ZIP64, which is what every
  extractor in the pipeline expects.
- **Mach-O injection** needs no data shifting. The new `dylib_command` is written into the gap
  between the end of the load commands and the first `__TEXT` section's file offset — the padding
  Xcode leaves — and only `ncmds`/`sizeofcmds` change. `MachOInject` refuses (with a clear
  message) when a binary has no room, rather than shifting segment offsets. Injection is skipped
  when a command already names the library, so re-applying a configuration is a no-op.
- **Verification**: `patch-selftest.yml` builds a sample arm64 `.ipa` on a macOS runner, patches
  it through the same `IPAPatch` the app uses, and asserts with `unzip -t`, `plutil` and
  `otool -l` that the archive stays valid, the identity and extension IDs are rewritten, the
  Watch app is gone, `LC_LOAD_DYLIB` names the injected path, an untouched resource is
  byte-identical, and a second pass injects nothing.

### Debs, injectors, the app manager and the marketplace

- **`DebArchive`** parses the three layers by hand: ar (60-byte headers, even-offset padding), tar
  (octal sizes, GNU long names, pax headers skipped) and gzip (header flags, then a raw DEFLATE
  stream — `compression_decode_buffer` with `COMPRESSION_ZLIB`, growing the output buffer because
  gzip doesn't record the size). xz and zstd debs are refused with a message rather than guessed
  at. From a package it takes every `.dylib` and every `.framework` binary, which covers both
  `/Library/MobileSubstrate/DynamicLibraries` and `/var/jb/…` rootless layouts.
- **Injectors** are user-supplied copies registered per framework kind. A package's `Depends`
  maps to a kind (`mobilesubstrate` → substrate, `ellekit`, `libhooker`, `substitute`) and that
  library is injected first; `AppConfigStore.missingInjectors` drives the warning shown before the
  install rather than after a crash. Distribution of the frameworks themselves is the user's
  business, not the app's.
- **`IPAPatch`** grew a plist edit list (typed values, only written when different), an
  entitlements file writer, per-extension removal and the multi-library injection above. Every
  library's architecture is checked with the shared `MachO` reader first, so an armv7 or x86 slice
  is reported instead of injected.
- **App manager**: `DeviceConnection.uninstall` calls `installation_proxy_uninstall` over the same
  RSD link the install uses; `Engine.uninstallApp` wraps it with the pairing/connection dance.
  Re-sign reuses the refresh job for a single app, and *Update to x.y* looks the bundle ID up in
  every configured source and compares versions numerically.
- **Marketplace**: `MarketplaceView` is a `NavigationSplitView` — a sidebar of categories and
  sources, a lazy grid of cards. The catalogue is de-duplicated by bundle ID (newest release wins)
  and rebuilt only when a source's app count or id changes, for the same reason the old list
  froze. Categories come from the source's own `category` strings, matched loosely and falling
  back to "Other", so an unlisted value never hides an app.

### Marketplace: tab and rail

- **Why categories didn't open**: `NavigationSplitView`'s `List(selection:)` only drives the detail
  column at regular width. On an iPhone the split view is compact, the sidebar is pushed as its own
  screen, and selection changes have nowhere to go — rows highlight and nothing else happens.
  `NavigationLink(value:)` in a sidebar has the same problem: it pushes onto the *sidebar's* stack,
  not the detail's.
- The fix is not another navigation style but a plain `HStack`: a 96pt rail of `Button`s that set a
  `Filter` state, a one-point divider, and the grid. It behaves identically at every size, works
  inside the tab's `NavigationStack` (so `.searchable` and the settings toolbar still apply), and
  removes a whole class of "selection did nothing" bugs.
- The tab is `Page.marketplace` in `RootView`, `.dark` like Tools, so the rail reads as a sidebar.
  `ToolsView` no longer carries a Marketplace row.
- An install started from the grid or an app's page closes that page: the run takes over the
  Install tab, and a sheet left open would sit in front of the progress.

### Source shelves, compact rows, and a plist editor that knows the keys

- **Why a source showed nothing**: `catalog` is de-duplicated by bundle ID (newest release wins) so
  the "All apps" list doesn't repeat an app carried by three repositories. The source filter then
  searched *that* list, so every app another source also carried had been replaced by that source's
  copy and disappeared. Fixed with a second index, `bySource`, filled in the same pass; the rail
  count and the shelf read from it. A source whose fetch failed now shows the error and a retry in
  its own shelf, plus a warning mark in the rail, rather than an empty-looking section.
- **Compact layout**: rows rather than cards. One `HStack` per app (44pt icon, two lines of text,
  version, install button), so a screen shows about twice as many apps and the install action is
  reachable without opening anything.
- **Tabs**: `Page` is install / marketplace / apps / tools. About is a `NavigationLink` inside the
  Settings form, which is where a version number and credits belong.
- **Configuration reads the build**: `IPAPatch.readInfoPlist` and `.readEntitlements` use the same
  central-directory reader as the patcher (xcent first, then the embedded profile's `Entitlements`),
  all off the main actor. Identity fields fill only when empty, so an edit is never overwritten.
- **Plist catalogue** (`PlistCatalog`): ~50 documented keys with type, one-line purpose and the
  values Apple defines. The editor picks the control from the key — switch for booleans, menu for
  enumerations, checkable list for array keys, text otherwise — and completions show the summary so
  a key can be chosen without knowing its spelling.
- **Injector fetching** (`InjectorCatalog`): ElleKit is taken from the community repository's
  `Packages` index (newest `iphoneos-arm64` stanza, then its `.deb`, unpacked with `DebArchive`);
  Substitute from its GitHub release asset. Both land as a plain library through `addInjectorData`.
  CydiaSubstrate and libhooker have no published build, so they're manual by definition.
- **Dependency analysis**: `MachOInject.linkedLibraries` reads `LC_LOAD_DYLIB`/`LC_LOAD_WEAK_DYLIB`
  names out of a tweak before it's stored, and `TweakInjectorKind.detected(inLibraries:)` maps
  `libsubstrate`/`ellekit`/`libhooker`/`libsubstitute` to a framework. That covers a bare `.dylib`
  with no control file, and a package whose `Depends` was stripped.

### JIT, merged marketplace entries, and which .ipa the config describes

- **JIT** (`JITSession`): the sequence is launch-suspended → `vAttach` → `c`. DVT process control
  (`process_control_launch_app`, RSD) starts the app stopped at its entry point; the debug proxy
  (`debug_proxy_connect_rsd`) speaks GDB-remote to the device's debugger; attaching is what sets
  `CS_DEBUGGED`, and with it the right to map executable pages. The connection is deliberately kept
  open and *not* read from: a stopped process gets one stop reply, and a packet aimed at the socket
  while the app runs would interrupt it. Liveness is checked out of band through
  `app_service_list_processes`, so quitting the app ends the session rather than hanging it.
- **Debug packets**: `debugserver_command_new` takes a name plus arguments, and the proxy
  hex-encodes only the arguments — so a packet with a payload goes in as name `vAttach;` and the
  hex string as its single argument. Packets with no payload (`c`) go as a bare name.
- **Merged marketplace entries**: the catalogue is one entry per bundle ID, but it keeps *every*
  release from every source, each tagged with the source that carries it. The row's menu and the
  app page pick from that list; de-duplication is by version string so a build two repos both
  carry is listed once. Sorting is applied after filtering, so it holds for a source's shelf and a
  category alike.
- **Install target for the config page**: `Engine.installTargetIPA` is the downloaded build, else
  the custom import, else the selected source's copy. Reading `IPILibrary.customImport()` alone was
  why the page described SideInstaller itself: that slot held the app's own .ipa. The page also
  re-reads when the Install tab's build changes, and replaces identity values that were carried
  over from the previous build rather than treating them as user edits.

### Menu loading: the three hot spots

- **Quadratic catalogue build.** Merging releases into one entry per app also needed to know
  *which* source carried each release, and the first version asked that by scanning every app of
  every source for a matching release — O(releases × apps). On AppTesters' ~9,900 apps that is tens
  of millions of comparisons per refresh. Indexing `releaseID → source` while walking each source
  makes it one pass.
- **Per-row scans in My Apps.** `refreshable.first(where:)` and a "newest release in any source"
  lookup ran inside the row body, i.e. for every row on every layout pass. Both are now
  dictionaries built when the data changes (`jobsByBundle`, `updateCandidates`), so a row is a
  lookup.
- **Icon fetching.** Each icon was a separate `engine.appIcon` call: connect `app_service`,
  handshake, fetch, close. Twenty apps meant twenty round trips before the list stopped showing
  placeholders. The batch method opens one connection for forty, and the disk cache answers first.
- **Filtering in `body`.** `visible` recomputed the filter, the search and the sort on every pass,
  including while scrolling. It's now a `@State` array refreshed by `onChange` of the filter,
  query, sort and catalogue revision — the same pattern as the source list, which is the lesson
  from the earlier freeze.

### A lighter marketplace

- **What was kept, and wasn't.** The store used to hold every decoded `AltSource` — the whole
  document, screenshots and news included — for each source, and the view walked it. It now decodes
  once, off the main actor, into `MarketEntry` rows (a dozen strings and the release list), drops
  the document, and merges those. `AltSource`/`AltApp` stay what they are: the decoder.
- **Fetching.** `refreshAll` runs four tasks at once under a sliding task group; each source sends
  `If-None-Match` with the `ETag` saved beside its cached JSON, and a 304 reuses the cached bytes.
  Before, sources were fetched in sequence and always downloaded in full.
- **What the view does now.** Nothing but filter and sort. The store owns merging, featured keys
  and per-source counts; the view memoises its visible list against `store.revision`, so a scroll
  pass touches no catalogue data at all.
- **Removed**: `SourcesView`, `SourceDetailView`, `AltAppView` and the old `MergerAppView` over
  `AltSource`. Every one was superseded — the marketplace's rail covers a source, and the merged
  page covers an app — and each was a second copy of the catalogue on screen.

### Marketplace: controls on top, sources in a manager

- **Why the chips, not tabs.** A `TabView` inside a tab is a lie to the user (two tab bars) and a
  `Menu` hides the counts. A horizontal `ScrollView` of capsule chips keeps the counts visible,
  scrolls sideways for a long source list, and costs one row of height.
- **Categories went to the bottom** as a `safeAreaInset(edge: .bottom)`, so they stay put while
  the list scrolls and never eat into the top bar's room. The all-categories chip clears the
  filter only when a category is active, so it doesn't fight the source chips.
- **Search is an inline field** rather than `.searchable`: the system search field animates into
  the navigation bar and can't coexist with a second row of controls, which this screen needs.
- **`SourceManagerView`** does the bulk work: lines parsed and validated through
  `SourceStore.sourceURL` so the button's count matches what will be added; adds go through the
  store one at a time (each fetches and indexes, and the store must stay consistent); failures are
  reported per link rather than aborting the batch.

### My Apps without a device read on open

- `autoLoad` used to call `load(quiet:)` whenever the tunnel looked up, and that opened the link:
  `ensurePairingConnection` → `tunnelUp` (which can start LocalDevVPN and wait) → `performConnect`.
  On a screen you flip to just to check an expiry date, that's several seconds of "Reading the
  device".
- Now the inventory (`installation_proxy` plists + `misagent` profiles) is cached per UDID in
  Caches, and the page rebuilds the list from it on first appear. The cache is written on every
  successful read, so it's never more than one load behind.
- An automatic re-read is allowed only when `engine.connection.isConnected` — i.e. the link from
  another screen is already up, so it's a query over an open socket rather than a connection. Load
  and pull-to-refresh remain the explicit path.
- `CachedInventory` stores the app dictionaries as a binary plist inside the plist: they're
  `[String: Any]` from `PropertyListSerialization` (device data), which `Codable` can't take
  directly.

### Where My Apps' remaining wait was

- `SideloadedApp(plist:)` and `ProvisioningProfile(data:)` run `PropertyListSerialization` per app
  and per profile, and `ProfileMatcher.match` regex-matches wildcard App IDs against apps — all of
  it on the main actor inside `adopt`. On a device holding a few hundred profiles (every re-sign
  leaves one behind) that's the bulk of the stall, cached or not.
- Both paths now hand `(appPlists, profileBlobs)` to a detached task and come back with the parsed
  entries, so the tab's first frame doesn't wait for it. The types are annotated
  `@unchecked Sendable` for that crossing — they're immutable value types over plist data, and
  nothing mutates them after parsing.
- The rows are a `LazyVStack`: a row carries a `Menu`, an icon lookup and an expiry label, which
  adds up when twenty-plus exist.
- If it's *still* slow, the remaining suspects are the icon batch (one `app_service` connection per
  40 apps) and `AVFoundation`-free `UIImage(data:)` decoding of 60pt PNGs; the fix there is to
  downsample with `CGImageSourceCreateThumbnailAtIndex` and store the small image.

### TestFlight in My Apps, and source kinds

- `SideloadedApp.init?(plist:kinds:)` defaults to *excluding* App Store apps but also excluded
  TestFlight from the manager's parse, so the section had nothing to show. The manager now passes
  `[.sideloaded, .testFlight]` explicitly.
- TestFlight builds carry `beta-reports-active`; their profile is Apple's and renews on its own.
  Offering Refresh/Re-sign on them would register an App ID and install a second copy under a
  different signature, so those rows only get Open, Info and Delete — and the inline Re-sign button
  is hidden for them.
- **SourceKind** is presentation plus one real behaviour. `.altSource` is every JSON catalogue
  (AltStore, SideStore, Feather, E-Sign, Scarlet all publish the same schema); `.github` reads a
  repository's releases, one app per distinct `.ipa` asset name, one version per tag. Rate limits
  are reported as such — 30 releases per repository keeps a single request.
- **Repository directory** is shipped, not scraped: a curated list works offline, can be trusted,
  and is the thing you need when the app is freshly installed. Links are community sources; the app
  doesn't endorse what they carry.

### Verifying the repository market

- Probed every candidate with `curl -L -m 20 -w %{http_code}` and decoded the body, so a 200 that
  was a web page counted as dead. Sources consulted: the `awesome-altstore` list (victordedomenico),
  GitHub repository search, SideStore's Community-Source repo, and the stores' own sites. Reddit's
  JSON API refuses unauthenticated requests now (403), so its lists weren't usable directly; the
  sources they recommend (AppTesters, CyPwn, Quark, Quantum) were verified individually instead.
- **Dead, removed**: E-Sign's `esign.yyyue.xyz/appstore.json` (404), AppDB (`repo.appdb.to` — no
  route), iOS Haven (`apps.json` 404). E-Sign's practical successor in the list is BatSign's own
  source, which resolves.
- **Worth knowing**: AppTesters' catalogue reports 9,879 apps but carries no `category` field, so
  every one of them lands in "Other" in the marketplace — that's the source's own data, not a bug
  here. It's also 10 MB of JSON, which is why the marketplace decodes to rows and drops the document.
- Re-verify by re-running the probe script against `RepositoryDirectory.all` before any release
  that claims these work.

### Why filtered sources were empty

- CyPwn's document has **no `versions` array at all**: each app carries one release at the top
  level (`version`, `downloadURL`, `size`, `versionDate`) — the v1 shape. That path existed, but it
  ran *after* a typed `JSONDecoder` had already decided the document's shape: any field whose type
  didn't match (`size` as a string, `version` as a number, which real sources publish) threw, the
  typed decode returned nil, and the source index was empty. The marketplace then showed its "no
  apps" card for that source while the rail still counted the raw app list — exactly the screenshot.
- **The fix is to stop declaring a schema.** `AltSource`/`AltApp`/`AltVersion` are now built from a
  `[String: Any]` tree produced by `JSONSerialization`, with `PlistValue` coercing each field
  (`"1"` and `1` both read as a version). A mistyped field costs that field, not the app.
- **The models moved apart from the store** so they can be compiled and run where Combine and
  URLSession don't exist: `AltSource.swift` (models), `SourceStore.swift` (fetch/cache/merge),
  `SourceKind.swift` (types), `GitHubSource.swift` (release reader).
- **`tools/parser-check`** decodes real documents through those models and fails if `apps` in the
  JSON doesn't match what the models produced. CI runs it in a Swift container; CyPwn's host blocks
  GitHub's runners, so it's skipped there and named as skipped — the three sources that do load are
  enough to catch a regression, and the CyPwn numbers were checked by hand (209/209).

### One parser for every repository format, and an index cache

- **Formats in the wild**, all now handled by `SourceParser`:
  - AltStore / SideStore / PAL / SpotC — `{ name, identifier, apps: [ … ] }` with a `versions` array.
  - GBox — same `apps` array, but `sourceName` / `sourceImage` for the metadata, and apps that carry
    no bundle ID at all (the row is keyed by `source#name` instead).
  - Scarlet — either the store shape *or* a category map: top-level keys are categories whose values
    are app arrays, with `down` for the download, `bundleID`, `icon`, `dev`, and a `META` block.
  - E-Sign / Feather / hand-rolled — a bare array of app objects, `url` or `link` for the download.
- **Why a parser and not a decoder:** the previous `JSONDecoder` model required one schema. Real
  documents disagree on types as well as names, and a single mismatch emptied the whole source.
  `SourceParser` reads JSON into Foundation objects and coerces each field, so a repository only has
  to *resemble* the format to be usable.
- **The cache is the fix for launch time.** `SourceIndex` holds a source's rows, its ETag and when
  it was fetched, in `Caches/SourceIndex/<hash>.json`. Launch reads those (a few hundred KB at
  worst) and merges; nothing is downloaded or parsed. `refreshAll(force: false)` only touches
  sources with no index or an index older than six hours, and each refresh sends `If-None-Match`, so
  an unchanged source answers 304 and its rows are kept as they are.
- **`source-parser` CI** decodes live documents (AltStore, AppTesters, GBox, SpotC, Quark) *and*
  vendored samples of the shapes no live fetch guarantees (Scarlet's category map, GBox metadata, an
  E-Sign array), failing if any app comes back without a release.

### Telegram channels as a source

- **What's reachable.** Telegram has no unauthenticated API for reading a channel, but it publishes
  an HTML preview at `t.me/s/<channel>`. That page carries each post's text, the attached document's
  **name and size**, and the post permalink. It does **not** carry a file URL: Telegram mints those
  per client session and they expire, so no amount of scraping produces one.
- **So the entry is honest.** `MarketEntry.Version` gained `direct`. A Telegram release has
  `direct: false` and its URL is the permalink; the install button opens it in Telegram (iOS hands
  `https://t.me/...` to the app when installed). A post whose text links a direct `.ipa` also gets a
  `direct: true` release, and that one installs through the normal pipeline — some channels mirror
  their files, and this picks that up for free.
- **Reading it**: blocks are split on `tgme_widget_message_wrap`, the id comes from `data-post`, the
  document from `tgme_widget_message_document_title`/`_extra` (name and "2 GB"), the date from
  `<time datetime>`. Entities are decoded and tags stripped; sizes parsed from the text form.
- **Limits**: public channels only, recent posts only (Telegram paginates the preview), and a
  channel with previews disabled returns no posts — each of those gets its own message rather than
  an empty source.

### What each requested channel actually exposes

Measured against the live previews:

| Channel | Result |
|---|---|
| `t.me/ipaomtk` | **Readable.** 20 posts in the preview; every one is a write-up ("Vibes (Not Boring) IPA") linking `ipaomtk.com/...`. Listed as 20 apps whose install opens that page. The pages themselves don't link a plain `.ipa` — downloads go through their own signer — so nothing installs directly. |
| `t.me/ipahub` | **Readable.** Posts carry `.ipa` documents (name + size in the preview, e.g. "PUBGM CHETO CRACK - KAMOHACKS.ipa", "2 GB"). Opening one goes to the post; Telegram mints the file link per session. |
| `t.me/binnichtaktivsipas` | **Previews off.** `t.me/s/…` redirects to the join page. Nothing readable without an account; the source says so and offers Open in Telegram. |
| `t.me/blatants` | Same. |
| `t.me/iOS_Randy420` | Same. |
| `t.me/c/2573020932/2` | **Private channel.** `t.me/c/<id>` links carry an internal id that no public URL resolves; refused with an explanation rather than trying `t.me/s/c`. |

- **Bug found while doing this:** posts were split on the exact string
  `<div class="tgme_widget_message_wrap"`, but Telegram renders
  `class="tgme_widget_message_wrap js-widget_message_wrap"` — so channels like ipaomtk parsed as
  zero posts. Splitting on the class name alone fixes it.
- The preview check is a redirect test: after following redirects, a URL that isn't under `/s/`
  means the channel has no preview, which is a different failure from "no .ipa in it".

### The Telegram studio, and why there's no login

- **What shipped**: channel selection with per-channel scan depth, a scan that walks `?before=`
  pages, results per channel with their errors, and an AltStore-format document generated from the
  lot — written to `Documents/Telegram/telegram-source.json`. `SourceStore.sourceURL` learned
  `file://`, so the app loads its own generated source like any other (the same JSON can be hosted
  and given to SideStore/AltStore, which is the "live URL" part).
- **What didn't, and why**: signing in. A Telegram account is an MTProto session: `api_id`/`api_hash`
  registered at my.telegram.org, a phone login (code via other devices or SMS, 2FA password where
  set), a session key that is itself a credential as sensitive as an Apple ID, and a file-download
  path that only such a session can provide. That's a separate subsystem — a Rust MTProto client
  (grammers) behind the existing FFI, Keychain-stored session, login UI with 2FA, file downloads —
  and it can't be validated from CI. Rather than a dead "Sign in" button, the account card lists
  exactly what it would take.
- **Consequence for the generated source**: Telegram mints file URLs per session, so the generated
  entries carry the post permalink (or the channel's own page link) as `downloadURL`. The app reads
  them back, and tapping one opens it. A channel that links a direct `.ipa` in its post text
  generates a real download URL, and those install normally.

### Telegram authorization: what can be streamlined, and what can't

- **Credential capture** (`TelegramCredentials`): api_id/api_hash from my.telegram.org/apps, shaped
  checked (numeric id, 32 hex chars), stored as `id:hash` under the Keychain service
  `com.sideinstaller.telegram` with `kSecAttrAccessibleAfterFirstUnlock`. The setup screen is the
  three steps Telegram actually requires, with the developer page one tap away.
- **Why the credentials aren't the login.** A Telegram client authenticates with an MTProto session:
  `auth.sendCode` → the code (other devices or SMS) → `auth.signIn`, plus SRP for accounts with 2FA,
  and an auth key that must persist (it *is* the credential). That needs a protocol client in the
  build; storing api_id/api_hash only removes the registration step.
- **The offline alternative, which works today**: Telegram Desktop's "Export chat history → JSON"
  writes `result.json` plus `files/…`. `TelegramExport.read` maps each `.ipa` message to an entry;
  files beside the JSON become `file://` releases, which the installer already accepts, so they
  sign and install like any import. For a channel with previews off this is the only path that
  yields installable apps, and it needs no account at all.
- **What remains for a real login**: a Rust MTProto client (grammers) behind the existing FFI, session
  storage bound to the Keychain, a code/2FA UI, and a download path that streams a file from
  Telegram. Each is verifiable only on a device with a real account, so it should be its own change.

### The loopback source server

- **Why a server at all**: SideStore and AltStore add *sources by URL*. A generated file is one
  import; a URL is a source. `LocalSourceServer` binds `127.0.0.1` (via `NWParameters
  .requiredLocalEndpoint`, not `NWListener(using:on:)`, which would listen on every interface) and
  serves `/telegram-source.json` — regenerated per request, so a scan immediately changes what a
  client fetches — plus `/health` and an index page that lists the channels and states the limits.
- **Loopback reachability** is deliberate: any app on the device can reach 127.0.0.1, and iOS's Local
  Network permission doesn't apply to loopback, so no prompt is involved. Nothing off the device can.
- **iOS ends it when the app is suspended.** Without a background mode (audio/VoIP/location — none
  of which this app should claim) a listening socket doesn't survive, so the card says the server
  runs while SideInstaller is open. A client that fetched the source keeps its copy.
- **What it can't do**, since it came up: an `api_id`/`api_hash` is app identification, not
  authorization. Scraping *your* joined channels requires an MTProto session (`auth.sendCode` →
  code → `auth.signIn`, SRP for 2FA) held on the device. Without that client, the server serves
  public previews and imported exports, and its index page says exactly that rather than implying
  the account is connected.

### The preview-off workaround, measured

- **`tg.i-c-a.su/rss/<channel>`** serves a channel as RSS, and its `<enclosure>` URLs are
  `https://tg.i-c-a.su/media/<channel>/<message>/<file>.ipa` — the files themselves, not pages. A
  ranged GET returned `206 application/zip`, so they're downloadable and therefore installable.
- Counts on the channels in question (live, this session): blatants 5, binnichtaktivsipas 5,
  iOS_Randy420 1, ipaomtk 10 — against 0 for the first three through `t.me/s`.
- `TelegramSource.entries` now asks both: bridge first (installable links), preview second (newest
  posts, and the channel's own name), merged by app name. If either fails the other still answers;
  only when both fail does the source show an error — the bridge's, since it's the one that was
  supposed to work.
- **Trade-off stated in the code**: the bridge is a third-party service. It can rate-limit, move or
  stop; nothing else depends on it.

### Backgrounding: what was built and what was refused

- Built: `beginBackgroundTask` (a ~30 s grace period so a client can finish a fetch after the app is
  backgrounded) and `BGAppRefreshTask` (registered in `Info.plist` as
  `com.frizzlem.sideinstaller.telegram`, scheduled four hours out, rescanning and regenerating the
  source while the app is closed).
- Refused: keeping the app alive with silent audio under the `audio` background mode, or a location
  session under `location`. Both are background-mode abuse: they declare a purpose the app doesn't
  have, they drain the battery, and they're the sort of thing that gets a signing certificate pulled.
  iOS also throttles silent audio that never plays anything audible, so it isn't even reliable.
  The UI says this in the card rather than leaving it unexplained.

### Every page, every channel, with pictures

- **Depth**: `Channel.allPages` defaults to true and the scan walks `?before=` until a page repeats
  or the forty-page backstop hits. The toggle turns it off and brings back the stepper (1–40).
- **Bridge depth**: its RSS takes `?limit=`; measured — 10 → 10 items, 25 → 25, 50 → 49, 75 → 74,
  90 → 89, 100 → 99, 120 → 99. So 100 is the request and ~99 the ceiling. It also returns 500 under
  load, which is why `entries` retries once and then asks for the plain feed: ten items is better
  than a channel that looks broken.
- **Icons**: each RSS item's description embeds `<img src="…/media/<channel>/<msg>/preview/thumb.jpeg">`
  — a per-file preview image, the closest thing to an app icon Telegram publishes. Entries use that,
  falling back to the channel picture (`<image><url>` in the feed, `og:image` on the preview page,
  and `tg.i-c-a.su/icon/<channel>/icon.jpg` when neither is present).
- **Every channel is checked**: the scan reads all channels whose switch is on, keeps going after a
  failure, and reports per channel — so one dead channel never hides the others' results.

### The configuration toolkit, reachable from Settings

- Settings now carries the same `AppConfigView` the Install screen opens, with the change count in the
  row. One view, two doors: duplicating it for Settings would have meant two places to keep in step.
- **Editable load paths**: `Tweak.loadPath` was already what the patcher injects; it just wasn't
  editable. A `.dylib` now shows a field prefilled with `@executable_path/Frameworks/<name>`, so a
  library built against `@rpath` or shipped as a framework can name its own path. Packages (`.deb`)
  don't get the field: their libraries are placed and loaded by the patcher.
- **Check against the build** compares `config.plistEdits` and `config.entitlements` with
  `snapshot.plist` / `snapshot.entitlements` (both read from the archive when the page opens) and
  sorts each into changes / additions / no-ops / invalid. `PlistEdit.object` decides "invalid" — a
  key whose value can't be typed is caught here rather than during signing.

### Settings that do something

- `AppSettings` is the single place for behaviour that used to be constants: bridge use, page
  limits, launch scan, server auto-start and port, background refresh and grace period, marketplace
  order and filtering, default depth. Every key has a default matching the old behaviour, so an
  install that never opens Settings is unchanged.
- **Wired end to end**, not decorative: `TelegramSource` skips the bridge when it's off,
  `BackgroundKeepAlive.scheduleRefresh` refuses when background refresh is off,
  `LocalSourceServer.start` takes the configured port, `TelegramStudio.allPageLimit` reads the
  limit, `MarketplaceView`'s initial sort and its non-direct filter come from settings, and the app
  starts the server/scan at launch when asked.
- **`SourceStore.shared`**: the store had been created by `RootView`, which left the diagnostics
  report (and anything else outside the view tree) unable to read the source list. It's a singleton
  now and `RootView` holds that instance.
- **Storage** measures `SourceIndex`, `Sources`, `AppIcons` and `Documents/Telegram` — everything the
  app can rebuild. The `.ipa` library, pairing files and certificates are deliberately absent: they
  are the user's, not cache.
- **Diagnostics** is a text file built from settings + storage + sources + channels + the tail of the
  log. It never includes an Apple ID or a password, which is why the log is passed through the same
  redactor the problem report uses.

### Bug sweep

Scanned the whole app for the usual defect classes and fixed what turned up:

| Found | Where | Fix |
|---|---|---|
| `@Published` mutated off the main actor — `refresh()` ran in whatever context called it | `SourceStore` | every state-touching method is `@MainActor`; the class stays non-isolated so `shared` is readable from a property initializer |
| Generated source rewritten once per HTTP request | `LocalSourceServer` | five-second cache of the document |
| `force` accepted and ignored, so a manual refresh still sent `If-None-Match` | `SourceStore.refresh` | force now omits the ETag |
| A settings toggle had no visible effect until the next catalogue revision | `MarketplaceView` | observes `showNonDirectEntries` |
| Sign-in inside the per-app loop | `AutoResign` | one `prepareRefresh` before the loop |
| Results list cleared while a scan was running | `TelegramStudio` | assign once, at the end |
| Profile matching in a SwiftUI body | `Renewals` settings | computed on appear |
| `scheduleRefresh()` called from a non-isolated `didSet` | `AppSettings` | hopped to the main actor |

Checked and left alone: the seven `URL(string:)!` sites are all literals (a typo would be caught at
launch); `LogRedactor`'s one `try!` builds a pattern from escaped literals; no `as!`, no
`fatalError`; the loopback server and the JIT session both clean up their handles and capture `self`
weakly in their callbacks.

### Keeping the .ipa, and two more tools

- **Why the cache exists**: a re-sign needs the original `.ipa`. The signed `.app` can't be read back
  out of another app's container, and a user's download may not survive seven days of Files
  housekeeping. `IPACache` copies the file after every successful install — and again on every
  refresh, since a refresh's source is the freshest copy — into `Application Support/IPACache`, not
  Documents: it's the app's bookkeeping, not something to shuffle in Files.
- **It joins the library**: `IPALibrary.scan()` now includes cached builds, which is what makes
  `ProfileMatcher` pair them with installed apps, which is what makes the Re-sign button appear for
  an app whose download is long gone.
- **Bounded**: `prune(olderThan: 60 days, keepingUnder: 2 GB)` runs after each store, oldest first.
  Deleting a copy never touches the installed app; it only means that app can't be renewed until an
  `.ipa` is supplied again — which the Stored builds page says in as many words.
- **Stored builds** and **Device** are read-only views over that: list/install/share/delete, and the
  device's own facts (lockdownd `ProductType`, `BuildVersion`, `UniqueDeviceID`, volume capacity).

### Finishing installs, updating from My Apps

- **`askBeforeAppIDCost`** (Settings, default off) gates the App ID prompt. Off, `confirmAppIDCost`
  logs the bundle ID it's registering and returns, so `runOneClick` proceeds straight through sign
  and install. The prompt was the only stop between "tap Install" and the app being on the device.
- **`MarketplaceRouter`**: a published `pendingSearch` plus a tab switch in `RootView`. My Apps uses
  it when an app has no newer release in the configured sources — the marketplace is then the place
  to look, pre-filtered to that bundle ID.
- **Install all updates** sequences `installLinkedIPA` calls and waits for `engine.isRunning` to clear
  between them: they share one device link and one signing queue, so firing them together would race.
- **Installed state in the marketplace** comes from the cached inventory (`SideloadedAppsManager`),
  so the app page can say "Installed 1.2 — this release is newer" without touching the device.

### The QoL pass, and why each piece is where it is

- **Search in My Apps** filters the same `manager.entries` the sections use, so the TestFlight /
  sideloaded split survives filtering; the sort only reorders within each section.
- **`Haptics`** is one small enum so the vocabulary stays consistent (light tap / success / warning /
  rigid for destructive), and it's called from the engine's outcome, not from every button — a tap
  that fires on "the run finished" is honest, one that fires on "the button was pressed" isn't.
- **Info sheet copy/share** exists because the questions people ask ("what's your bundle ID, when
  does it expire") are answered by a paste, and because the stored-`.ipa` line tells you at a glance
  whether this app can be re-signed later.
- **Opened .ipa → Install tab**: `installMenuRevision` already bumps on every import; `RootView` now
  reacts to it by switching tabs, which covers the share-sheet path and the document picker alike.


### The tweak browser, and where it stops

- **It's the file picker with an index in front.** Every package ends up in
  `AppConfigStore.addTweaks` — the same call the Files picker makes — so the parser can't disagree
  with injection about what a `.deb` contributes. The browser only decides *which* `.deb`, and
  verifies it arrived as published (SHA-256 from the index, when present).
- **`Packages` is Debian control, not JSON.** Continuation lines (a leading space or tab) belong to
  the key above them; a multi-line `Description` is the common case, and a parser that ignores them
  silently truncates every description and — worse — merges the next stanza's keys. `stanzas(in:)`
  folds them, and `tools/tweak-repo-check` reads live indexes in CI so that stays true.
- **One row per identifier.** A repository lists every build it still serves (Havoc: 3,657 stanzas
  for 531 packages), so the newest version wins, with arm64 preferred when two builds share a
  version — rootless and rootful both work, since only the `.dylib` is taken.
- **Filtered at parse time**: a stanza whose `Architecture` isn't `iphoneos-*` is a macOS or Debian
  build and can't be injected, so it never reaches the list.
- **The index is cached as published**, in `Application Support/TweakRepos`, and parsed off the main
  actor when the store loads — a 2.9 MB index is worth not parsing on the first frame. A failed
  refresh keeps the cache and shows the error on the repository's row, the way a source does in the
  marketplace.
- **Plain `Packages` first, `Packages.gz` second.** Most repositories serve both; the compressed one
  is read through `DebArchive.gunzip`, which is the same inflater `.deb` members use. `.xz`/`.zst`
  indexes are not read — the plain or gzip variant is missing on very few repositories, and adding an
  xz decoder to the app for that isn't worth the code.
- **Known limit**: no dependency resolution. A tweak's `Depends` picks the injector framework
  (ElleKit / Substrate / libhooker / Substitute) when it names one, and the configuration page says
  when that framework isn't added; the rest of the dependencies (preference bundles, libraries like
  AppList) are not installed, because there is no jailbreak for them to be installed into.

### Tweak updates: identity, not file names

- **A `.deb`'s file name is not its identity.** `Foo_1.4_iphoneos-arm64.deb` becomes
  `Foo_1.6_iphoneos-arm64.deb`, so a "is this already added?" check by name goes blind exactly when
  it matters. `Tweak` now keeps the control file's `Package:` and `Version:` (and the repository it
  came from), and `addTweaks` replaces by identifier: the old file is deleted, the new one recorded,
  and `weak` / repository carry over.
- **Legacy tweaks are left alone.** A tweak added before this change has no identifier or version.
  Matching still falls back to the file name so it reads as "already added" in the browser, but
  `TweakRepoStore.update(for:)` requires a recorded version — an unknown current version would make
  every release look newer, and an update badge that's always on is noise, not information.
- **The update check is a cache read, never a network call.** `update(for:)` looks in the indexes
  already on disk, so drawing the tweak list costs nothing; the browser's Refresh (or opening it) is
  what actually refetches. That also means a fresh launch with no index yet shows no badges until
  something reads a repository, which is honest — nothing has been compared.
- **Ordering is Debian's `compare(options: .numeric)`**, with one deliberate difference: `~` sorts as
  punctuation, so `1.0~beta` reads as newer than `1.0` rather than older. Repositories that ship
  pre-releases this way would otherwise never offer the final release. `tools/tweak-repo-check`
  asserts the orderings the badge depends on (`1.0.10` > `1.0.9`, nothing > itself) on every change.
- **Same swap path as adding.** The update button downloads through `TweakRepoStore.file(for:)`
  (SHA-256 verified when the index publishes one) and calls `TweakPackageInstaller.add`, which is
  `addTweaks`. The browser and the configuration page therefore can't disagree about what an update
  produces — they call the same two functions.

### Install menu: the setup is the menu

- **Nothing install-relevant is behind a disclosure any more.** The version picker and the pairing
  file used to live in an **Advanced** section *below* the button, which meant a run could start
  with a stale version or someone else's pairing file and the only clue was a smaller section. They
  are chips inside the install card now — above the button, each showing its current value, so the
  menu doubles as the receipt for the next run.
- **Cards, not a dropdown, for the build.** `InstallSource` has four cases and a `Menu`+`Picker`
  showed one line at a time; the differences between "SideStore" and "SideStore + LiveContainer" are
  exactly what a one-line menu hides. A 2×2 grid of cards shows all four, their one-line
  descriptions, and the selection.
- **The version list is a page, not a menu.** Release titles can carry a maintainer's warning
  (`0.6.4 (DO NOT USE)`); a `Menu` truncates them and a picker can't show a second line. The sheet
  lists releases with the remark under the title, plus the channel control and the fetch error with
  its retry.
- **Chips are values, not buttons.** `InstallOptionChip` takes its text from engine state
  (`selectedVersion`, `releaseCatalog.latest`, `importedPairingName`, `config.summary.count`), so a
  chip can't disagree with what the run will do — there's no second copy of the choice to drift.
- **The catalog is fetched when the card appears**, not when the version sheet opens, because the
  chip names the release ("Latest (2.4.1)") and would otherwise read "Latest" until the sheet had
  been visited once.
- **`AppConfigView` is unchanged** — it was already the page the Configuration chip opens. The card
  only gained the chip, which counts `config.summary` so the change is visible without opening it.

### Tools tab: rows as data

- **`ToolEntry` is the page.** Title, status line, glyph, beta flag and destination live in one
  struct, and `ToolsView` renders sections from an array of them. Search (`haystack`), the section
  headers and the row count all derive from that list, so a page can't be added without a status line
  and can't be findable in search but missing from the menu.
- **One switch builds every destination** (`page(_:)`), so a row's `ToolDestination` and the view it
  opens can't drift. Pages that own a `NavigationStack` (Sources, Report, About) say so
  (`presentsAsSheet`) and are presented instead of pushed — pushing one would nest a second stack.
- **Status comes from the stores, not from the page.** Certificates read `certManager.certs` for the
  signing certificate's expiry, stored builds read `IPACache.all()` **on appear** (it's a directory
  listing; a body is not the place), history reads `InstallHistory.shared.entries`, sources and
  tweak repositories read their published arrays. The only coloured detail is a certificate that is
  close to expiring or has expired.
- **Grouping is by what you're doing, not by data source**: "Signing" holds entitlement editing and
  pairing because they're the three things that decide whether a build installs at all; the
  inspector sits with builds, not with files.
- **Why About/Report moved here**: both already existed as sheets opened from Settings or from
  another page's toolbar. A menu of pages is the honest place for them, and duplicating the entry
  costs nothing — they're the same views.

### Tools performance: what was actually slow

Every one of these was work in a `body` or a synchronous file call on the main actor, which is why
the pages felt like they hung rather than merely loading:

| Where | What it did | Now |
|---|---|---|
| Device info | `StorageReport.size(of: NSHomeDirectory())` — a recursive walk of every file in the app container — plus `IPACache.totalBytes()`, in a computed property used by `body` | measured once in `onAppear`, in `Task.detached`, into `@State`, with a "Measuring…" row |
| Stored builds | `IPACache.totalBytes()` in the header's `StatusPill`, i.e. a folder listing on every redraw; `IPACache.all()` on the main actor | `IPACache.load()` (async), and the total summed from the entries already read |
| Install history | `entry.cachedURL` per row per body — a `fileExists` per row, 200 of them at the limit | one detached pass per appearance building a `Set<UUID>`; the URL is resolved when the button is tapped |
| Injected libraries | `IPALibrary.contents` inflated each build's whole executable (no cap after the `max:` removal) | `IPALibrary.prefix(of:in:limit:)` inflates the first 8 MB into a small buffer; `compression_decode_buffer` stops when the destination fills, which is exactly the prefix a Mach-O header needs |
| Report a problem | `ProblemReport.current(engine)` in `body`, which maps and redacts the entire activity log | built once, kept in `@State` |
| Tools hub | certificate expiry parsed and formatted per redraw | formatted on `onAppear` and when the certificate list changes; `DevCert` shares its `ISO8601DateFormatter`s |
| Settings › Storage | four directory walks in `onAppear` on the main actor | `Task.detached` |
| About | QR code drawn by Core Image in `body` | drawn once per address, off-main |

Two rules came out of this and are worth keeping: **no file-system call in a `body`** (a `body` can
run tens of times a second while a text field has focus), and **no unbounded inflate of a member**
— a zip entry's `uncompressedSize` is attacker-controlled in a downloaded `.ipa`, so the reader
bounds what it allocates.

### Settings, folded into Tools

- **The gear was in fourteen toolbars.** `settingsToolbarItem(isPresented:)` was one extension
  applied by every page, which made Settings look like a property of each screen — the one control
  that doesn't change with context. It's now a single row at the top of **Tools**, a page that is
  nothing but "the app's own stuff", presented as the same sheet with the same Done.
- **What had to be true for the removal to be honest:** every page that lost its gear must still
  have a way back to the tab bar (they're all pushed inside the tab's `NavigationStack`, or sheets
  that dismiss), and the one page presented *only* as a sheet from Tools — About — needed its own
  Done, so `AboutView(showsDone:)` was added (`false` when pushed from Settings, where the back
  button already exists).
- **Search doesn't hide it.** The Settings card is drawn only while the search field is empty, so a
  search shows results only, but the entry itself is not a section entry and doesn't inflate the
  "N pages" count — it's the app's control, not one of the pages being searched.

### Compact headers for the list tabs

- **`BrandHeader(compact:)`** is one flag on the existing header rather than a second type: the
  glyph drops from 86 to 34 points, the title from `largeTitle` to `title3`, and the accessory (the
  status pill) sits under the row instead of under a centred hero. The icon's corner radius and
  symbol size are derived from `glyphSide`, so they scale with it without a second set of numbers.
- **Only the three tabs that open with a list use it** — Install, My Apps, Tools. Pushed pages keep
  the hero: they're read once, not scrolled past.
- **`hasAccessory`** compares `Accessory.self` with `EmptyView.self` so the stack doesn't reserve
  spacing for a header that has nothing to show under it. The pill keeps its `.id` and transition,
  so the cross-fade when the tunnel state changes is unchanged.

### One button size

- **`PrimaryButtonStyle` was the app's biggest control** — `headline`, 16 points of vertical
  padding, 18-point corners, a 16-point glow — at about 52 points tall, next to `.bordered` buttons
  at 34 and chips at 30. It's now `subheadline` semibold, 12 points, 14-point corners and a
  10-point glow: ~40 points, which is the platform's own comfortable touch height and reads as a
  sibling of the chips rather than a different family.
- **`SecondaryButtonStyle` exists so pairs line up.** The "No, or I'm not sure" button on the
  account check was a hand-built copy of the old primary (16 points, radius 18, custom fill); it's
  the new secondary now, which is defined in the same terms as the primary and will stay in step
  with it.
- **The Install button is deliberately excluded.** It isn't a row action: the same surface grows
  into the run's progress card, and its height and corners are part of that animation. Shrinking it
  would have made the app's main action the smallest thing on the screen.

### My Apps: the page opens on the apps

- **Three page-wide buttons and two cards sat above the list** — Refresh all, Install all updates,
  Reload, the JIT card and the refresh-run card. The actions that concerned the whole list are now
  in the toolbar or under it: updates behind an icon with a count, reload as an icon, refresh all
  below the last row. The top of the page is the search field and the apps, which is what it's for.
- **The updates sheet is a list, not a card.** Each row carries the app's icon, `1.2 → 1.6` in
  monospace and its own install button; the bottom button installs all of them in the same order the
  card did. `updateAll` still sequences them one at a time — they share the device link and Apple's
  rate limit.
- **`preloadIcons()`** runs `loadIcons` for whatever the list already holds, so PNGs cached on disk
  fill the column before (or without) a device read. That was the difference between a row with an
  icon and a row with a letter.

### Install menu: presets, then everything else

- **A dropdown and a version menu share a row** because they're one decision: what to install, and
  which release of it. The dropdown only lists the three builds SideInstaller can fetch; the custom
  `.ipa` is a separate button because it isn't a release at all.
- **`InstallSigningPanel`** is the expander's body, and each section states the honest limit: the
  identity fields keep the build's own value when empty, a capability writes the keys the app
  expects but the profile decides what's granted, and an injector is only downloadable for the two
  that are open source.
- **`AppCapability`** maps a switch to plist keys and entitlements, and its disable path removes
  only the value it wrote from a list (`UIBackgroundModes` keeps `location` when `audio` goes),
  rather than deleting the key someone else may have set.
- **Tweak storage is its own store** (`TweakLibrary`) with a JSON index beside the files; applying
  goes through `AppConfigStore.addTweaks`, so the library can't disagree with the configuration
  about what a `.deb` contributes.

### Bulk install, and why the files are copied first

- **A picker URL is a lease, not a path.** `startAccessingSecurityScopedResource()` ends when the
  picker closes, so a queued URL would be unreadable by the time the queue reached it.
  `BulkInstallStage` copies each file into `Application Support/BulkInstall` first, and
  `prune(keeping:)` deletes copies whose item has left the queue.
- **The queue already existed**, from the "install queue" work: it starts a build, waits for
  `Engine.isRunning` to clear, records done/failed and pauses two seconds between items. Bulk install
  only needed `run()` to take a file URL through `installLocalIPA` instead of the link path.

### Settings adopted, then cleared

- **Adoption is deliberately partial.** `AppConfigStore.adopt(info:entitlements:)` takes the identity
  and the five capabilities the panel can express; copying every `Info.plist` key would be noise,
  and copying the build's entitlements would write back a document the signing profile replaces.
- **Clearing happens at one place**: the end of `runOneClick`, after `stopBackgroundWork()`. That
  covers success, failure and cancellation without three call sites drifting, and it's what makes
  back-to-back installs safe — the second app can't inherit the first one's bundle ID, capability
  edits or injected dylibs. `reset()` deliberately leaves injectors alone.

### Telegram: listing an account's channels without an account

- **There is no MTProto client in this build**, so "every channel I'm in" can't be asked of
  Telegram directly. The full desktop export already answers it: `result.json` carries
  `chats.list` (every dialog, with `username` for public channels) and `messages` tagged with
  `peer_id`. `TelegramDiscovery` joins the two — `.ipa` counts per peer — and the studio offers the
  result as a list.
- **Peer ids arrive in two shapes** (`channel123456` and `123456`); both are reduced to digits so the
  join works. A single-chat export has no chat list and falls back to the JSON's own name.
- **Only public handles are addable**: without one there's no `t.me/s/` preview to read, and no
  account to read it with. Those channels stay in the list, marked, rather than being hidden — a
  list that silently drops half the account is worse than one that explains itself.

### Background keep-alive

- **Two modes, both declared in the plist already** (`audio`, `location`): silent audio through
  `AVAudioEngine` with a looped empty buffer, or `CLLocationManager` at three-kilometre accuracy with
  `allowsBackgroundLocationUpdates`. The audio session is the dependable one; location costs less
  battery but dies without permission and puts an arrow in the status bar.
- **`pendingLocationStart`** exists because `requestAlwaysAuthorization` returns immediately: without
  it, `start(.location)` would mark the keep-alive running before anything was, and the delegate's
  guard (`mode == .off`) would then refuse to start it. The delegate is where a granted prompt
  finishes the job.
- **Restore is asymmetric on purpose**: audio comes back at launch (it's silent and expected), but
  location only does when permission is already there — a prompt on launch would be the app asking
  for something the user didn't just request.
- **`BackgroundKeepAlive` (BGTask, for the Telegram source) is untouched**: that's the periodic
  refresh path, a different mechanism with a different ceiling. This one is the deliberate
  user-facing switch.
