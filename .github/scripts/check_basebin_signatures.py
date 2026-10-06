#!/usr/bin/env python3
"""Check packaged Mach-O ad-hoc flags and page hashes without executing them.

This verifies file contents, not device trust-cache state or iOS compatibility.
"""

import argparse
import hashlib
import io
from pathlib import Path
import struct
import tarfile
import zipfile


MACHO_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
REQUIRED = {'basebin/jbctl', 'basebin/libjailbreak.dylib', 'basebin/libchoma.dylib'}


def region(data, offset, size):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise ValueError('truncated or out-of-range Mach-O data')
    return data[offset:offset + size]


def unpack(fmt, data, offset):
    return struct.unpack(fmt, region(data, offset, struct.calcsize(fmt)))


def check_signature(image, signature):
    magic, length, count = unpack('>III', signature, 0)
    if magic != 0xFADE0CC0 or length > len(signature) or count > (length - 12) // 8:
        raise ValueError('invalid signature superblob')
    signature = region(signature, 0, length)
    directories = 0
    for index in range(count):
        slot, offset = unpack('>II', signature, 12 + index * 8)
        blob_magic, blob_length = unpack('>II', signature, offset)
        blob = region(signature, offset, blob_length)
        if slot == 0x10000 and blob_length > 8:
            raise ValueError('unexpected CMS signature in ad-hoc BaseBin image')
        if slot != 0 and not 0x1000 <= slot < 0x1005:
            continue
        if blob_magic != 0xFADE0C02 or blob_length < 44:
            raise ValueError('invalid CodeDirectory')
        _, _, version, flags, hash_offset, _, _, slots, limit = unpack('>9I', blob, 0)
        if not flags & 0x2:
            raise ValueError(f'CodeDirectory is missing CS_ADHOC (flags=0x{flags:x})')
        hash_size, hash_type, _, page_exp = unpack('4B', blob, 36)
        hashers = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}
        expected_sizes = {1: 20, 2: 32, 3: 20, 4: 48}
        if hash_type not in hashers or hash_size != expected_sizes[hash_type] or page_exp > 20:
            raise ValueError('unsupported CodeDirectory hashing parameters')
        if version >= 0x20300 and limit == 0:
            limit = unpack('>Q', blob, 56)[0]
        region(image, 0, limit)
        page_size = (1 << page_exp) if page_exp else max(limit, 1)
        if slots != (limit + page_size - 1) // page_size:
            raise ValueError('invalid code page count')
        region(blob, hash_offset, slots * hash_size)
        for page in range(slots):
            start = page * page_size
            digest = hashers[hash_type](image[start:min(start + page_size, limit)]).digest()[:hash_size]
            if digest != region(blob, hash_offset + page * hash_size, hash_size):
                raise ValueError(f'code page hash mismatch at page {page}')
        directories += 1
    if not directories:
        raise ValueError('signature contains no CodeDirectory')


def check_image(data):
    magic_bytes = bytes(data[:4])
    if magic_bytes in {b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}:
        count = unpack('>I', data, 4)[0]
        fat64 = magic_bytes == b'\xca\xfe\xba\xbf'
        fmt, size = ('>IIQQII', 32) if fat64 else ('>IIIII', 20)
        if not count or count > (len(data) - 8) // size:
            raise ValueError('invalid fat architecture table')
        for index in range(count):
            arch = unpack(fmt, data, 8 + index * size)
            image = region(data, arch[2], arch[3])
            if image[:4] != b'\xcf\xfa\xed\xfe':
                raise ValueError('unsupported or corrupt fat slice')
            check_image(image)
        return
    magic, _, _, _, commands, command_size, _, _ = unpack('<8I', data, 0)
    if magic != 0xFEEDFACF or commands > command_size // 8:
        raise ValueError('invalid Mach-O header')
    region(data, 32, command_size)
    position, signatures = 32, 0
    for _ in range(commands):
        command, size = unpack('<II', data, position)
        if size < 8 or size > 32 + command_size - position:
            raise ValueError('invalid load command size')
        if command == 0x1D:
            if size != 16:
                raise ValueError('invalid LC_CODE_SIGNATURE')
            offset, length = unpack('<II', data, position + 8)
            check_signature(data, region(data, offset, length))
            signatures += 1
        position += size
    if signatures != 1 or position != 32 + command_size:
        raise ValueError('missing or duplicate signature / invalid load commands')


def check_basebin(tar_data):
    seen, checked, errors = set(), 0, []
    with tarfile.open(fileobj=io.BytesIO(tar_data)) as archive:
        for member in archive:
            if not member.isfile():
                continue
            name = member.name.removeprefix('./')
            if name in seen:
                raise ValueError(f'duplicate archive member: {name}')
            seen.add(name)
            data = archive.extractfile(member).read()
            if data[:4] not in MACHO_MAGICS:
                if name in REQUIRED:
                    errors.append(f'{name}: not a supported Mach-O')
                continue
            try:
                check_image(data)
                checked += 1
            except ValueError as error:
                errors.append(f'{name}: {error}')
    errors.extend(f'missing required image: {name}' for name in sorted(REQUIRED - seen))
    if errors:
        raise ValueError('\n'.join(errors))
    print(f'PASS: {checked} BaseBin Mach-O images have CS_ADHOC and valid code page hashes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--tipa', type=Path)
    group.add_argument('--basebin-tar', type=Path)
    args = parser.parse_args()
    if args.tipa:
        with zipfile.ZipFile(args.tipa) as archive:
            data = archive.read('Payload/Dopamine.app/basebin.tar')
    else:
        data = args.basebin_tar.read_bytes()
    check_basebin(data)


if __name__ == '__main__':
    main()
