#!/usr/bin/env python3
import argparse
import base64
import re
from pathlib import Path


def xor_bytes(data: bytes, key: bytes) -> bytes:
    if not key:
        raise ValueError("key must not be empty")
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def decode_obf(obf_text: str, key: str) -> bytes:
    cleaned = re.sub(r"\s+", "", obf_text)
    raw = base64.b64decode(cleaned)
    return xor_bytes(raw, key.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify that jppm-etf-dev.obf decodes to the original CSV.",
    )
    parser.add_argument(
        "-i",
        "--input",
        default="jppm-etf-dev.csv",
        help="Input CSV path (default: jppm-etf-dev.csv)",
    )
    parser.add_argument(
        "-o",
        "--obf",
        default="jppm-etf-dev.obf",
        help="Obfuscated file path (default: jppm-etf-dev.obf)",
    )
    parser.add_argument(
        "-k",
        "--key",
        default="hirotgr",
        help="XOR key (default: hirotgr)",
    )
    args = parser.parse_args()

    csv_path = Path(args.input)
    obf_path = Path(args.obf)

    csv_bytes = csv_path.read_bytes()
    obf_text = obf_path.read_text(encoding="utf-8")
    decoded = decode_obf(obf_text, args.key)

    if csv_bytes == decoded:
        print(f"OK: {csv_path.name} and {obf_path.name} match ({len(csv_bytes)} bytes).")
        return 0

    min_len = min(len(csv_bytes), len(decoded))
    mismatch_index = None
    for i in range(min_len):
        if csv_bytes[i] != decoded[i]:
            mismatch_index = i
            break
    if mismatch_index is None and len(csv_bytes) != len(decoded):
        mismatch_index = min_len

    print("NG: decoded content does not match the CSV.")
    if mismatch_index is not None:
        print(f"First mismatch at byte {mismatch_index}.")
    print(f"CSV size: {len(csv_bytes)} bytes")
    print(f"Decoded size: {len(decoded)} bytes")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
