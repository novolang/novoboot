# novoboot

A bootloader in novo-lang for a board whose manifest has a `[flash]`
table with the A/B layout, and the writer an application uses to put an
update into the layout's second slot.  The page for the layouts, the
header and `hal.boot` is
[the bootloader](../../docs/embedded/bootloader.md); this page is the
package.

## What it is

**The bootloader** (`src/main.nv`) runs first.  It checks the image
header of slot A and slot B (the magic, the header's CRC-32C, the sizes,
the chip and board ids, the SHA-256 of the image, an Ed25519 signature
where the image carries one), applies the A/B rule (`abrule.nv`), moves
the images through the swap area with a record in the status region
(`swaprec.nv`), and starts slot A, an image on trial under the watchdog.
Build it with `novo build --target=<board> --role=bootloader src/main.nv`.

**The RD certificate** (`src/rdcert.nv`) is a development opening on a
production device.  Where the table says `signing = "required"` and the
status region has a unit for it, the bootloader reads a record there before
it checks the slots: a certificate the release key signed, for this
device's factory id, that lets the device take an unsigned image, or one
signed by a development key, for a bounded number of boots.  It says one
line (`rd: for this device, 11 boots left`, `rd: other device`, `rd: bad
signature`, `rd: spent`, `rd: unusable`) and counts the boot in the unit's
tail.  `novo image rd` makes a certificate, `novo flash --rd` and the file
group's `/rd` write it and `novo flash --rd-erase` revokes it; [the
bootloader page](../../docs/embedded/bootloader.md#rd) has the record, the
unit and the lines.  The package's `rdcert` functions check a certificate
over any `ByteSource`, so the host suite runs the bootloader's own code.

**The slot writer** (`src/bootslot.nv`) is what a running application
calls to stage an update.  It writes slot B and nothing else.

| Call | What it does |
| --- | --- |
| `accept_header` | Checks the image's first `header_bytes` bytes before anything is erased: magic, CRC-32C, header version and size, chip and board ids, the image within the slot, the unsigned bit against the signing policy.  Answers `bootimg`'s answer. |
| `begin` | Erases slot B unit by unit through the end of the image, unless it holds the only image the bootloader could revert to (`SLOT_BUSY`), and programs the header with its three state words erased. |
| `program` | Programs a page of the image at an offset and reads it back. |
| `durable` | The image offset to resume from: the start of the last 512-byte page that holds a byte other than 0xFF.  The device keeps no record; slot B is the record. |
| `whole` | Whether slot B holds a whole image and not the part of one a transfer has written so far: its header passes the checks and the image is marked, or the last page of the image holds a byte other than 0xFF.  Reads one page where the hash reads the image. |
| `commit` | Checks the SHA-256 of the whole image against the header and programs the pending word.  The bootloader's next start swaps the slots and tries the image. |
| `abandon`, `erase` | Erase the first unit, or all, of slot B, with the same guard as `begin`. |
| `staged`, `staged_bytes`, `is_pending`, `slot_info` | What slot B holds, and a report of either slot's header: version, hash, pending, tried, confirmed. |

The writer takes a device that is a `SlotDev` and a `ByteSource`.
`bootdev.nv` is the board's, over `hal.boot` and the core reading the
slots; `bootram.nv` is two slots in RAM with NOR rules and a power cut
after a chosen operation; a device of your own implements the two
traits.  Nothing is allocated after start-up.  The writer does not
check an Ed25519 signature: it carries no key, and the bootloader
verifies every image it starts.

## Install

```
novo pkg add novoboot
```

[dfu-nv](../dfu-nv/README.md) 0.2.0 depends on it by path, and
[mcumgr-nv](https://novo-lang.org/packages/mcumgr-nv) 0.1.2 by the range
`^0.2.1`; their device programs are the writer in use.

## Tests

```bash
novo test tests/vectors_tests.nv     #  7: SHA-256 and Ed25519 against the published vectors
novo test tests/abrule_tests.nv      #  2: the A/B rule, case by case
novo test tests/bootslot_tests.nv    # 15: the slot writer on RAM slots, a power cut at every flash operation
novo test tests/rd_tests.nv          # 10: the RD certificate on four certificates the toolchain made
```

`tests/bootslot_tests.nv` cuts the power at each of the 60 flash
operations of an update, once leaving the operation undone and once
tearing it after 8 bytes, and asks `abrule.nv` over `bootimg.nv`'s checks
what the bootloader would start: the old image or the new one whole, each
time; the update run again leaves the new image pending.
`tests/rd_tests.nv` checks the certificate for this device, for another
device, signed by another key, with a byte changed, with a magic that is not
one, with its boots counted and spent, and the opening each one gives.
`tests/orbit/test_novoboot.sh` in the novo-lang repository runs these, the
`[flash]` table's checks, the stamped headers and the bootloader's build,
and builds `tests/slot_probe.nv` for each board with a table.  Each
board's `tests/boot.sh` is the bench for the bootloader and
`tests/dfu_boot.sh` the bench for an update by dfu-nv.

## Licence

Apache-2.0.
