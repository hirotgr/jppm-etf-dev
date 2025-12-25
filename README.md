三菱UFJ信託銀行の国内現物保管型貴金属ETF (1540.T, 1541.T, 1542.T, 1543.T) の市場価格(東証終値)と理論価額(基準価額)の乖離率を描画するツールです。

GitHub Pages: https://hirotgr.github.io/jppm-etf-dev/jppm-etf-dev.html

* jppm-etf-dev.html : 本体
* jppm-etf-dev.csv : ETF市場価格/理論価額/乖離率データ
* jppm-etf-dev-data-update.sh (内部でPython実行) : データ更新スクリプト例 (*)
* com.[username].jppm-etf-dev-data-update.plist : macOSでの定時実行 plist例  (*)
  * `~/Library/LaunchAgents/`　において `launchctl [load | unload] ~/Library/LaunchAgents/com.[username].jppm-etf-dev-data-update.plist` および `launchctl list com.[username].jppm-etf-dev-data-update`

<br>
(*) : 環境によってカスタマイズが必要