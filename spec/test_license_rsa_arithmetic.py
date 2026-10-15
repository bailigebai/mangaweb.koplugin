"""Independent integer oracle for the security-sensitive RSA arithmetic."""

import base64
from pathlib import Path
import random
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


class RsaArithmeticTests(unittest.TestCase):
    def test_bounded_montgomery_arithmetic_matches_python_integers(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path = ... .. '/?.lua;' .. package.path", ROOT.as_posix())
        # Inspect the internal arithmetic without adding test-only product APIs.
        multiply, parameters = lua.execute("""
            local verify = require('mangaweb.license_rsa_portable').verify
            local function upvalue(name)
                for i = 1, 30 do
                    local key, value = debug.getupvalue(verify, i)
                    if key == name then return value end
                end
                error('missing arithmetic helper ' .. name)
            end
            return upvalue('multiply'), upvalue('parameters')
        """)

        radix = 1 << 2048
        random_source = random.Random(20261015)
        moduli = [radix - 1, (1 << 2047) + 1, radix - 159]
        moduli += [(1 << 2047) | random_source.getrandbits(2047) | 1 for _ in range(9)]
        prefix = bytes.fromhex('30820122300d06092a864886f70d01010105000382010f003082010a0282010100')
        suffix = bytes.fromhex('0203010001')

        def as_limbs(value):
            return lua.table_from([(value >> (16 * index)) & 65535 for index in range(128)])

        def as_integer(value):
            return sum(int(value[index + 1]) << (16 * index) for index in range(128))

        for modulus in moduli:
            pem = '-----BEGIN PUBLIC KEY-----\n' + base64.b64encode(
                prefix + modulus.to_bytes(256, 'big') + suffix
            ).decode('ascii') + '\n-----END PUBLIC KEY-----\n'
            key = parameters(pem)
            self.assertEqual(as_integer(key['r2']), pow(radix, 2, modulus))
            self.assertEqual(int(key['inverse']), -pow(modulus, -1, 65536) % 65536)
            pairs = [(0, 0), (1, 1), (modulus - 1, modulus - 1),
                     (modulus - 1, 1), (modulus // 2, modulus - 1)]
            pairs += [(random_source.randrange(modulus), random_source.randrange(modulus)) for _ in range(7)]
            for left, right in pairs:
                with self.subTest(modulus_bits=modulus.bit_length(), left=left, right=right):
                    result = multiply(as_limbs(left), as_limbs(right), key['modulus'], key['inverse'])
                    expected = left * right * pow(radix, -1, modulus) % modulus
                    self.assertEqual(as_integer(result), expected)
                    self.assertEqual(int(result[129]), 0)


if __name__ == '__main__':
    unittest.main()
