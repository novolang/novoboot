# Changelog

All notable changes to novoboot are recorded here.  This package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the
pre-1.0 rule that a breaking change bumps the MINOR number.

## [Unreleased]

### Added

- `rdcert.nv`, the RD certificate: a record the release key signs that names one device by its factory id, allows an unsigned image or an image
  signed by a development key, and bounds the boots it serves.  The bootloader reads it from the status region's last erase unit at each start
  where the table says `signing = "required"` and the board has such a unit, says one line (`rd: for this device, N boots left`, `rd: other
  device`, `rd: bad signature`, `rd: spent`, `rd: unusable`) and counts the boot in the unit's tail, a word for each boot, so the count needs
  no erase.  `bootimg.signed_by` is the signature check of an image header and of a certificate, and `bootimg.u32_at` and `u16_at` are public.
  The swap erases the status region below the certificate's unit.  `tests/rd_tests.nv` has the cases, and section 8b of `tests/board_boot.sh`
  runs them on a board with a unit for the record (the nRF54LM20 DK).  The toolchain makes a certificate with `novo image rd` and writes it
  with `novo flash --rd`; mcumgr-nv's `/rd` is the second route.

### Changed

- `bootdev.BoardSlots.program` writes a page with one `hal.boot.copy`, where it called `hal.boot.write_word` at each word.  A word cost the flash driver's write enable, commit and write disable (146 microseconds on the nRF54LM20, 36 milliseconds for the 984 bytes of an upload request in the firmware update demo), and the copy takes them once for the page: 2.6 milliseconds a page with the buffered driver of the board support package, 7.8 milliseconds for a whole request.  It reads the page where it lies, so it checks at each page that a `Vec`'s octets follow its 8-octet length (as `pdu_mem.nv` of the nRF54 blocks does), and falls back to the word loop if they do not.  The board run of `tests/board_boot.sh` is the check; the host has no flash to program.  Filed with the driver as `bugs/orbit/rram-driver-stores-unbuffered.md`.

## [0.2.1] — 2026-11-15

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
