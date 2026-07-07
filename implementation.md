# jppm-etf-dev 実装メモ

この文書は、`jppm-etf-dev` の貴金属 ETF 乖離率チャート SPA と、そのデータ更新・難読化・運用スクリプトの実装理解をまとめたものです。

## 全体構成

このリポジトリには GitHub Pages で公開される SPA 本体、難読化済みデータ、README、データ更新スクリプト例、macOS LaunchAgent 例、難読化・検証用 Python スクリプトが含まれます。

元データCSV の `jppm-etf-dev.csv` はGitリポジトリ直下ではなく、親ディレクトリのに置かれています。公開 SPA は CSV を直接読まず、リポジトリ内の `jppm-etf-dev.obf` を取得し、ブラウザ側で復号して表示します。

主なファイルの役割は以下です。

| パス | 役割 |
| --- | --- |
| `./jppm-etf-dev.csv` | 更新元の平文 CSV。日付、各 ETF の東証終値、理論価額、乖離率を保持する。 |
| `./jppm-etf-dev-data-update.sh` | 親ディレクトリにある運用向け更新スクリプト。`DATA_DIR` を基準に repo 内 `.obf` を更新する。 |
| `./jppm-etf-dev-obfuscate.py` | 平文 CSV を XOR + Base64 で `.obf` に変換する。 |
| `./jppm-etf-dev-obf-verify.py` | `.obf` を復号し、平文 CSV と完全一致するか検証する。 |
| `./jppm-etf-dev.csv` | 元データのファイル。リポジトリには含まれておらず、`index.html`は`./jppm-etf-dev/jppm-etf-dev.obf`を読み込む |
| `./jppm-etf-dev/index.html` | SPA 本体。UI、データ読み込み、復号、CSV parse、チャート描画をすべて含む単一 HTML。 |
| `./jppm-etf-dev/jppm-etf-dev.obf` | 公開用の難読化済みデータ。XOR 後に Base64 化された CSV。 |
| `./jppm-etf-dev/jppm-etf-dev.html` | 公開 URL `https://hirotgr.github.io/jppm-etf-dev/` へリダイレクトする HTML。 |
| `./jppm-etf-dev/com.username.jppm-etf-dev-data-update.plist` | macOS LaunchAgent の定時実行設定例。 |
| `./jppm-etf-dev/README.md` | 概要、GitHub Pages URL、主要ファイル、使用イメージを記載。 |


## データ形式

平文 CSV は先頭に BOM 付きヘッダを持ち、日付ごとに 4 銘柄分の値を横持ちします。

```csv
Date,1540-price,1540-nav,1540-dev,1540-unit,1541-price,1541-nav,1541-dev,1541-unit,1542-price,1542-nav,1542-dev,1542-unit,1543-price,1543-nav,1543-dev,1543-unit
```

対象銘柄は以下です。

| コード | 表示名 | 金属 |
| --- | --- | --- |
| 1540 | 純金上場投信 | 金 |
| 1541 | 純プラチナ上場投信 | プラチナ |
| 1542 | 純銀上場投信 | 銀 |
| 1543 | 純パラジウム上場投信 | パラジウム |

各銘柄について、`price` は東証終値、`nav` は理論価額または基準価額、`dev` は乖離率、`unit` はETFの設定口数です。更新スクリプト上の乖離率計算は次の式です。

```text
dev = (price - nav) / nav * 100
```

## SPA 本体の実装

`index.html` は外部 JS/CSS ファイルを持たない単一ファイル SPA です。TradingView の Lightweight Charts と Google Fonts を CDN から読み込み、DOM 構築、状態管理、データ取得、チャート描画をインライン JavaScript で完結させています。

### 主要定数と状態

JavaScript では `symbols` が 4 銘柄の表示名を定義し、`columns` が銘柄コードから CSV カラム名への対応を定義します。

`OBF_FILE` は `jppm-etf-dev.obf`、`OBF_KEY` は `hirotgr` です。ブラウザはこのキーを使って `.obf` を復号します。これは秘匿ではなく、CSV の直接閲覧を軽く避けるための難読化です。

`SMA_PERIODS` は `[20, 50, 100, 200]` で、理論価額 NAV に対する SMA20/SMA50/SMA100/SMA200 を価格チャートへ重ねて描画します。

`state` は以下のような表示状態をまとめて保持します。

