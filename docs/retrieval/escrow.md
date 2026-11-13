# Escrow

In escrow mode (the default), your MDM collects the password from each Mac with an inventory attribute that runs:

```bash
macOSLAPS -escrow
```

It prints one line of JSON:

```json
{"v":1,"account":"ladmin","password":"…","set":"2026-11-12T20:40:00Z","expires":"2027-01-11T20:40:00Z","verified":true,"host":"Mac-1234"}
```

| Field | Meaning |
|---|---|
| `account` | The managed admin |
| `password` | Its current password |
| `set`, `expires` | When it was set and when it rotates next (ISO 8601, UTC) |
| `verified` | Whether the password worked for the account just now |
| `host` | The Mac's computer name |
| `pending`, `pendingSet` | With [staged rotation](#staged-rotation): the next password, not yet in use |

Log messages go to stderr, so the attribute captures only the JSON. Ready-made scripts for Jamf Pro, Intune, Workspace ONE and other MDMs are described in [MDM setup](../mdm.md).

!!! warning "Who can read it"
    In plain escrow, anyone who can read the inventory attribute can read the password. Limit who can see it, or use [encrypted escrow](encrypted-escrow.md).

## Staged rotation

A rotation that happens right after your MDM's last inventory would leave the MDM with an old password until the next one. Staged rotation closes that gap:

1. The new password is first stored as **pending**, and `-escrow` reports it next to the current one (`pending`, `pendingSet`).
2. macOSLAPS changes the account to it only after `-escrow` has reported it `EscrowConfirmations` times (default 2).

So your MDM always holds the password the Mac is using. Keep both values: if the current password doesn't work, try the pending one.

`StagedRotation auto` (the default) stages only on Macs where `-escrow` ran in the last 14 days. `on` always stages, `off` never does. A first rotation with `-firstPass`, or a Mac with no stored password, always rotates immediately.

## Refreshing inventory after a rotation

`InventoryHook jamf` runs `jamf recon` after each rotation. For other MDMs, set `InventoryHook custom` and put your agent's command in `InventoryHookCommand`, one argument per item. If that command collects inventory (so it runs `-escrow`), set `InventoryHookConfirms true` and it counts towards `EscrowConfirmations`.
