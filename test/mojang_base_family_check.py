"""Read-only Task 3A/3B ELF admission. Never invokes a loader, ldd, or Nix.

Expectations are evaluated Nix bindings; searches never consult the host,
environment, ld.so.cache or default library directories.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


class Rejected(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def check_symbols(obj, providers, exports):
    for symbol, weak, index in obj["undefined"]:
        if weak:
            continue
        if "@" in symbol:
            require(index in obj["version_providers"],
                    f"unparsed symbol version {obj['path']}: {symbol}")
            name, version = obj["version_providers"][index]
            require(symbol.endswith("@" + version) and name in providers,
                    f"symbol provider mismatch {obj['path']}: {symbol}")
            require(symbol in providers[name]["symbols"],
                    f"symbol provider {obj['path']}: {name}: {symbol}")
        else:
            require(symbol in exports, f"unresolved symbol {obj['path']}: {symbol}")


def check_graph_symbols(objects, paths):
    scope = [objects[Path(path)] for path in paths]
    exports = set().union(*(obj["symbols"] for obj in scope))
    providers = {obj["soname"]: obj for obj in scope if obj["soname"]}
    for path in paths:
        check_symbols(objects[Path(path)], providers, exports)


def check(inv):
    require(isinstance(inv, dict), "invalid inventory object")
    require(inv.get("schemaVersion") == 1, "invalid inventory schema")
    base, transport = inv["base"], inv["transport"]
    out = lambda record: record["outputs"]["out"]
    libc = out(base["glibc"])
    interpreter = libc + "/lib/ld-linux-x86-64.so.2"
    require(inv["expectedInterpreter"] == interpreter, "interpreter identity mismatch")
    for name, package in transport.items():
        require(package["stdenvDrv"] == base["stdenv"]["drvPath"], f"stdenv {name} mismatch")
        require(package["libcPath"] == libc, f"libc {name} identity mismatch")
        expected = inv["declaredInputs"][name]
        for field in ("buildInputs", "propagatedBuildInputs"):
            require(package[field] == expected[field], f"declared inputs {name}: {field}: {package[field]}")
    require(transport["curl"]["opensslPath"] == base["openssl"]["outputPath"], "OpenSSL binding mismatch")
    require(transport["curl"]["zlibPath"] == out(base["zlib"]), "zlib binding mismatch")
    readelf = inv["tools"]["readelf"]
    require(readelf == base["binutils"]["outputPath"] + "/bin/readelf", "readelf identity mismatch")
    require(Path(readelf).is_file(), f"unrealized tool {readelf}")

    def read(path, *flags):
        result = subprocess.run([readelf, *flags, str(path)], text=True,
                                capture_output=True, env={"LC_ALL": "C"})
        require(result.returncode == 0, f"readelf failed {path}: {result.stderr}")
        return result.stdout

    objects = {}

    def inspect(path):
        path = Path(path).resolve(strict=True)
        if path in objects:
            return objects[path]
        require(path.read_bytes()[:4] == b"\x7fELF", f"not ELF {path}")
        dynamic = read(path, "-dW")
        headers = read(path, "-hW", "-lW")
        require("ELF64" in headers and "Advanced Micro Devices X86-64" in headers,
                f"unsupported ELF {path}")
        sonames = re.findall(r"\(SONAME\).*?\[(.*?)\]", dynamic)
        require(len(sonames) <= 1, f"ambiguous SONAME {path}")
        paths = re.findall(r"\((?:RPATH|RUNPATH)\).*?\[(.*?)\]", dynamic)
        require(len(paths) <= 1, f"ambiguous RPATH/RUNPATH {path}")
        # fail closed on unsupported inherited/relative/ambient search semantics.
        search = paths[0].split(":") if paths else []
        for directory in search:
            require(directory in allowed_dirs, f"provider identity / RPATH {path}: {directory}")
        interp = re.findall(r"Requesting program interpreter: (.*?)\]", headers)
        require(not interp or interp == [interpreter], f"interpreter identity {path}: {interp}")
        symbols, undefined = set(), []
        for line in read(path, "--dyn-syms", "--wide").splitlines():
            fields = line.split()
            if len(fields) < 8 or not re.fullmatch(r"\d+:", fields[0]):
                continue
            symbol = fields[7]
            if fields[6] == "UND":
                index = re.fullmatch(r"\((\d+)\)", fields[8]) if len(fields) > 8 else None
                undefined.append((symbol, fields[4] == "WEAK", int(index[1]) if index else None))
            elif fields[4] in ("GLOBAL", "WEAK", "UNIQUE") and fields[5] in ("DEFAULT", "PROTECTED"):
                symbols.add(symbol.replace("@@", "@"))
                if "@@" in symbol:
                    symbols.add(symbol.split("@@")[0])
        versions = read(path, "--version-info", "--wide")
        definitions = set()
        needs = {}
        version_providers = {}
        mode, provider = None, None
        for line in versions.splitlines():
            if line.startswith("Version definition section"):
                mode = "definitions"
            elif line.startswith("Version needs section"):
                mode = "needs"
            match = re.search(r"File: (\S+)", line)
            if mode == "needs" and match:
                provider = match[1]
            match = re.search(r"Name: (\S+)", line)
            if match:
                if mode == "definitions":
                    definitions.add(match[1])
                elif mode == "needs":
                    require(provider is not None, f"unparsed version provider {path}")
                    needs.setdefault(provider, set()).add(match[1])
                    index = re.search(r"Version: (\d+)", line)
                    require(index is not None, f"unparsed version index {path}: {line}")
                    version_providers[int(index[1])] = (provider, match[1])
        obj = dict(path=str(path), soname=sonames[0] if sonames else None,
                   needed=re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic),
                   search=search, interpreter=interp, symbols=symbols,
                    undefined=undefined, definitions=definitions, needs=needs,
                    version_providers=version_providers,
                   sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        objects[path] = obj
        return obj

    roots = [out(base[name]) for name in ("glibc", "openssl", "zlib")]
    roots += [out(transport[name]) for name in ("curl", "ares")]
    roots += [base[name]["outputs"]["lib"] for name in ("postgresql", "krb5", "keyutils")]
    allowed_dirs = {root + "/lib" for root in roots}
    # exact SONAME -> canonical provider identities, independent of encountered DSOs.
    providers = {}
    for root in roots:
        directory = Path(root) / "lib"
        require(directory.is_dir(), f"unrealized provider identity {directory}")
        for path in sorted(directory.glob("*.so*")):
            if path.is_file() and path.read_bytes()[:4] == b"\x7fELF":
                # provider catalog includes libc compatibility DSOs, not arbitrary runtime additions.
                obj = inspect(path)
                if obj["soname"]:
                    providers.setdefault(obj["soname"], set()).add(Path(obj["path"]))
    expected = {name: paths for name, paths in providers.items()}
    for name in ("libc.so.6", "libssl.so.3", "libcrypto.so.3", "libz.so.1", "libcurl.so.4", "libcares.so.2"):
        require(name in expected, f"provider identity missing {name}")
    require(all(out(transport[name]) + "/lib" in inv["artifacts"] for name in ("curl", "ares")),
            "missing private artifacts")
    packages = inv.get("packages")
    require(isinstance(packages, dict) and set(packages) == {"default", "capability", "transport"},
            "missing package artifacts")
    package_paths = {Path(p).resolve() for p in packages.values()}
    require(len(package_paths) == 3, "duplicate package artifacts")
    ca = inv["metadata"]["ca_bundle"]
    require(ca == base["cacert"]["outputPath"] + "/etc/ssl/certs/ca-bundle.crt", "CA identity mismatch")
    require(Path(ca).is_file(), "unrealized base CA")
    starts = []
    for artifact in inv["artifacts"] + list(packages.values()):
        path = Path(artifact)
        require(path.exists(), f"unrealized artifact {artifact}")
        candidates = sorted(path.glob("*.so*")) if path.is_dir() else [path]
        found = set()
        for candidate in candidates:
            if candidate.is_file() and candidate.read_bytes()[:4] == b"\x7fELF":
                obj = inspect(candidate)
                canonical = Path(obj["path"])
                if canonical in package_paths:
                    require(obj["interpreter"] == [interpreter], f"missing package interpreter {canonical}")
                    require(ca.encode() in canonical.read_bytes(), f"missing base CA reference {canonical}")
                found.add(canonical)
                if obj["soname"]:
                    providers.setdefault(obj["soname"], set()).add(canonical)
        require(found, f"no runtime ELF in artifact {artifact}")
        starts.extend(sorted(found))
    for name, paths in providers.items():
        require(len(paths) == 1, f"duplicate provider {name}: {sorted(map(str, paths))}")
    # the exact base interpreter is inspected as date
    queue = starts + [Path(interpreter).resolve(strict=True)]
    visited, edges = set(), []
    while queue:
        path = queue.pop(0)
        if path in visited:
            continue
        obj = inspect(path)
        if obj["soname"]:
            require(path in expected.get(obj["soname"], set()), f"provider identity {obj['soname']}: {path}")
        else:
            require(path in package_paths or any(path.is_relative_to(root) for root in map(Path, roots)), f"non-admitted ELF {path}")
        visited.add(path)
        for needed in obj["needed"]:
            require("/" not in needed, f"non-SONAME dependency {path}: {needed}")
            candidates = { (Path(directory) / needed).resolve(strict=True)
                           for directory in obj["search"] if (Path(directory) / needed).is_file() }
            # libc and its interpreter are process-global, already loaded base identities.
            if not candidates and needed in ("libc.so.6", "ld-linux-x86-64.so.2"):
                candidates = expected.get(needed, set())
            require(len(candidates) == 1, f"unresolved/duplicate dependency {path}: {needed}: {candidates}")
            provider = next(iter(candidates))
            require(candidates == expected.get(needed), f"provider identity {path}: {needed}: {provider}")
            edges.append(dict(object=str(path), needed=needed, provider=str(provider)))
            queue.append(provider)

    # version req
    for path in visited:
        obj = objects[path]
        for name, versions in obj["needs"].items():
            require(name in obj["needed"], f"version provider not DT_NEEDED {path}: {name}")
            provider = next(iter(expected[name]))
            require(versions <= objects[provider]["definitions"],
                    f"symbol-version mismatch {path}: {name}: {sorted(versions - objects[provider]['definitions'])}")
    graphs = {}
    for name, artifact in packages.items():
        reached, pending = set(), [str(Path(artifact).resolve()), str(Path(interpreter).resolve())]
        while pending:
            path = pending.pop()
            if path in reached:
                continue
            reached.add(path)
            pending.extend(edge["provider"] for edge in edges if edge["object"] == path)
        for required in ("libcurl.so.4", "libcares.so.2", "libssl.so.3", "libcrypto.so.3", "libc.so.6"):
            require(str(next(iter(expected[required]))) in reached, f"missing package provider {name}: {required}")
        if name == "default":
            for required in ("libpq.so.5", "libgssapi_krb5.so.2", "libkeyutils.so.1"):
                require(str(next(iter(expected[required]))) in reached, f"missing package provider default: {required}")
        check_graph_symbols(objects, reached)
        graphs[name] = sorted(reached)
    return {"status": "GREEN", "packages": graphs, "metadata": inv["metadata"],
            "ca_sha256": hashlib.sha256(Path(ca).read_bytes()).hexdigest(), "edges": edges, "objects": [
        {k: objects[p][k] for k in ("path", "soname", "needed", "search", "interpreter", "sha256")}
        for p in sorted(visited)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory-stdin", action="store_true", required=True)
    parser.add_argument("--require-realized", action="store_true", required=True)
    parser.parse_args()
    try:
        print(json.dumps(check(json.load(sys.stdin)), indent=2))
    except (Rejected, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: invalid inventory or admission failure: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
