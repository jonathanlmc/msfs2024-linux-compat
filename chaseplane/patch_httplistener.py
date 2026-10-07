#!/usr/bin/env python3
"""Make the linux-x64 build of System.Net.HttpListener.dll loadable by CoreCLR under Wine.

The net8.0-unix build is emitted with SectionAlignment = FileAlignment = 0x200 and every
section's VirtualAddress different from its PointerToRawData, which CoreCLR and Wine
reject. This moves each section's bytes to the address it already occupies in memory and
repoints PointerToRawData, so no RVA moves and every RVA-based structure (COR20,
metadata, base relocations, exception directory, resources) stays valid. Only the
Authenticode overlay, addressed by file offset, has to be re-pointed. The machine field is
rewritten 0xfd1d -> 0x8664. See docs/internals.md for the measured failure modes.

Usage:
  patch_httplistener.py check <file>            report whether the file is loadable
  patch_httplistener.py patch <in.dll> <out>    write the re-laid-out copy
"""

import struct
import sys

# PE header constants. Offsets are relative to the PE signature unless stated otherwise.
MACHINE_LINUX = 0xFD1D     # machine value the linux-x64 package ships; CoreCLR rejects it
MACHINE_AMD64 = 0x8664     # IMAGE_FILE_MACHINE_AMD64
PE32PLUS = 0x20B           # optional-header magic for PE32+
SECTION_HEADER_SIZE = 40   # bytes per section header entry
SECTION_RAW_POINTER = 20   # PointerToRawData field, offset within a section header
DATA_DIRS = 112            # first data directory, offset within the optional header
OPT_SECTALIGN = 32         # SectionAlignment/FileAlignment pair, optional header
OPT_SIZEOFIMAGE = 56       # SizeOfImage/SizeOfHeaders pair, optional header
DIR_CERTIFICATE = 4        # data-directory index of the Authenticode signature
DIR_COR20 = 14             # data-directory index of the CLR runtime header


class PE:
    def __init__(self, data: bytearray):
        self.b = data
        self.e = struct.unpack_from("<I", data, 0x3C)[0]   # e_lfanew: offset of the PE signature
        if data[self.e:self.e + 4] != b"PE\0\0":
            raise ValueError("not a PE image")
        self.nsec = struct.unpack_from("<H", data, self.e + 6)[0]      # NumberOfSections
        self.sizeopt = struct.unpack_from("<H", data, self.e + 20)[0]  # SizeOfOptionalHeader
        self.opt = self.e + 24
        if struct.unpack_from("<H", data, self.opt)[0] != PE32PLUS:
            raise ValueError("not PE32+")
        self.dd = self.opt + DATA_DIRS
        self.sections = self.e + 24 + self.sizeopt
        self.sectalign, self.filealign = struct.unpack_from("<II", data, self.opt + OPT_SECTALIGN)
        self.sizeofimage, self.sizeofheaders = struct.unpack_from("<II", data, self.opt + OPT_SIZEOFIMAGE)

    def machine(self):
        return struct.unpack_from("<H", self.b, self.e + 4)[0]   # Machine

    def set_machine(self, value):
        struct.pack_into("<H", self.b, self.e + 4, value)   # Machine

    def dir(self, index):
        return struct.unpack_from("<II", self.b, self.dd + index * 8)

    def set_dir(self, index, rva, size):
        struct.pack_into("<II", self.b, self.dd + index * 8, rva, size)

    def sections_list(self):
        out = []
        for i in range(self.nsec):
            base = self.sections + SECTION_HEADER_SIZE * i
            name = self.b[base:base + 8].rstrip(b"\0").decode("latin1")
            vsz, va, rsz, raw = struct.unpack_from("<IIII", self.b, base + 8)
            out.append((name, vsz, va, rsz, raw, base))
        return out

    def set_raw(self, section_base, value):
        struct.pack_into("<I", self.b, section_base + SECTION_RAW_POINTER, value)

    def to_offset(self, rva):
        for _, vsz, va, rsz, raw, _ in self.sections_list():
            if va <= rva < va + max(vsz, rsz):
                return raw + (rva - va)
        return None


def align(value, granularity):
    return (value + granularity - 1) // granularity * granularity


def is_loadable(pe: PE):
    """The layout requirement CoreCLR and Wine's loader actually enforce.

    Measured against the real 8.0.31 assemblies: SectionAlignment 0x200 is fine as long as
    every section's PointerToRawData equals its VirtualAddress. VA != raw is what fails,
    and SectionAlignment < page size only makes it fail earlier (in Wine's loader).
    """
    problems = []
    if pe.machine() not in (MACHINE_AMD64, MACHINE_LINUX):
        problems.append(f"machine {pe.machine():#06x}")
    for name, _, va, _, raw, _ in pe.sections_list():
        if va != raw:
            problems.append(f"{name}: VirtualAddress {va:#x} != PointerToRawData {raw:#x}")
    return problems


