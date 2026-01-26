#!/usr/bin/env python3
import argparse
import base64
from pathlib import Path


def xor_bytes(data: bytes, key: bytes) -> bytes:
    if not key:
        raise ValueError("key must not be empty")
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="XOR + Base64 obfuscate a CSV file for browser use.",
    )
    parser.add_argument(
        "-i",
        "--input",
        default="jppm-etf-dev.csv",
        help="Input CSV path (default: jppm-etf-dev.csv)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="jppm-etf-dev.obf",
        help="Output obfuscated path (default: jppm-etf-dev.obf)",
    )
    parser.add_argument(
        "-k",
        "--key",
        default="hirotgr",
        help="XOR key (default: hirotgr)",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    data = input_path.read_bytes()
    key_bytes = args.key.encode("utf-8")
    obf = base64.b64encode(xor_bytes(data, key_bytes))
    output_path.write_bytes(obf + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
