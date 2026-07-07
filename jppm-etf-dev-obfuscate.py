#!/usr/bin/env python3
import argparse
import base64
import csv
import os
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
        default="jppm-etf-dev/jppm-etf-dev.obf",
        help="Output obfuscated path (default: jppm-etf-dev/jppm-etf-dev.obf)",
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

    try:
        validate_csv_header(input_path)
        data = input_path.read_bytes()
        key_bytes = args.key.encode("utf-8")
        obf = base64.b64encode(xor_bytes(data, key_bytes))
        if not output_path.parent.exists():
            print(f"Output directory not found: {output_path.parent}", file=sys.stderr)
            return 1
        tmp_path = output_path.with_name(f"{output_path.name}.tmp.{os.getpid()}")
        try:
            tmp_path.write_bytes(obf + b"\n")
            tmp_path.replace(output_path)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()
        return 0
    except FileNotFoundError as exc:
        print(f"CSV not found: {exc.filename}", file=sys.stderr)
    except CSVHeaderError as exc:
        print(exc, file=sys.stderr)
    except ValueError as exc:
        print(f"Obfuscation failed: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
