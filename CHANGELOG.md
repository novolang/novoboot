# Changelog

All notable changes to novoboot are recorded here.  This package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the
pre-1.0 rule that a breaking change bumps the MINOR number.

## [Unreleased]

### Added

- `bootslot.whole` says whether slot B holds a whole image and not the part of one that a transfer has written so far.  The header is the first
  page a transfer writes, so a header that passes its checks says nothing of the bytes after it.  An image is whole when its header passes the checks
  and its pending or tried word is programmed, or the last page of the image holds a byte other than 0xFF; the pages are written in order, so
  the last one is written when all of them are.  It reads one page at most, where the hash reads the whole image.  A power cut inside the
  programming of the last page leaves a page written in part that counts as written, and `commit` and the bootloader refuse that image by its hash.
  `tests/bootslot_tests.nv` has the case.  mcumgr-nv 0.1.2 lists slot 1 by it.

### Fixed

- A swap puts the image that leaves slot A into slot B with its three state words erased (pending, tried, confirmed), unless that image
  failed its trial (pending, tried and not confirmed), which keeps its marks since they stop the bootloader from trying it again.  The marks of
  the time an image ran in slot A stayed with it into slot B: an image that a request had marked pending and confirmed (the "Confirm" button
  of a client on the row of the other image) was swapped back in at the next plain reset, after the update that had replaced it was confirmed.
  `swaprec.nv` leaves the words out of the copy of the swap area's first unit into slot B; `tests/board_boot.sh` section 3b checks it on a
  board and `smpsim.nv` of mcumgr-nv 0.1.2 does the same on RAM slots.

### Changed

- `bootslot.accept_header` takes a header of more than one page, held by its first page: the nRF54LM20's vector table is aligned to 2 KB, so
  its header is 2 KB, whose fields are in the first 256 bytes and whose other bytes are 0xFF.  Before, a policy with a header of more
  than 512 bytes answered `IMG_BAD_HEADER` to every header.  `tests/bootslot_tests.nv` has the case.
- `tests/board_boot.sh` takes three optional settings of a board, `DL_FLAGS`, `SLOT_ERASE_BYTES` and `BOARD_RESET`, for the nRF54LM20 DK
  (`orbit/bsp/nordic/nrf54/nrf54lm20-dk/tests/boot.sh`).

## [0.2.0] — 2026-11-14

The slot writer: what an application uses to put an update into slot B.
The bootloader program, the header checks and the A/B rule are as they
were, and the bootloader image is the same size.

### Added

- `bootslot.nv`: `SlotDev`, the device the writer writes through, and
  `accept_header`, `begin`, `program`, `commit`, `durable`, `abandon`,
  `erase`, `staged`, `staged_bytes`, `is_pending` and `slot_info`.  The
  header is checked before any erase, including the unsigned bit against
  the signing policy; slot B is erased unit by unit unless it holds the
  only image the bootloader could revert to; the image is programmed a
  page at a time with a read back; `commit` checks the SHA-256 of the
  whole image and programs the pending word.  A transfer resumes from
  `durable`, the start of the last 512-byte page that holds data.
  Nothing is allocated; the staged header is held in a 512-byte buffer.
- `bootdev.nv`: the board's slots as a `SlotDev` and a `ByteSource`,
  over `hal.boot` for an erase and a program and `hw.mem_read8` for a
  read.  `slots` and `policy` take the numbers of the board's `[flash]`
  table, which the program reads from `bsp.board.flash_*`.
- `bootram.nv`: two slots in RAM with NOR rules and a power cut after a
  chosen operation, clean or torn, for host suites.
- `hostimg.nv`: a NOVB image built on the host, for host suites.
- `tests/bootslot_tests.nv`: 15 tests, every line of `bootslot.nv`,
  `bootram.nv` and `hostimg.nv` run (the two `impl`s of `bootdev.nv`
  need a board and carry `cov: skip`), and a power cut at each of the 60
  flash operations of an update with the bootloader's own rule asking
  what would start.
- `tests/slot_probe.nv`, built with `--role=application` for the boards
  with a table, and `tests/dfu_boot.sh`, the bench for an update by
  dfu-nv on a board.

## [0.1.0] — 2026-10-08

The bootloader: the image header checks (CRC-32C, chip and board,
SHA-256, Ed25519), the A/B rule with the copy into slot A, the swap with
its record in the status region, and the watchdog-guarded trial.