- 読み込み済み行データと最新行
- 現在選択中の銘柄
- 上段:価格チャート、中段:ETF設定口数チャート、下段:乖離率チャート
- Price/NAV/Unit/Deviation/SMA の系列と検索用 Map
- 表示範囲同期、ドラッグ、リサイズ、ツールチップの初期化状態

### データ読み込みと復号

起動時は `DOMContentLoaded` で `setupModal()` と `loadData()` が呼ばれます。

`loadData()` は `fetch(OBF_FILE, { cache: 'no-store' })` で `jppm-etf-dev.obf` を取得します。取得後、次の流れでデータを復元します。

1. `base64ToBytes()` が Base64 文字列を `Uint8Array` に変換する。
2. `xorBytes()` が `OBF_KEY` の UTF-8 バイト列で XOR 復号する。
3. `decodeObf()` が復号バイト列を UTF-8 文字列として CSV に戻す。
4. `parseCSV()` が CSV を行オブジェクトの配列に変換する。
5. 各行の `Date` を `toUTC()` で Lightweight Charts 用の UNIX 秒へ変換し、`__time` として保持する。

CSV parser は単純なカンマ split ベースです。現在の CSV は quoted field を含まないため成立していますが、将来データにカンマを含む quoted field が入る場合は CSV parser の見直しが必要です。

### 最新値テーブル

`renderLatestTable()` は `state.latest` を使い、最終更新日と 4 銘柄の最新値テーブルを描画します。銘柄名は button で、クリックすると `updateSymbol(id)` が呼ばれ、表示対象銘柄が切り替わります。

数値整形は `fmtNumber()` と `fmtInteger()` が担当します。市場価格は整数表示、理論価額と乖離率は小数表示です。乖離率には `%` を付けて表示します。

### チャート描画

`initCharts()` が初回のみ Lightweight Charts のチャートを 3 つ作成します。

- 上段 `priceChart`: Price、NAV、NAV の SMA20/SMA50/SMA100/SMA200 を line series として描画する。
- 中段 `unitChart`: ETF設定口数を line series として描画する。軸表示は千単位の `K` 表記。
- 下段 `devChart`: 乖離率を histogram series として描画する。

共通のチャート設定は `commonChartOptions()` にまとめられています。背景は透明、文字色やグリッドはダークテーマに合わせています。スクロールは独自処理で制御するため `handleScroll` の mouse wheel と pressed move は無効化され、scale は wheel/pinch を有効にしています。

`updateSymbol(symbolId)` は銘柄切り替え時の中心処理です。

1. CSV から対象銘柄の Price/NAV/Unit/Deviation 配列を `buildSeriesData()` で作る。
2. ツールチップ参照用に time -> value の Map を構築する。
3. line/histogram series に `setData()` する。
4. NAV データから `computeSMA()` で SMA を計算し、SMA series に設定する。
5. 直近 1 年を初期表示範囲として `setInitialRange()` で 3 つのチャートに適用する。

下段の乖離率 histogram には、最終データ日の翌日に透明のダミー点を追加しています。これは右端に少し余白を持たせ、最新棒がチャート端に詰まりすぎないようにするための実装です。

### 表示範囲同期と操作

3 つのチャートの表示範囲は `syncCharts()` と `applyRange()` で同期されます。

`subscribeVisibleTimeRangeChange()` でいずれかの visible range 変更を検知し、`applyRange()` が 3 つすべてへ同じ範囲を設定します。同期中の再入を避けるため、`state.skipSync` を使っています。

`clampRangeWithSpan()` は表示範囲がデータ全体の範囲から外れないように補正します。`state.initialRange` は先頭データ日から最終データ日の翌日までで、ドラッグやズーム時の境界として使われます。

チャート上のドラッグ移動は `setupDragHandlers()` が独自に実装しています。pointer down 時点の visible range と x 座標を保持し、pointer move の移動量を表示期間の秒数へ換算して新しい range を適用します。リサイズハンドル付近の pointer down はドラッグ開始から除外しています。

### リサイズ

`setupResizeObservers()` は `ResizeObserver` を使い、`priceChart`、`unitChart`、`devChart` の DOM サイズ変更を Lightweight Charts に反映します。CSS 側ではチャート領域に `resize` が設定されており、全体または個別チャートのサイズをブラウザ上で変更できます。

リサイズ後は既存の visible range を再適用し、3 つのチャートの表示範囲同期を保ちます。

