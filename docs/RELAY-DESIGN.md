# Relay server: security design (not built yet)

Purpose: let a phone reach its PC from any network without the user touching their router.
This is the plan to build from when there is funding for hosting. Nothing here exists in the apps yet.

## The rule everything follows

**The relay is a pipe that cannot read, change or forge anything.** If the server is hacked, seized or
run by someone dishonest, the worst they can do is stop the service and see connection metadata.

## How it works

1. **PC connects out.** PC Power opens an outgoing connection to the relay and keeps it open. No router setup.
2. **PC proves who it is.** Its address on the relay is the fingerprint of the certificate it already has.
   It proves ownership by signing a fresh challenge with that certificate's private key, which never
   leaves the PC. Nobody else can claim a PC's address.
3. **Phone asks for that address.** The phone already knows the fingerprint from pairing. The relay joins
   the two connections and copies bytes between them.
4. **Same encryption as at home, inside the pipe.** Phone and PC run the existing TLS 1.3 session through
   the relay: the phone still checks the PC's pinned certificate, and the PC still demands the phone's
   token. The relay sees only encrypted bytes.

## What each party can and cannot do

| Party | Can | Cannot |
|---|---|---|
| Relay operator or attacker on the relay | Drop connections; see which PC addresses are online, IP addresses and timing | Read commands, send commands, pose as a PC or a phone |
| Stranger on the internet | Connect to the relay | Find a PC (addresses are 256-bit and unguessable), reach one without being a paired phone |
| Paired phone | Everything it can do at home | Pair another phone remotely |

## Decisions

- **No accounts, passwords or user database.** Nothing to steal, no reset flows to attack.
- **Pairing stays home-only.** The relay never carries pairing requests; the PC refuses them unless they
  come from its own network.
- **Turn on through another PC.** A phone paired with PC B can ask B, through B's own encrypted tunnel,
  to send the wake signal for a PC on B's network. B only ever sends wake signals on its own network.
  A home with every device off still cannot be woken; that needs one always-on device.
- **Abuse limits.** Per-address and per-IP connection rates, idle timeouts, a cap on bytes per session
  (commands are tiny), and no payload logging.
- **Server hardening.** One small program, no database, not running as administrator, automatic
  security updates, and published source so the "cannot read anything" claim can be checked.
- **Opt-in.** The PC only connects to the relay if the user switches it on, and the app shows when it is in use.

## Before launch

- Independent review of this design and the pairing protocol.
- A privacy policy that lists the metadata the relay sees and how long it is kept.
