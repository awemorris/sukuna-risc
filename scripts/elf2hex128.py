#!/usr/bin/env python3
import sys

def convert(bin_path, hex_path, min_words=16):
    with open(bin_path, 'rb') as f:
        data = f.read()

    # Pad to 16-byte alignment
    pad_len = (16 - (len(data) % 16)) % 16
    data += b'\x00' * pad_len

    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        # Little endian 32-bit words
        w0 = int.from_bytes(chunk[0:4], 'little')
        w1 = int.from_bytes(chunk[4:8], 'little')
        w2 = int.from_bytes(chunk[8:12], 'little')
        w3 = int.from_bytes(chunk[12:16], 'little')
        # 128-bit word in hex: w3_w2_w1_w0
        lines.append(f"{w3:08x}{w2:08x}{w1:08x}{w0:08x}")

    while len(lines) < min_words:
        lines.append("00000013000000130000001300000013") # NOPs

    with open(hex_path, 'w') as f:
        for line in lines:
            f.write(line + '\n')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: elf2hex128.py <input.bin> <output.hex> [min_words]")
        sys.exit(1)
    min_w = int(sys.argv[3]) if len(sys.argv) > 3 else 64
    convert(sys.argv[1], sys.argv[2], min_w)
