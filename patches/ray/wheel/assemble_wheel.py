"""Build the patched Ray wheel from the stock PyPI wheel.

Downloads the stock wheel for the Python tag and architecture, checks it against the sha256 PyPI publishes, replaces the
raylet and gcs_server binaries and the Python files the patches touch, sets the local version, regenerates RECORD, and
writes the wheel and a sha256 file next to it.
"""

import argparse
import base64
import hashlib
import json
import pathlib
import re
import urllib.request
import zipfile


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def record_hash(data):
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def download_stock_wheel(upstream, python_tag, arch, directory):
    """Fetch the stock wheel and verify it against the digest PyPI publishes for it."""
    filename = f"ray-{upstream}-{python_tag}-{python_tag}-manylinux2014_{arch}.whl"
    with urllib.request.urlopen(f"https://pypi.org/pypi/ray/{upstream}/json") as response:
        files = {f["filename"]: f for f in json.load(response)["urls"]}
    published = files[filename]
    path = directory / filename
    if not path.exists() or sha256_hex(path.read_bytes()) != published["digests"]["sha256"]:
        urllib.request.urlretrieve(published["url"], path)
    actual = sha256_hex(path.read_bytes())
    if actual != published["digests"]["sha256"]:
        raise SystemExit(f"{filename}: sha256 {actual} does not match PyPI's {published['digests']['sha256']}")
    return path


def patched_python_files(patches):
    """The python/ray files the patches touch, as paths relative to python/."""
    names = set()
    for patch in patches:
        for line in pathlib.Path(patch).read_text().splitlines():
            match = re.match(r"\+\+\+ b/(python/ray/.+)$", line)
            if match:
                names.add(match.group(1)[len("python/"):])
    return sorted(names)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--local-version", required=True)
    parser.add_argument("--python-tag", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--binaries", type=pathlib.Path, required=True)
    parser.add_argument("--patches", nargs="+", required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()

    cache = args.out / ".stock"
    cache.mkdir(parents=True, exist_ok=True)
    stock = download_stock_wheel(args.upstream, args.python_tag, args.arch, cache)

    replacements = {
        "ray/core/src/ray/gcs/gcs_server": (args.binaries / "gcs_server").read_bytes(),
        "ray/core/src/ray/raylet/raylet": (args.binaries / "raylet").read_bytes(),
    }
    for name in patched_python_files(args.patches):
        replacements[name] = (args.source / "python" / name).read_bytes()

    old_dist_info = f"ray-{args.upstream}.dist-info"
    new_dist_info = f"ray-{args.local_version}.dist-info"
    target = args.out / stock.name.replace(f"ray-{args.upstream}-", f"ray-{args.local_version}-", 1)

    with zipfile.ZipFile(stock) as source, zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as wheel:
        names = {info.filename for info in source.infolist()}
        for stock_only in ("ray/core/src/ray/gcs/gcs_server", "ray/core/src/ray/raylet/raylet"):
            if stock_only not in names:
                raise SystemExit(f"stock wheel has no {stock_only}")
        record = []
        written = set()

        def add(info, data):
            wheel.writestr(info, data)
            written.add(info.filename)
            record.append(f"{info.filename},{record_hash(data)},{len(data)}")

        for info in source.infolist():
            name = info.filename
            if name.endswith("/") or name == f"{old_dist_info}/RECORD":
                continue
            data = source.read(name)
            if name in replacements:
                data = replacements[name]
            elif name == "ray/_version.py":
                data = re.sub(
                    rb'^version = "[^"]*"$', f'version = "{args.local_version}"'.encode(), data, flags=re.M
                )
            elif name == f"{old_dist_info}/METADATA":
                data = re.sub(rb"^Version: .*$", f"Version: {args.local_version}".encode(), data, count=1, flags=re.M)
            if name.startswith(old_dist_info + "/"):
                info.filename = new_dist_info + name[len(old_dist_info):]
            add(info, data)
        # Patched files the stock wheel does not have, such as files the patches add.
        for name in sorted(set(replacements) - names):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            add(info, replacements[name])
        record_name = f"{new_dist_info}/RECORD"
        info = zipfile.ZipInfo(record_name, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        wheel.writestr(info, "\n".join(record + [f"{record_name},,", ""]))

    checksum = sha256_hex(target.read_bytes())
    pathlib.Path(str(target) + ".sha256").write_text(f"{checksum}  {target.name}\n")
    print(f"{target}\nsha256 {checksum}")


if __name__ == "__main__":
    main()
