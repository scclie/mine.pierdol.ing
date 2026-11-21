"""Socket-free acceptance harness regression tests; no backend or provider I/O."""
import subprocess
import sys
import unittest

from mojang_base_family_check import Rejected
from mojang_capability_check import check_trace, forbid_sockets


class CapabilityTests(unittest.TestCase):
    def test_kernel_denies_socket_creation(self):
        result = subprocess.run([sys.executable, "-c", """
import errno, socket
try:
    socket.socket()
except OSError as error:
    assert error.errno == errno.EPERM
else:
    raise AssertionError('socket creation was allowed')
"""], env={"LC_ALL": "C"}, preexec_fn=forbid_sockets,
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_only_denied_socket_capability_probes_are_accepted(self):
        check_trace('1 socket(AF_INET6, SOCK_DGRAM, 0) = -1 EPERM (Operation not permitted)')
        for event in ('socket(AF_INET, SOCK_STREAM, 0) = 3',
                      'connect(3, {}, 16) = -1 EPERM',
                      'sendmsg(3, {}, 0) = 1',
                      'getsockopt(3, SOL_SOCKET, SO_ERROR, [0], [4]) = 0'):
            with self.subTest(event=event), self.assertRaises(Rejected):
                check_trace(event)

    def test_ambient_configuration_is_rejected(self):
        for path in ('/forbidden/ambient-ca', '/nix/store/base/etc/ssl/openssl.cnf'):
            with self.subTest(path=path), self.assertRaises(Rejected):
                check_trace(f'openat(AT_FDCWD, "{path}", O_RDONLY) = 3')


if __name__ == "__main__":
    unittest.main()
