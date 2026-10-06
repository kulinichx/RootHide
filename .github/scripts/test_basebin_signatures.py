#!/usr/bin/env python3
"""Regression tests for the packaged BaseBin signature gate."""

import hashlib
import io
import struct
import tarfile
import unittest

from check_basebin_signatures import REQUIRED, check_basebin, check_image


def image(flags=2):
    # One signed code page, followed by an embedded SHA-256 CodeDirectory.
    signature_size = 12 + 8 + 44 + 32
    data = bytearray(256)
    struct.pack_into('<8I', data, 0, 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0x200085, 0)
    struct.pack_into('<4I', data, 32, 0x1D, 16, 256, signature_size)
    directory = struct.pack('>9I', 0xFADE0C02, 76, 0x20200, flags, 44, 0, 0, 1, 256)
    directory += struct.pack('4BI', 32, 2, 0, 12, 0)
    directory += hashlib.sha256(data).digest()
    return bytes(data) + struct.pack('>5I', 0xFADE0CC0, signature_size, 1, 0, 20) + directory


def fat(first, second):
    table_size = 48
    return (struct.pack('>II', 0xCAFEBABE, 2)
            + struct.pack('>5I', 0x100000C, 0, table_size, len(first), 0)
            + struct.pack('>5I', 0x100000C, 0x80000002, table_size + len(first), len(second), 0)
            + first + second)


class SignatureTests(unittest.TestCase):
    def test_valid_adhoc(self):
        check_image(image())

    def test_missing_adhoc_rejected(self):
        with self.assertRaisesRegex(ValueError, 'CS_ADHOC'):
            check_image(image(flags=0))

    def test_all_fat_slices_checked(self):
        check_image(fat(image(), image()))
        for data in (fat(image(0), image()), fat(image(), image(0))):
            with self.assertRaisesRegex(ValueError, 'CS_ADHOC'):
                check_image(data)

    def test_modified_code_rejected(self):
        data = bytearray(image())
        data[100] ^= 1
        with self.assertRaisesRegex(ValueError, 'page hash mismatch'):
            check_image(data)

    def test_truncated_signature_rejected(self):
        with self.assertRaises(ValueError):
            check_image(image()[:-1])

    def test_bad_load_command_rejected(self):
        data = bytearray(image())
        struct.pack_into('<I', data, 36, 0)
        with self.assertRaisesRegex(ValueError, 'load command'):
            check_image(data)

    def test_archive_checks_required_files(self):
        for names in (REQUIRED, REQUIRED - {'basebin/jbctl'}):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w') as archive:
                for name in names:
                    member = tarfile.TarInfo(name)
                    member.size = len(image())
                    archive.addfile(member, io.BytesIO(image()))
            if names == REQUIRED:
                check_basebin(buffer.getvalue())
            else:
                with self.assertRaisesRegex(ValueError, 'missing required image'):
                    check_basebin(buffer.getvalue())


if __name__ == '__main__':
    unittest.main()
