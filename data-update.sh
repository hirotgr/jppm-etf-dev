#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="."

# ヒストリカルデータのURL
METAL_SOURCES=(
  "gold|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/01/teaserItems1/0/linkList/0/link/gold.zip"
  "platinum|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/01/teaserItems2/0/linkList/0/link/platinum.zip"
  "silver|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/02/teaserItems1/0/linkList/0/link/silver.zip"
  "palladium|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/02/teaserItems2/0/linkList/0/link/palladium.zip"
)

# ヒストリカルデータのダウンロード
mkdir -p "$DATA_DIR"

for entry in "${METAL_SOURCES[@]}"; do
  metal="${entry%%|*}"
  url="${entry##*|}"
  zip_path="${DATA_DIR}/${metal}.zip"

  echo "Downloading ${metal} data..."
  curl -fsSL "$url" -o "$zip_path"

  echo "Unzipping ${zip_path}..."
  unzip -o "$zip_path" -d "$DATA_DIR"

  rm "$zip_path"
done

# jppm-etf.csvの最終更新日を取得
JPPM_FILE="${DATA_DIR}/jppm-etf.csv"

if [[ ! -f "$JPPM_FILE" ]]; then
  echo "jppm-etf.csv が見つかりません: $JPPM_FILE" >&2
  exit 1
fi

LAST_DATE="$(tail -n 1 "$JPPM_FILE" | awk -F, 'NF {print $1}')"
if [[ ! "$LAST_DATE" =~ ^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$ ]]; then
  LAST_DATE=""
fi
echo "jppm-etf.csv の最終日付: ${LAST_DATE:-N/A}"

# 各メタルの CSV から最新20行をまとめて抽出し、ETF CSV に追記する行を生成
# 20営業日以上データ更新しないと動かなくなるのは仕様上の制限
NEW_ROWS="$(
LAST_DATE="$LAST_DATE" DATA_DIR="$DATA_DIR" python3 <<'PY'
import csv
import io
import os
import re
import subprocess
import sys
from pathlib import Path
from datetime import datetime

last_date = os.environ.get("LAST_DATE", "")
data_dir = Path(os.environ.get("DATA_DIR", "."))
files = [
    ("gold.csv", "1540"),
    ("platinum.csv", "1541"),
    ("silver.csv", "1542"),
    ("palladium.csv", "1543"),
]

DATE_FMT = "%Y/%m/%d"
date_re = re.compile(r"^\d{4}/\d{1,2}/\d{1,2}$")
records = {}
date_objs = {}

def parse_date(value):
    try:
        return datetime.strptime(value, DATE_FMT)
    except ValueError:
        return None

def tail_lines(path):
    try:
        result = subprocess.run(
            ["tail", "-n", "20", str(path)],
            check=True,
            capture_output=True,
            text=True,
            encoding="cp932",
        )
    except subprocess.CalledProcessError as exc:
        print(f"tail が失敗しました ({path}): {exc}", file=sys.stderr)
        sys.exit(1)
    return result.stdout

last_date_dt = None
if last_date:
    last_date_dt = parse_date(last_date)

for fname, code in files:
    path = data_dir / fname
    if not path.exists():
        print(f"{fname} が存在しません。", file=sys.stderr)
        sys.exit(1)
    tail_data = tail_lines(path)
    reader = csv.reader(io.StringIO(tail_data))
    for row in reader:
        if not row:
            continue
        date_raw = row[0].strip()
        if not date_re.match(date_raw):
            continue
        date_dt = parse_date(date_raw)
        if not date_dt:
            continue
        if last_date_dt and date_dt <= last_date_dt:
            continue
        date_norm = date_dt.strftime(DATE_FMT)
        if len(row) <= 7:
            continue
        price = row[1].strip().replace(',', '')
        nav = row[7].strip().replace(',', '')
        if not price or not nav:
            continue
        try:
            price_val = float(price)
            nav_val = float(nav)
        except ValueError:
            continue
        if nav_val == 0:
            continue
        dev = (price_val - nav_val) / nav_val * 100
        entry = records.setdefault(date_norm, {})
        entry[code] = (price, nav, f"{dev:.2f}")
        date_objs[date_norm] = date_dt

dates = sorted(records.keys(), key=lambda d: date_objs[d])
order = [code for _, code in files]
missing_dates = []
output_lines = []

for date in dates:
    entry = records[date]
    missing = [code for code in order if code not in entry]
    if missing:
        missing_dates.append((date, missing))
        continue
    row = [date]
    for code in order:
        row.extend(entry[code])
    output_lines.append(",".join(row))

for date, missing in missing_dates:
    print(
        f"{date} のデータが不足しています: {', '.join(missing)}",
        file=sys.stderr,
    )

sys.stdout.write("\n".join(output_lines))
PY
)"

# NEW_ROWSをjppm-etf.csvにappend
NEW_ROWS="${NEW_ROWS%$'\n'}"

if [[ -n "$NEW_ROWS" ]]; then
  printf "%s\n" "$NEW_ROWS" >> "$JPPM_FILE"
  appended_count="$(printf "%s" "$NEW_ROWS" | grep -c '^')"
  echo "jppm-etf.csv に ${appended_count} 行を追記しました。"
else
  echo "追記対象の行はありません。"
fi

# GitHubへのcommit
LATEST_DATE="$(tail -n 1 "$JPPM_FILE" | awk -F, 'NF {print $1}')"
if [[ ! "$LATEST_DATE" =~ ^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$ ]]; then
  LATEST_DATE=""
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  status_output="$(git status --short -- "$JPPM_FILE")"
  if [[ -z "$status_output" ]]; then
    echo "jppm-etf.csv に変更はありません。コミットは行いません。"
  else
    git add "$JPPM_FILE"
    commit_msg="updated at ${LATEST_DATE:-unknown date}"
    if git commit -m "$commit_msg"; then
      echo "GitHub 用のコミットを作成しました: $commit_msg"
    else
      echo "git commit に失敗しました。" >&2
      exit 1
    fi
  fi
else
  echo "Git リポジトリ外のため、コミット処理はスキップします。"
fi

# ダウンロードしたヒストリカルデータを削除
rm gold.csv
rm platinum.csv
rm silver.csv
rm palladium.csv
