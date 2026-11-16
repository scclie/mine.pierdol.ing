"""Opt-in real PostgreSQL evidence. No URL discovery, installation, or Docker pull."""

import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-bin", required=True)
    parser.add_argument("artifact")
    args = parser.parse_args()
    binaries = Path(args.postgres_bin)
    required = ("postgres", "initdb", "pg_ctl", "psql")
    if not args.postgres_bin or any(not os.access(binaries / x, os.X_OK) for x in required):
        raise SystemExit("BLOCKED: supply --postgres-bin with already-provisioned PostgreSQL binaries; nothing fetched")
    if os.geteuid() == 0:
        raise SystemExit("BLOCKED: disposable PostgreSQL must run as an unprivileged user")

    root = Path(tempfile.mkdtemp(prefix="mine-game-auth-", dir="/tmp/opencode"))
    data = root / "data"
    sockets = root / "socket"
    sockets.mkdir(mode=0o700)
    password = "synthetic-local-only-" + uuid.uuid4().hex
    password_file = root / "password"
    password_file.write_text(password + "\n")
    password_file.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    # linux ephemeral ports are unprivileged; fail rather than ever using 3099.
    if port <= 1024 or port == 3099:
        shutil.rmtree(root)
        raise SystemExit("Unsafe ephemeral port")
    env = {"PATH": os.defpath, "HOME": str(root), "LC_ALL": "C"}
    started = False
    print(f"RESOURCE cluster={root} user={os.geteuid()} bind=127.0.0.1:{port} socket={sockets}", flush=True)

    def run(binary, *arguments, **kwargs):
        return subprocess.run([str(binaries / binary), *map(str, arguments)], env=env, check=True, timeout=60, **kwargs)

    try:
        run("initdb", "-D", data, "-U", "game_auth_evidence", "--auth-host=scram-sha-256", "--auth-local=trust", "--pwfile", password_file, "--no-locale", "--encoding=UTF8")
        run("pg_ctl", "-D", data, "-l", root / "postgres.log", "-w", "start", "-o", f"-h 127.0.0.1 -p {port} -k {sockets} -c max_connections=12 -c statement_timeout=15000 -c lock_timeout=10000 -c log_connections=on -c log_disconnections=on")
        started = True
        print(f"RESOURCE postmaster_pid={(data / 'postmaster.pid').read_text().splitlines()[0]} role=game_auth_evidence", flush=True)
        url = f"postgresql://game_auth_evidence:{password}@127.0.0.1:{port}/postgres?connect_timeout=5"
        test_env = dict(env, TEST_DATABASE_URL=url)

        result = subprocess.run([args.artifact], env=test_env, timeout=240)
        remaining = run("psql", "-h", sockets, "-p", port, "-U", "game_auth_evidence", "-d", "postgres", "-Atc", "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname", capture_output=True, text=True).stdout.strip()
        print(f"RESOURCE remaining_test_databases={remaining or 'none'}", flush=True)
        if remaining:
            raise RuntimeError("Fixture database cleanup failed")
        if result.returncode:
            raise SystemExit(result.returncode)
    finally:
        if started or (data / "postmaster.pid").exists():
            run("pg_ctl", "-D", data, "-m", "immediate", "-w", "stop")
        if (data / "postmaster.pid").exists():
            raise RuntimeError(f"Cluster still running: {root}")
        if started:
            status = subprocess.run([str(binaries / "pg_ctl"), "-D", str(data), "status"], env=env, timeout=10)
            if status.returncode != 3:
                raise RuntimeError(f"Stopped-cluster verification failed: {root}")
            print("RESOURCE pg_ctl_status=3 (no server running)", flush=True)

        log = root / "postgres.log"
        if log.exists():
            for line in log.read_text().splitlines():
                if any(marker in line for marker in ("ERROR:", "DETAIL:", "connection received:", "connection authorized:", "disconnection:")):
                    print("POSTGRES " + line, flush=True)
        print(f"RESOURCE stopped cluster={root}", flush=True)
        shutil.rmtree(root)
        print(f"RESOURCE removed cluster={root} exists={root.exists()}", flush=True)


if __name__ == "__main__":
    main()