def verify(pe: PE):
    """Self-check: the RVA-addressed structures must still resolve after the move."""
    cor_rva, _ = pe.dir(DIR_COR20)
    cor = pe.to_offset(cor_rva)
    if cor is None:
        raise AssertionError("COR20 header RVA no longer maps to a section")
    cb, major, minor = struct.unpack_from("<IHH", pe.b, cor)
    if cb not in (0x40, 0x48) or major != 2:   # COR20 header is 0x48 (0x40 in older runtimes)
        raise AssertionError(f"COR20 header looks wrong at {cor:#x} (cb={cb:#x}, major={major})")
    meta_rva, meta_size = struct.unpack_from("<II", pe.b, cor + 8)   # Metadata RVA + size in COR20
    meta = pe.to_offset(meta_rva)
    if meta is None or pe.b[meta:meta + 4] != b"BSJB":
        raise AssertionError(f"metadata root not found at RVA {meta_rva:#x}")
    streams = struct.unpack_from("<H", pe.b, meta + 30)[0]           # stream count in the metadata root
    version = pe.b[meta + 16:meta + 16 + struct.unpack_from("<I", pe.b, meta + 12)[0]]  # version string
    return (f"COR20@{cor:#x} cb={cb} runtime={major}.{minor} "
            f"{version.split(b'\\0')[0].decode()} metadata@{meta:#x} ({meta_size} B) streams={streams}")


def patch(src, dst):
    data = bytearray(open(src, "rb").read())
    pe = PE(data)

    before = is_loadable(pe)
    if not before:
        print(f"{src}: already loadable, copying through unchanged")

    if pe.machine() == MACHINE_LINUX:
        pe.set_machine(MACHINE_AMD64)
        print(f"  machine {MACHINE_LINUX:#06x} -> {MACHINE_AMD64:#06x}")

    # Source layout: every section's bytes and the Authenticode overlay that follows them.
    secs = pe.sections_list()
    raw_end = max(raw + rsz for _, _, _, rsz, raw, _ in secs)
    overlay = data[raw_end:]                      # Authenticode blob, addressed by file offset

    # Destination: headers, then each section at the address it already has in memory.
    out = bytearray(data[:pe.sizeofheaders])
    pe_out = PE(out)                              # same header layout, so same offsets
    for i, (name, vsz, va, rsz, raw, _) in enumerate(secs):
        if va < pe.sizeofheaders:
            raise AssertionError(f"{name}: VirtualAddress {va:#x} below SizeOfHeaders")
        if va % pe.filealign:
            raise AssertionError(f"{name}: VirtualAddress {va:#x} not a multiple of FileAlignment")
        end = va + align(rsz, pe.filealign)
        if len(out) < end:
            out.extend(b"\0" * (end - len(out)))
        out[va:va + rsz] = data[raw:raw + rsz]
        pe_out.set_raw(pe.sections + SECTION_HEADER_SIZE * i, va)

    # The overlay is addressed by file offset, so it has to be re-pointed after the move.
    out += overlay
    _, cert_size = pe.dir(DIR_CERTIFICATE)
    if cert_size:
        pe_out.set_dir(DIR_CERTIFICATE, len(out) - len(overlay), cert_size)

    # Grow SizeOfImage if the new file layout needs more of it.
    last = max(va + align(rsz, pe_out.sectalign) for _, _, va, rsz, _, _ in pe_out.sections_list())
    if pe_out.sizeofimage < last:
        struct.pack_into("<I", pe_out.b, pe_out.opt + OPT_SIZEOFIMAGE, last)

    open(dst, "wb").write(out)
    print(f"  sections re-laid out (PointerToRawData == VirtualAddress), "
          f"overlay {len(overlay)} B re-pointed, {len(data)} -> {len(out)} B")


def main(argv):
    if len(argv) < 3 or argv[1] not in ("check", "patch"):
        print("usage: patch_httplistener.py check <file> | patch <in.dll> <out.dll>")
        return 2

    if argv[1] == "check":
        pe = PE(bytearray(open(argv[2], "rb").read()))
        problems = is_loadable(pe)
        print(f"{argv[2]}: machine {pe.machine():#06x}, "
              f"SectionAlignment {pe.sectalign:#x}, FileAlignment {pe.filealign:#x}")

        for name, _, va, _, raw, _ in pe.sections_list():
            print(f"  {name:8} VA {va:#08x} raw {raw:#08x} {'ok' if va == raw else 'MISMATCH'}")
        print(f"  {verify(pe)}")
        if problems:
            print("  NOT loadable: " + "; ".join(problems))
            return 1
        print("  loadable")
        return 0

    src, dst = argv[2], argv[3]
    patch(src, dst)
    pe = PE(bytearray(open(dst, "rb").read()))
    problems = is_loadable(pe)
    if problems:
        print(f"  FAILED self-check: {'; '.join(problems)}", file=sys.stderr)
        return 1
    print(f"  {verify(pe)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
