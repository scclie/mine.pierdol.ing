"""Task 3C: direct fixed-filter exported ELF in the loopback-only Nix sandbox."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile

from mojang_base_family_check import require

MANDATORY = (
    "blackholed ordinary DNS cancels", "stalled connect cancels", "stalled TLS cancels",
    "unfinished headers cancel", "body trickle cannot reset deadline", "truncated body terminal",
    "oversized headers including interim and trailers", "oversized body including chunked",
    "compressed body rejected", "bad certificate and hostname terminal", "redirect never followed",
    "proxy environment ignored", "retry 5xx then success exactly two",
    "transient reset retry but DNS TLS timeout never retry", "long Retry-After returns without sleep",
    "cancel during backoff", "shutdown drains active ownership", "allocation and option failures clean up",
    "admission rolling budget cooldown and exact deadline scripts",
)


def check_trace(events):
    require(not re.search(r"htons\(3099\)", events), "forbidden port 3099")
    for family in re.findall(r"socket\((AF_[A-Z0-9_]+)", events):
        require(family in ("AF_INET", "AF_INET6"), "non-IP socket " + family)
    for address in re.findall(r'inet_addr\("([^"\n]+)"\)', events):
        require(address == "127.0.0.1", "non-loopback IPv4 " + address)
    for address in re.findall(r'inet_pton\(AF_INET6, "([^"\n]+)"', events):
        require(address == "::1", "non-loopback IPv6 " + address)
    require('sa_family=AF_UNIX' not in events, "Unix service access")
    require('.cnf"' not in events, "ambient OpenSSL configuration")
    require('/forbidden/' not in events, "ambient configuration access")
    require(not re.search(r'"(?:/run/|/var/|[^"\n]*\.env(?:"|/))', events), "operational file access")


def validate(text, inv, graph):
    require("SKIP" not in text and "FAIL" not in text and "tests passed." in text, "failed/skipped/missing suite")
    for name in MANDATORY:
        require(f".test.mojang transport {name}..." in text, "missing mandatory case " + name)
    metadata = re.findall(r"^MOJANG_METADATA (.+)$", text, re.M)
    require(len(metadata) == 1, "missing Client metadata")
    require(json.loads(metadata[0]) == dict(inv['metadata'], ca_sha256=graph['ca_sha256']), "metadata/CA mismatch")
    loaded = {str(Path(p).resolve(strict=True)) for p in re.findall(r"^MOJANG_LOADED (.+)$", text, re.M)}
    require(loaded == set(graph['packages']['transport']), "loaded provider graph mismatch")
    measurements = [json.loads(x) for x in re.findall(r"^MOJANG_CASE (.+)$", text, re.M)]
    measured = {x['name'] for x in measurements}
    for name in MANDATORY:
        require(name in measured, "missing measurement " + name)
    for case in measurements:
        require(0 <= case['elapsed_ns'] <= 5_250_000_000, "elapsed bound " + case['name'])
        require(case['scheduler_tolerance_ms'] == 250, "scheduler tolerance changed")
    return measurements


def check(inv, graph, directory):
    directory = Path(directory)
    directory.mkdir()
    executable = inv['packages']['transport']
    identities = {k: {'path': p, 'sha256': hashlib.sha256(Path(p).read_bytes()).hexdigest()}
                  for k, p in inv['packages'].items()}
    require(all(graph['objects'][os.path.realpath(p)]['sha256'] == identities[k]['sha256']
                for k, p in inv['packages'].items()), 'artifact hash mismatch before execution')
    with tempfile.TemporaryDirectory(prefix='task-3c-fixtures-', dir=directory) as fixtures:
        env = {'LC_ALL': 'C', 'TMPDIR': fixtures, 'HOME': fixtures}
        trace = directory / 'local.trace'
        # No loader/LD_* environment or filter arguments; this is a test harness,
        # not a backend launch path. Nix's network namespace supplies isolation.
        proc = subprocess.Popen([inv['tools']['strace'], '-f', '-qq', '-s', '4096', '-e',
                                 'trace=network,openat', '-o', str(trace), executable],
                                env=env, cwd=fixtures, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise
        text = stdout + stderr
        (directory / 'local.log').write_text(text)
        require(proc.returncode == 0, 'local fixture suite failed: ' + text)
        measurements = validate(text, inv, graph)
        check_trace(trace.read_text())
        require(not list(Path(fixtures).iterdir()), 'fixture material remains')
    for case in measurements:
        case.update(artifacts=identities, metadata=inv['metadata'], ca_sha256=graph['ca_sha256'],
                    providers=graph['packages'])
    result = dict(status='GREEN', mandatory=list(MANDATORY), measurements=measurements,
                  graph=graph, artifacts=identities,
                  trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest())
    (directory / 'adversarial.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('inventory', 'graph', 'output'):
        parser.add_argument('--' + arg, required=True)
    args = parser.parse_args()
    check(json.loads(Path(args.inventory).read_text()), json.loads(Path(args.graph).read_text()), args.output)


if __name__ == '__main__':
    main()