### ツールチップ

`setupTooltips()` は 3 つのチャートそれぞれの crosshair move を購読し、独自 tooltip DOM を表示します。

上段チャートの tooltip は Price、NAV、該当日の SMA 値を表示します。中段チャートの tooltip はETF設定口数、下段チャートの tooltip は乖離率を表示します。どのチャートに crosshair が乗った場合でも、同じ日付の値を Map から引いて他チャートの tooltip と crosshair も同期する実装になっています。

`positionTooltip()` は tooltip がチャート領域からはみ出さないよう、左右上下の座標を補正します。

### ヘルプ modal と外部リンク

ヘッダには金の果実シリーズ公式サイトへのリンク、他ツールへのリンク、ヘルプボタンがあります。

`setupModal()` はヘルプ modal の開閉を担当します。ヘルプ本文にはツールの目的、市場価格と基準価額に関する注意、操作方法、リポジトリ、ライセンス、CDN とフォントへの依存が記載されています。

外部リンクの `target="_blank"` には `rel="noopener noreferrer"` を明示しています。Google Fonts の URL は HTML 属性内で `&amp;display=swap` としてエスケープされています。

## データ更新処理

データ更新は親ディレクトリ版の `./jppm-etf-dev-data-update.sh` が担当します。実運用では、親ディレクトリの平文 CSV と `./jppm-etf-dev` の公開用 `.obf` をつなぐ形になっています。

処理概要は以下です。

1. `METAL_SOURCES` に定義された 4 種類の ZIP を三菱UFJ信託銀行サイトから `curl` で取得する。
2. ZIP を `unzip` し、`gold.csv`、`platinum.csv`、`silver.csv`、`palladium.csv` を展開する。
3. 既存の `jppm-etf-dev.csv` から、1 列目が `YYYY/M/D` 形式の最後の有効日付を `latest_valid_csv_date()` で取得する。末尾に空行や不正行があっても最後の有効日付を使う。
4. 埋め込み Python が各金属 CSV を CP932 として読み、まず最新 20 行から開始し、必要なら 40/80/160 行と読み取り範囲を広げる。`LAST_DATE` 以前の日付に届かない場合は、データ欠落を避けるため更新を中止する。
5. 最終日付より新しい行だけを抽出し、4 銘柄すべてのデータが揃っている日付だけ、横持ち 1 行の CSV として生成する。
6. 途中に欠損日がある場合は、その日付以降の追記を停止する。後続日付が完全でも追記せず、次回以降に欠損データが揃ってから処理する。
7. 新規行があれば、追記直前に `./jppm-etf-dev.csv.YYYYmmdd-HHMMSS.bak` 形式のバックアップを作成する。同秒衝突時は PID を含めた名前にする。
8. バックアップ成功後に `jppm-etf-dev.csv` へ追記し、追記成功後にバックアップを直近 30 件だけ残して古いものを削除する。
9. 追記があった場合、または既存 `.obf` と CSV が一致しない場合は `jppm-etf-dev-obfuscate.py` で `.obf` を更新する。
10. Git リポジトリ内で `.obf` に変更があれば `git add`、`git commit -m "updated at YYYY/MM/DD"`、`git push` を実行する。
11. 展開した金属 CSV を削除する。
12. `.obf` に変更がなかった場合は最大 1 回、30 分待機して再実行する。

埋め込み Python は各金属 CSV から `row[1]` を市場価格、`row[5]` をETF設定口数、`row[7]` を理論価額として読み取ります。日付形式は `%Y/%m/%d` です。読み取り上限は `MAX_SOURCE_READ_LINES=20000` です。

この構成では、公開リポジトリに平文 CSV を含めず、親ディレクトリに保持した CSV から repo 内 `.obf` だけを更新・公開する運用が意図されています。

## 難読化と検証

難読化は暗号化ではなく、固定キーによる XOR と Base64 です。Python とブラウザ側 JavaScript が同じ処理を実装しています。

`jppm-etf-dev-obfuscate.py` の処理は以下です。

1. 入力 CSV を bytes として読む。
2. `--key` の UTF-8 bytes を繰り返し適用し、各 byte を XOR する。
3. XOR 後の bytes を Base64 encode する。
4. 出力先ディレクトリの存在を確認する。存在しない場合は `Output directory not found: ...` を表示して終了する。
5. 出力ファイルと同じディレクトリに `<output>.tmp.<pid>` 形式の一時ファイルを書き込む。
6. 書き込み成功後、`Path.replace()` で一時ファイルを最終 `.obf` に置き換える。
7. 失敗時に一時ファイルが残っていれば削除する。

