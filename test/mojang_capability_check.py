"""Execute only the fixed-filter, socket-free exported Task 3B artifact.

No backend execution, loader invocation, environment discovery or provider I/O.
Must run in the Nix check sandbox; all child environments are constructed here.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import re
import subprocess

from mojang_base_family_check import require


def forbid_sockets():
    # disposable x86_64 Linux child only even local ipv6 capability probes cannot create sockets
    class Filter(ctypes.Structure):
        _fields_ = [("code", ctypes.c_ushort), ("jt", ctypes.c_ubyte),
                    ("jf", ctypes.c_ubyte), ("k", ctypes.c_uint)]
    class Program(ctypes.Structure):
        _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.POINTER(Filter))]
    code = [(0x20, 0, 0, 4), (0x15, 1, 0, 0xc000003e), (0x06, 0, 0, 0x80000000),
            (0x20, 0, 0, 0), (0x45, 0, 1, 0x40000000), (0x06, 0, 0, 0x80000000)]
    for syscall in (41, 42, 43, 44, 45, 46, 47, 49, 50, 53, 288, 299, 307):
        code += [(0x15, 0, 1, syscall), (0x06, 0, 0, 0x50001)]
    code += [(0x06, 0, 0, 0x7fff0000)]
    filters = (Filter * len(code))(*(Filter(*entry) for entry in code))
    program = Program(len(code), filters)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) != 0 or libc.prctl(22, 2, ctypes.byref(program), 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot forbid sockets")


def check_trace(events):
    for line in events.splitlines():
        if re.search(r"\b(?:socket|socketpair|connect|bind|listen|accept|accept4|sendto|recvfrom|sendmsg|recvmsg|sendmmsg|recvmmsg|getsockname|getpeername|getsockopt|setsockopt|shutdown)\(", line):
            require("socket(" in line and "= -1 EPERM" in line, f"network operation: {line}")
    require('.cnf"' not in events, "runtime OpenSSL configuration read")
    require("/forbidden/" not in events, "ambient configuration access")


def check(inv, graph, directory):
    executable = inv["packages"]["capability"]
    expected = set(graph["packages"]["capability"])
    results = []
    for case in ("clean", "poison-upper", "poison-lower", "poison-conflicting"):
        env = {"LC_ALL": "C"}
        if case != "clean":
            for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"):
                key = name.lower() if case == "poison-lower" else name
                env[key] = "http://127.0.0.1:1" if name != "NO_PROXY" else "never.invalid"
                if case == "poison-conflicting":
                    env[name.lower()] = "http://127.0.0.1:2" if name != "NO_PROXY" else "*"
            env.update(SSL_CERT_FILE="/forbidden/ambient-ca", SSL_CERT_DIR="/forbidden/ambient-ca-dir",
                       CURL_CA_BUNDLE="/forbidden/curl-ca", MOJANG_CA_BUNDLE="/forbidden/mojang-ca",
                       MOJANG_URL="https://forbidden.invalid/", HOME="/forbidden/home",
                       XDG_CONFIG_HOME="/forbidden/config", OPENSSL_CONF="/forbidden/openssl.cnf",
                       OPENSSL_MODULES="/forbidden/openssl-modules", OPENSSL_ENGINES="/forbidden/openssl-engines")
        trace = Path(directory) / (case + ".trace")
        p = subprocess.run([inv["tools"]["strace"], "-f", "-qq", "-s", "4096", "-e",
                            "trace=network,openat", "-o", str(trace), executable],
                           env=env, cwd=directory, text=True, capture_output=True, timeout=90,
                           preexec_fn=forbid_sockets)
        (Path(directory) / (case + ".log")).write_text(p.stdout + p.stderr)
        require(p.returncode == 0, f"capability failure {case}: {p.stderr}")
        text = p.stdout + p.stderr
        metadata = re.findall(r"^MOJANG_METADATA (.+)$", text, re.M)
        require(len(metadata) == 1, f"missing real Client metadata {case}")
        metadata = json.loads(metadata[0])
        require(metadata == dict(inv["metadata"], ca_sha256=graph["ca_sha256"]), "compiled metadata/CA mismatch")
        loaded = {str(Path(path).resolve(strict=True)) for path in re.findall(r"^MOJANG_LOADED (.+)$", text, re.M)}
        require(loaded == expected, f"loaded graph mismatch {case}: extra={loaded - expected}, missing={expected - loaded}")
        events = trace.read_text()
        check_trace(events)
        ca = inv["metadata"]["ca_bundle"]
        require('"' + ca + '"' in events, f"compiled CA not opened {case}")
        # No application configuration or operational DB/service files are used.
        require(not re.search(r'"(?:/run/|/var/|[^"\n]*\.env(?:"|/))', events), f"operational file access {case}")
        results.append(dict(case=case, metadata=metadata, loaded=sorted(loaded),
                            trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest()))
    return {"status": "GREEN", "runs": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--graph", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    directory = Path(args.output)
    directory.mkdir()
    result = check(json.loads(Path(args.inventory).read_text()), json.loads(Path(args.graph).read_text()), directory)
    (directory / "capabilities.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
