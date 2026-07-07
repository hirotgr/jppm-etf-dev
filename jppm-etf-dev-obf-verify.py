#!/usr/bin/env python3
import argparse
import base64
import binascii
import csv
import re
import sys
from pathlib import Path


EXPECTED_HEADER = [
    "Date",
    "1540-price",
    "1540-nav",
    "1540-dev",
    "1540-unit",
    "1541-price",
    "1541-nav",
    "1541-dev",
    "1541-unit",
    "1542-price",
    "1542-nav",
    "1542-dev",
    "1542-unit",
    "1543-price",
    "1543-nav",
    "1543-dev",
    "1543-unit",
]


class CSVHeaderError(ValueError):
    pass


def xor_bytes(data: bytes, key: bytes) -> bytes:
    if not key:
        raise ValueError("key must not be empty")
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def decode_obf(obf_text: str, key: str) -> bytes:
    cleaned = re.sub(r"\s+", "", obf_text)
    raw = base64.b64decode(cleaned)
    return xor_bytes(raw, key.encode("utf-8"))


def validate_csv_header(path: Path) -> None:
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.reader(f)
            header = next(reader, None)
    except FileNotFoundError:
        raise
    except UnicodeDecodeError as exc:
        raise CSVHeaderError(f"CSV is not valid UTF-8: {path}") from exc

    if header != EXPECTED_HEADER:
        actual = ",".join(header or [])
        expected = ",".join(EXPECTED_HEADER)
        raise CSVHeaderError(
            f"CSV header mismatch: {path}\n"
            f"expected: {expected}\n"
            f"actual:   {actual}"
        )


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
        default="jppm-etf-dev/jppm-etf-dev.obf",
        help="Obfuscated file path (default: jppm-etf-dev/jppm-etf-dev.obf)",
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

    try:
        validate_csv_header(csv_path)
        csv_bytes = csv_path.read_bytes()
        obf_text = obf_path.read_text(encoding="utf-8")
        decoded = decode_obf(obf_text, args.key)
    except FileNotFoundError as exc:
        missing = "CSV" if Path(exc.filename) == csv_path else "obf"
        print(f"{missing} not found: {exc.filename}", file=sys.stderr)
        return 1
    except CSVHeaderError as exc:
        print(exc, file=sys.stderr)
        return 1
    except (binascii.Error, ValueError) as exc:
        print(f"Failed to decode obf: {exc}", file=sys.stderr)
        return 1

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
