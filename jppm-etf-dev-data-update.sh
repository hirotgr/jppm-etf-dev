#!/usr/bin/env bash
set -euo pipefail

RETRY_WAIT_SEC=1800
MAX_RETRY=1
BACKUP_RETENTION=30
retry_count=0

# データファイルを置くディレクトリ（例）
DATA_DIR="/Users/username/scripts"
# ファイル名を変数として定義
DATA_FILE="jppm-etf-dev.csv"
OBF_FILE="jppm-etf-dev.obf"
OBF_KEY="hirotgr"
OBF_SCRIPT="${DATA_DIR}/jppm-etf-dev-obfuscate.py"
VERIFY_SCRIPT="${DATA_DIR}/jppm-etf-dev-obf-verify.py"

latest_valid_csv_date() {
  awk -F, '
    $1 ~ /^[0-9]{4}\/[0-9]{1,2}\/[0-9]{1,2}$/ {
      latest = $1
    }
    END {
      if (latest != "") {
        print latest
      }
    }
  ' "$1"
}

# Gitリポジトリはここ
cd "${DATA_DIR}/jppm-etf-dev/"

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

  rm -f "$zip_path"
done

# データファイルの絶対パス (既存であることが前提)
JPPM_FILE="${DATA_DIR}/${DATA_FILE}"
OBF_PATH="${DATA_DIR}/jppm-etf-dev/${OBF_FILE}"

if [[ ! -f "$JPPM_FILE" ]]; then
  echo "${DATA_FILE} が見つかりません: $JPPM_FILE" >&2
  exit 1
fi

LAST_DATE="$(latest_valid_csv_date "$JPPM_FILE")"
echo "${DATA_FILE} の最終日付: ${LAST_DATE:-N/A}"

# 各メタルのCSVから必要期間を抽出し、ETF CSVに追記する行を生成
NEW_ROWS="$(
LAST_DATE="$LAST_DATE" DATA_DIR="$DATA_DIR" JPPM_FILE="$JPPM_FILE" python3 <<'PY'
import csv
import io
import os
import re
import sys
from pathlib import Path
from datetime import datetime

last_date = os.environ.get("LAST_DATE", "")
data_dir = Path(os.environ.get("DATA_DIR", "."))
jppm_file = Path(os.environ.get("JPPM_FILE", "jppm-etf-dev.csv"))
files = [
    ("gold.csv", "1540"),
    ("platinum.csv", "1541"),
    ("silver.csv", "1542"),
    ("palladium.csv", "1543"),
]

DATE_FMT = "%Y/%m/%d"
EXPECTED_HEADER = [
    "Date",
    "1540-price", "1540-nav", "1540-dev", "1540-unit",
    "1541-price", "1541-nav", "1541-dev", "1541-unit",
    "1542-price", "1542-nav", "1542-dev", "1542-unit",
    "1543-price", "1543-nav", "1543-dev", "1543-unit",
]
date_re = re.compile(r"^\d{4}/\d{1,2}/\d{1,2}$")
records = {}
date_objs = {}
DEFAULT_READ_LINES = 20
MAX_SOURCE_READ_LINES = 20000

def parse_date(value):
    try:
        return datetime.strptime(value, DATE_FMT)
    except ValueError:
        return None

def validate_jppm_header(path):
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.reader(f)
            header = next(reader, None)
    except FileNotFoundError:
        print(f"{path} が存在しません。", file=sys.stderr)
        sys.exit(1)
    if header != EXPECTED_HEADER:
        print(
            f"{path.name} のヘッダが想定と異なります。",
            file=sys.stderr,
        )
        print(f"expected: {','.join(EXPECTED_HEADER)}", file=sys.stderr)
        print(f"actual:   {','.join(header or [])}", file=sys.stderr)
        sys.exit(1)

def extract_dates(lines):
    dates = []
    reader = csv.reader(io.StringIO("\n".join(lines)))
    for row in reader:
        if not row:
            continue
        date_raw = row[0].strip()
        if not date_re.match(date_raw):
            continue
        date_dt = parse_date(date_raw)
        if date_dt:
            dates.append(date_dt)
    return dates

def source_lines(path, last_date_dt):
    try:
        all_lines = path.read_text(encoding="cp932").splitlines()
    except UnicodeDecodeError as exc:
        print(f"{path.name} を cp932 として読み込めません: {exc}", file=sys.stderr)
        sys.exit(1)

    if not all_lines:
        return ""

    max_lines = min(len(all_lines), MAX_SOURCE_READ_LINES)
    read_count = min(DEFAULT_READ_LINES, max_lines)

    while True:
        selected = all_lines[-read_count:]
        if not last_date_dt:
            print(f"{path.name} は最新 {read_count} 行を読みました。", file=sys.stderr)
            return "\n".join(selected)

        source_dates = extract_dates(selected)
        if any(date_dt <= last_date_dt for date_dt in source_dates):
            if read_count > DEFAULT_READ_LINES:
                print(
                    f"{path.name} は LAST_DATE まで届くように最新 {read_count} 行を読みました。",
                    file=sys.stderr,
                )
            return "\n".join(selected)

        if read_count >= max_lines:
            print(
                f"{path.name} の読み取り範囲を {read_count} 行まで広げても "
                f"{last_date} 以前の日付が含まれません。",
                file=sys.stderr,
            )
            if len(all_lines) > MAX_SOURCE_READ_LINES:
                print(
                    f"読み取り上限 {MAX_SOURCE_READ_LINES} 行に達しました。",
                    file=sys.stderr,
                )
            print("データ欠落を避けるため更新を中止します。", file=sys.stderr)
            sys.exit(1)

        read_count = min(read_count * 2, max_lines)