デフォルトは以下です。

```text
--input  jppm-etf-dev.csv
--output jppm-etf-dev/jppm-etf-dev.obf
--key    hirotgr
```

`jppm-etf-dev-obf-verify.py` は `.obf` の空白を除去し、Base64 decode、XOR 復号を行い、平文 CSV の bytes と完全一致するか検証します。不一致時は最初の mismatch byte と両ファイルサイズを表示します。

確認済みの検証コマンドは以下です。

```sh
cd ./jppm-etf-dev
python3 jppm-etf-dev-obf-verify.py --input ../jppm-etf-dev.csv --obf jppm-etf-dev.obf --key hirotgr
```

確認時点では次の結果でした。

```text
OK: jppm-etf-dev.csv and jppm-etf-dev.obf match (458527 bytes).
```

## 公開・運用

GitHub Pages の公開 URL は `https://hirotgr.github.io/jppm-etf-dev/` です。README でも同 URL が案内されています。

`jppm-etf-dev.html` はこの URL へのリダイレクト用 HTML です。meta refresh と `window.location.replace()` の両方を使っており、ブラウザ履歴にリダイレクト元を残しにくい実装です。

`com.username.jppm-etf-dev-data-update.plist` は macOS LaunchAgent の例です。平日 18:00 に `/bin/bash /Users/username/scripts/jppm-etf-dev-data-update.sh` を実行する設定になっています。実利用時は username やスクリプトパスを環境に合わせて変更する必要があります。標準出力と標準エラーは `/tmp/jppm-etf-dev-data-update.out` と `/tmp/jppm-etf-dev-data-update.err` に保存する例になっています。

更新スクリプトは Git リポジトリ内で `.obf` に変更がある場合のみ commit/push します。コミットメッセージは `updated at YYYY/MM/DD` 形式です。確認時点の repo は `origin` が `https://github.com/hirotgr/jppm-etf-dev.git` を指しており、最新履歴には `updated at 2026/07/07` が含まれていました。

## 依存関係

ブラウザ表示時の外部依存は以下です。

- Lightweight Charts `4.1.0`: `https://cdn.jsdelivr.net/npm/lightweight-charts@4.1.0/dist/lightweight-charts.standalone.production.min.js`
- Noto Sans JP: `https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;600&display=swap` (`index.html` 内では `&amp;display=swap` として記述)

データ更新時の主なローカル依存は以下です。

- `bash`
- `curl`
- `unzip`
- `awk`
- `date`
- `cp`
- `find`
- `sort`
- `python3`
- `git`

埋め込み Python は標準ライブラリのみを使っています。外部 Python パッケージは不要です。

## 現状確認メモ

調査時点で確認した状態は以下です。

- `DATA_DIR` 自体は Git リポジトリではない。
- `./jppm-etf-dev` は Git リポジトリ。
- `./jppm-etf-dev/jppm-etf-dev.obf` は `./jppm-etf-dev.csv` と復号一致する。
- 運用スクリプトは `DATA_DIR` 直下の `./jppm-etf-dev-data-update.sh`、`./jppm-etf-dev-obfuscate.py`、`./jppm-etf-dev-obf-verify.py` 。

## 新機能追加時の注意点

この SPA はビルド工程を持たない単一 HTML です。新機能を追加する場合、`index.html` のインライン CSS/JavaScript が肥大化しやすいため、変更範囲と状態管理の影響を事前に確認する必要があります。

データ列を増やす機能では、以下を同時に更新する必要があります。

- 平文 CSV の列設計
- データ更新スクリプトの生成行
- 難読化後 `.obf`
- `index.html` の `columns`、parse 後の参照、表示 UI、チャート系列

チャート操作系を変更する場合は、3 つのチャートの visible range 同期、crosshair 同期、`state.skipSync` / `state.skipCrosshairSync`、独自ドラッグ処理、ResizeObserver の再適用処理が干渉しないか確認が必要です。

データ更新処理を変更する場合は、親ディレクトリの平文 CSV から repo 内 `.obf` を更新する構成、CSV 更新前バックアップ、欠損日以降の追記停止、`.obf` の一時ファイル経由 replace を壊さないよう確認が必要です。
