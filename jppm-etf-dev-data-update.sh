#!/usr/bin/env bash
set -euo pipefail

RETRY_WAIT_SEC=1800
MAX_RETRY=1
retry_count=0

# データファイルを置くディレクトリ
DATA_DIR="./"
# ファイル名を変数として定義
DATA_FILE="jppm-etf-dev.csv"
OBF_FILE="jppm-etf-dev.obf"
OBF_KEY="hirotgr"
OBF_SCRIPT="jppm-etf-dev-obfuscate.py"

cd "$DATA_DIR"

# ヒストリカルデータのURL
METAL_SOURCES=(
  "gold|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/01/teaserItems1/0/linkList/0/link/gold.zip"
  "platinum|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/01/teaserItems2/0/linkList/0/link/platinum.zip"
  "silver|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/02/teaserItems1/0/linkList/0/link/silver.zip"
  "palladium|https://kikinzoku.tr.mufg.jp/ja/data_report/historicaldata/main/02/teaserItems2/0/linkList/0/link/palladium.zip"
)

while true; do
  retry=0

# ヒストリカルデータのダウンロード

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

# データファイルの絶対パス (既存であることが前提)
JPPM_FILE="${DATA_DIR}/${DATA_FILE}"
OBF_PATH="${DATA_DIR}/${OBF_FILE}"

if [[ ! -f "$JPPM_FILE" ]]; then
  echo "${DATA_FILE} が見つかりません: $JPPM_FILE" >&2
  exit 1
fi

LAST_DATE="$(tail -n 1 "$JPPM_FILE" | awk -F, 'NF {print $1}')"
if [[ ! "$LAST_DATE" =~ ^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$ ]]; then
  LAST_DATE=""
fi
echo "${DATA_FILE} の最終日付: ${LAST_DATE:-N/A}"

# 各メタルのCSVから最新20行をまとめて抽出し、ETF CSVに追記する行を生成
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

# NEW_ROWSをCSVにappend
NEW_ROWS="${NEW_ROWS%$'\n'}"

appended=0
if [[ -n "$NEW_ROWS" ]]; then
  printf "%s\n" "$NEW_ROWS" >> "$JPPM_FILE"
  appended_count="$(printf "%s" "$NEW_ROWS" | grep -c '^')"
  echo "${DATA_FILE} に ${appended_count} 行を追記しました。"
appended=1
else
  echo "追記対象の行はありません。"
fi

# CSVを難読化してobfを更新（追記があった場合のみ）
if [[ "$appended" -eq 1 ]]; then
  if [[ -f "$OBF_SCRIPT" ]]; then
    python3 "$OBF_SCRIPT" --input "$JPPM_FILE" --output "$OBF_PATH" --key "$OBF_KEY"
    echo "${OBF_FILE} を更新しました。"
  else
    echo "難読化スクリプトが見つかりません: $OBF_SCRIPT" >&2
    exit 1
  fi
fi

# GitHubへのcommit
LATEST_DATE="$(tail -n 1 "$JPPM_FILE" | awk -F, 'NF {print $1}')"
if [[ ! "$LATEST_DATE" =~ ^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$ ]]; then
  LATEST_DATE=""
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  status_output="$(git status --short -- "$OBF_PATH")"
  if [[ -z "$status_output" ]]; then
    echo "${OBF_FILE} に変更はありません。コミットは行いません。"
    retry=1
  else
    git add "$OBF_PATH"
    commit_msg="updated at ${LATEST_DATE:-unknown date}"
    if git commit -m "$commit_msg"; then
      echo "GitHub 用のコミットを作成しました: $commit_msg"
      current_branch="$(git rev-parse --abbrev-ref HEAD)"
      remote_name="$(git config branch."$current_branch".remote || echo origin)"
      echo "GitHub (${remote_name}/${current_branch}) へ push 中..."
      if git push "$remote_name" "$current_branch"; then
        echo "GitHub への push が完了しました。"
      else
        echo "git push に失敗しました。手動で確認してください。" >&2
        exit 1
      fi
    else
      echo "git commit に失敗しました。" >&2
      exit 1
    fi
  fi
else
  echo "Git リポジトリ外のため、コミット処理はスキップします。"
fi

# ダウンロードしたヒストリカルデータを削除
for entry in "${METAL_SOURCES[@]}"; do
  metal="${entry%%|*}"
  rm "${metal}.csv"
done

if [[ "$retry" -eq 1 && "$retry_count" -lt "$MAX_RETRY" ]]; then
  retry_count=$((retry_count + 1))
  echo "30分待機して再実行します。"
  sleep "$RETRY_WAIT_SEC"
  continue
fi

break
done