validate_jppm_header(jppm_file)

last_date_dt = None
if last_date:
    last_date_dt = parse_date(last_date)

for fname, code in files:
    path = data_dir / fname
    if not path.exists():
        print(f"{fname} が存在しません。", file=sys.stderr)
        sys.exit(1)
    source_data = source_lines(path, last_date_dt)
    reader = csv.reader(io.StringIO(source_data))
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
        unit = row[5].strip().replace(',', '')
        nav = row[7].strip().replace(',', '')
        if not price or not nav or not unit:
            continue
        try:
            price_val = float(price)
            nav_val = float(nav)
            float(unit)
        except ValueError:
            continue
        if nav_val == 0:
            continue
        dev = (price_val - nav_val) / nav_val * 100
        entry = records.setdefault(date_norm, {})
        entry[code] = (price, nav, f"{dev:.2f}", unit)
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
        break
    row = [date]
    for code in order:
        row.extend(entry[code])
    output_lines.append(",".join(row))

for date, missing in missing_dates:
    print(
        f"{date} のデータが不足しています: {', '.join(missing)}",
        file=sys.stderr,
    )
    print(
        "以降の日付は追記しません。次回以降、欠損データが揃ってから追記します。",
        file=sys.stderr,
    )

sys.stdout.write("\n".join(output_lines))
PY
)"

# NEW_ROWSをCSVにappend
NEW_ROWS="${NEW_ROWS%$'\n'}"

appended=0
if [[ -n "$NEW_ROWS" ]]; then
  backup_timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${JPPM_FILE}.${backup_timestamp}.bak"
  if [[ -e "$backup_path" ]]; then
    backup_path="${JPPM_FILE}.${backup_timestamp}.$$.bak"
  fi
  if [[ -e "$backup_path" ]]; then
    echo "バックアップファイルが既に存在します: $backup_path" >&2
    exit 1
  fi
  cp -p "$JPPM_FILE" "$backup_path"
  echo "CSV更新前バックアップを作成しました: $backup_path"

  printf "%s\n" "$NEW_ROWS" >> "$JPPM_FILE"
  appended_count="$(printf "%s" "$NEW_ROWS" | grep -c '^')"
  echo "${DATA_FILE} に ${appended_count} 行を追記しました。"
  backup_count=0
  while IFS= read -r old_backup; do
    backup_count=$((backup_count + 1))
    if [[ "$backup_count" -gt "$BACKUP_RETENTION" ]]; then
      rm -f "$old_backup"
      echo "古いCSVバックアップを削除しました: $old_backup"
    fi
  done < <(find "$DATA_DIR" -maxdepth 1 -type f -name "${DATA_FILE}.*.bak" | sort -r)
  appended=1
else
  echo "追記対象の行はありません。"
fi

obf_needs_update=0
if [[ "$appended" -eq 1 ]]; then
  obf_needs_update=1
else
  if [[ -f "$VERIFY_SCRIPT" ]]; then
    if python3 "$VERIFY_SCRIPT" --input "$JPPM_FILE" --obf "$OBF_PATH" --key "$OBF_KEY"; then
      echo "${OBF_FILE} は ${DATA_FILE} と一致しています。"
    else
      echo "${OBF_FILE} が ${DATA_FILE} と一致しないため再生成します。"
      obf_needs_update=1
    fi
  else
    echo "検証スクリプトが見つかりません: $VERIFY_SCRIPT" >&2
    exit 1
  fi
fi

# CSVを難読化してobfを更新
if [[ "$obf_needs_update" -eq 1 ]]; then
  if [[ -f "$OBF_SCRIPT" ]]; then
    python3 "$OBF_SCRIPT" --input "$JPPM_FILE" --output "$OBF_PATH" --key "$OBF_KEY"
    echo "${OBF_FILE} を更新しました。"
  else
    echo "難読化スクリプトが見つかりません: $OBF_SCRIPT" >&2
    exit 1
  fi
fi

# GitHubへのcommit
LATEST_DATE="$(latest_valid_csv_date "$JPPM_FILE")"

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
cd "${DATA_DIR}"
for entry in "${METAL_SOURCES[@]}"; do
  metal="${entry%%|*}"
  rm -f "${metal}.csv"
done

if [[ "$retry" -eq 1 && "$retry_count" -lt "$MAX_RETRY" ]]; then
  retry_count=$((retry_count + 1))
  echo "30分待機して再実行します。"
  sleep "$RETRY_WAIT_SEC"
  continue
fi

break
done
