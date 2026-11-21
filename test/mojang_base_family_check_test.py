"""DB/network-free Task 3A fixtures; no store mutation or ELF execution."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from mojang_base_family_check import Rejected, check_symbols, check_graph_symbols


class SymbolTests(unittest.TestCase):
    def test_other_executable_cannot_supply_a_missing_strong_import(self):
        objects = {
            Path("backend"): {"path": "backend", "soname": None, "symbols": set(),
                              "undefined": [("only_in_test", False, None)], "version_providers": {}},
            Path("test"): {"path": "test", "soname": None, "symbols": {"only_in_test"},
                           "undefined": [], "version_providers": {}},
        }
        with self.assertRaisesRegex(Rejected, "unresolved symbol.*only_in_test"):
            check_graph_symbols(objects, {"backend"})
        objects[Path("backend")]["symbols"].add("only_in_test")
        check_graph_symbols(objects, {"backend"})

    def test_named_version_provider_must_export_symbol(self):
        consumer = {"path": "curl", "undefined": [("SSL_connect@OPENSSL_3.0.0", False, 2)],
                    "version_providers": {2: ("libssl.so.3", "OPENSSL_3.0.0")}}
        providers = {"libssl.so.3": {"symbols": set()},
                     "libcrypto.so.3": {"symbols": {"SSL_connect@OPENSSL_3.0.0"}}}
        with self.assertRaisesRegex(Rejected, "libssl.so.3.*SSL_connect"):
            check_symbols(consumer, providers, {"SSL_connect@OPENSSL_3.0.0"})
        providers["libssl.so.3"]["symbols"].add("SSL_connect@OPENSSL_3.0.0")
        check_symbols(consumer, providers, {"SSL_connect@OPENSSL_3.0.0"})

    def test_unresolved_strong_symbol(self):
        consumer = {"path": "curl", "undefined": [("missing", False, None)], "version_providers": {}}
        with self.assertRaisesRegex(Rejected, "unresolved symbol.*missing"):
            check_symbols(consumer, {}, set())

    def test_unresolved_weak_symbol_is_optional(self):
        check_symbols({"path": "curl", "undefined": [("optional", True, None)],
                       "version_providers": {}}, {}, set())


class BaseFamilyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = json.loads(Path(os.environ["MOJANG_INVENTORY"]).read_text())
        cls.checker = Path(__file__).with_name("mojang_base_family_check.py")

    def run_check(self, inventory, message=None):
        self.assertTrue(self.checker.is_file(), "base-family checker not implemented")
        result = subprocess.run(
            [sys.executable, str(self.checker), "--inventory-stdin", "--require-realized"],
            input=json.dumps(inventory), text=True, capture_output=True,
            env={"LC_ALL": "C"},
        )
        if message is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("GREEN", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(message, result.stderr)

    def test_real_private_artifacts(self):
        self.run_check(self.inventory)

    def test_missing_artifact(self):
        inv = copy.deepcopy(self.inventory)
        with tempfile.TemporaryDirectory() as tmp:
            inv["artifacts"].append(tmp + "/missing-libcurl")
            self.run_check(inv, "unrealized artifact")

    def test_wrong_ssl_identity(self):
        inv = copy.deepcopy(self.inventory)
        inv["base"]["openssl"]["outputs"]["out"] = inv["transport"]["ares"]["outputs"]["out"]
        self.run_check(inv, "provider identity")

    def test_duplicate_ssl_provider(self):
        inv = copy.deepcopy(self.inventory)
        ssl = Path(inv["base"]["openssl"]["outputs"]["out"]) / "lib/libssl.so.3"
        with tempfile.TemporaryDirectory() as tmp:
            duplicate = Path(tmp) / "libssl.so.3"
            shutil.copyfile(ssl, duplicate)
            inv["artifacts"].append(str(duplicate))
            self.run_check(inv, "duplicate provider libssl.so.3")

    def test_extra_declared_runtime_input(self):
        inv = copy.deepcopy(self.inventory)
        inv["transport"]["curl"]["propagatedBuildInputs"].append("/nix/store/forbidden-librtmp")
        self.run_check(inv, "declared inputs curl")

    def test_wrong_stdenv(self):
        inv = copy.deepcopy(self.inventory)
        inv["transport"]["ares"]["stdenvDrv"] = "/nix/store/selected-stdenv.drv"
        self.run_check(inv, "stdenv ares")

    def test_wrong_interpreter(self):
        inv = copy.deepcopy(self.inventory)
        inv["expectedInterpreter"] = inv["base"]["openssl"]["outputs"]["out"] + "/wrong-loader"
        self.run_check(inv, "interpreter identity")

    def test_invalid_inventory(self):
        self.run_check({}, "invalid inventory")

    def test_cannot_omit_private_artifacts(self):
        inv = copy.deepcopy(self.inventory)
        inv["artifacts"] = []
        self.run_check(inv, "missing private artifacts")

    def test_cannot_omit_package_artifacts(self):
        inv = copy.deepcopy(self.inventory)
        inv.pop("packages", None)
        self.run_check(inv, "missing package artifacts")


if __name__ == "__main__":
    unittest.main()
