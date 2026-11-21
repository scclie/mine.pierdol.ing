import unittest
from mojang_adversarial_check import check_trace, validate
from mojang_base_family_check import Rejected


class Acceptance(unittest.TestCase):
    def test_external_and_forbidden_port_rejected(self):
        for event in (
            'connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("1.2.3.4")}, 16) = 0',
            'bind(3, {sa_family=AF_INET, sin_port=htons(3099), sin_addr=inet_addr("127.0.0.1")}, 16) = 0',
            'socket(AF_PACKET, SOCK_RAW, 0) = 3',
        ):
            with self.assertRaises(Rejected):
                check_trace(event)

    def test_loopback_ephemeral_accepted(self):
        check_trace('socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0) = 3\n'
                    'connect(3, {sa_family=AF_INET, sin_port=htons(49152), sin_addr=inet_addr("127.0.0.1")}, 16) = -1 EINPROGRESS')

    def test_success_exit_without_cases_not_accepted(self):
        with self.assertRaises(Rejected):
            validate('All 7 tests passed.\n', {}, {})


if __name__ == '__main__':
    unittest.main()
