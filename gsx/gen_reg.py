"""Generate the COM registration .reg for QlmLicenseLib.dll (FSDT license library).

Wine Mono's regasm can't register it (RegistrationServices is unimplemented),
so replicate what regasm would write: ProgId + CLSID trees with the type GUID
derived the same way .NET derives it (MD5 of the full type name, big-endian
first three fields), plus Assembly/CodeBase/RuntimeVersion values.

Usage: gen_reg.py <QlmLicenseLib.dll> <out.reg>
Requires dnfile (`pip install dnfile`; apply.sh auto-creates a venv for it).
"""
import dnfile
import hashlib
import struct
import sys

# regasm's fixed registry values: mscoree.dll hosts in-process .NET COM servers,
# v4.0.30319 is the .NET Framework 4 runtime stamp, and FSDT always installs the
# license library to this path.
INPROC_SERVER = "mscoree.dll"
RUNTIME_VERSION = "v4.0.30319"
DLL_WINPATH = "C:\\Program Files (x86)\\Addon Manager\\QlmLicenseLib.dll"

if len(sys.argv) != 3:
    sys.exit("usage: gen_reg.py <QlmLicenseLib.dll> <out.reg>")

DLL, OUT = sys.argv[1], sys.argv[2]

pe = dnfile.dnPE(DLL)
md = pe.net.mdtables
a = md.Assembly.rows[0]

# dnfile exposes the assembly public key as raw bytes or as a .value wrapper
# depending on version.
pk = a.PublicKey.value if hasattr(a.PublicKey, "value") else bytes(a.PublicKey)

# Public key token = last 8 bytes of the public key's SHA-1, reversed to
# little-endian. Empty key (unsigned assembly) registers as "null".
token = hashlib.sha1(pk).digest()[-8:][::-1].hex().upper() if pk else "null"
ver = f"{a.MajorVersion}.{a.MinorVersion}.{a.BuildNumber}.{a.RevisionNumber}"


def ctor(row):
    mr = row.Type.row
    tr = mr.Class.row
    return f"{tr.TypeNamespace}.{tr.TypeName}"


# Collect ProgIdAttribute usages: attribute string argument -> declaring type.
progids = {}

for row in md.CustomAttribute.rows:
    if ctor(row) == "System.Runtime.InteropServices.ProgIdAttribute":
        tgt = row.Parent.row
        if not hasattr(tgt, "TypeName"):
            continue
        ns = str(tgt.TypeNamespace)
        name = str(tgt.TypeName)
        # Attribute value blob: 2-byte ELEMENT_VALUE prologue, 1-byte compressed
        # length, then the UTF8 string terminated by NUL.
        pid = row.Value.value[3:].split(b"\x00")[0].decode()
        progids[pid] = f"{ns}.{name}"


def guid_for(fullname):
    # .NET's type GUID: MD5 over the full type name. The first three fields are
    # read little-endian from the digest; the last two stay big-endian.
    h = hashlib.md5(fullname.encode()).digest()
    d1, d2, d3 = struct.unpack("<IHH", h[0:8])
    return f"{{{d1:08X}-{d2:04X}-{d3:04X}-{h[8:10].hex().upper()}-{h[10:16].hex().upper()}}}"


lines = ["Windows Registry Editor Version 5.00", ""]

for pid, full in sorted(progids.items()):
    g = guid_for(full)
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\{pid}]")
    lines.append(f'@="{full}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\{pid}\\CLSID]")
    lines.append(f'@="{g}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}]")
    lines.append(f'@="{full}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}\\InprocServer32]")
    lines.append(f'@="{INPROC_SERVER}"')
    lines.append(f'"ThreadingModel"="Both"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}\\ProgId]")
    lines.append(f'@="{pid}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}\\CodeBase]")
    # .reg files escape backslashes as \\
    lines.append(f'@="file:///{DLL_WINPATH.replace(chr(92), chr(92) * 2)}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}\\Assembly]")
    lines.append(f'@="QlmLicenseLib, Version={ver}, Culture=neutral, PublicKeyToken={token}"')
    lines.append("")
    lines.append(f"[HKEY_LOCAL_MACHINE\\Software\\Classes\\CLSID\\{g}\\RuntimeVersion]")
    lines.append(f'@="{RUNTIME_VERSION}"')
    lines.append("")

with open(OUT, "w") as f:
    f.write("\n".join(lines))
print(f"{len(progids)} ProgIDs registered; token={token} ver={ver}")
