#!/bin/bash
set -euo pipefail

confirm() {
  echo ""
  read -p "${1:-继续？} [Y/n]: " _c
  [[ -z "$_c" || "$_c" == "y" || "$_c" == "Y" ]] || { echo "已取消。"; exit 0; }
}
pause() { echo ""; read -p "按 Enter 继续下一步，Ctrl+C 退出..."; }

echo "╔══════════════════════════════════════╗"
echo "║     Blesta 服务延期工具 v3.1         ║"
echo "╚══════════════════════════════════════╝"
echo ""

CONFIG_FILE="/home/blesta/public_html/config/blesta.php"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/home/blesta/public_html/config/blesta"
[ ! -f "$CONFIG_FILE" ] && { echo "错误: 找不到配置文件"; exit 1; }

extract() { grep "'$1'" "$CONFIG_FILE" | awk -F"'" '{print $(NF-1)}' | head -1; }

DB_USER=$(extract "user")
DB_PASS=$(extract "pass")
DB_NAME=$(extract "database")
[ -z "$DB_USER" ] && { echo "错误: 无法解析数据库凭据"; exit 1; }
echo "数据库: $DB_USER@$DB_NAME"

BACKUP_DIR="/tmp/add/backup"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/$(date +%Y%m%d%H%M%S).sql.gz"
echo "正在备份数据库..."
mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$BACKUP_FILE"
echo "✓ 备份完成: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))"

read -p "搜索关键词 [SLC]: " KEYWORD; KEYWORD="${KEYWORD:-SLC}"
LOG_FILE="/tmp/add/logs/extend_${KEYWORD}_$(date +%Y%m%d_%H%M%S).log"
mkdir -p /tmp/add/logs

mq(){ mysql -u"$DB_USER" -p"$DB_PASS" -D"$DB_NAME" --batch --skip-column-names -e "$1" 2>/dev/null; }
log()     { echo "$1" | tee -a "$LOG_FILE"; }
logonly() { echo "$1" >> "$LOG_FILE"; }
hr()      { log "────────────────────────────────────────"; }

SNAP="_snap_$$"
USNAP="_usnap_$$"
ABSNAP="_absnap_$$"

log "=== 开始 | 关键词: $KEYWORD | 备份: $BACKUP_FILE | $(date) ==="
hr

# ── Step 1 ────────────────────────────────────────────────
echo ""
echo "[1/6] 查找含 '$KEYWORD' 的 Package..."
PKG_IDS=$(mq "SELECT GROUP_CONCAT(DISTINCT package_id ORDER BY package_id) FROM package_names WHERE name LIKE '%${KEYWORD}%';")
[ -z "$PKG_IDS" ] || [ "$PKG_IDS" = "NULL" ] && { echo "未找到匹配的 Package，退出。"; exit 1; }
PKG_COUNT=$(mq "SELECT COUNT(DISTINCT package_id) FROM package_names WHERE name LIKE '%${KEYWORD}%';")
echo "找到 $PKG_COUNT 个 Package (IDs: $PKG_IDS)"
mq "SELECT package_id, name FROM package_names WHERE name LIKE '%${KEYWORD}%' ORDER BY package_id;" \
  | while IFS=$'\t' read -r pid pname; do
      echo "  [$pid] $pname"
      logonly "  [$pid] $pname"
    done

pause

# ── Step 2 ────────────────────────────────────────────────
echo ""
echo "[2/6] 统计激活服务..."
SVC_COUNT=$(mq "SELECT COUNT(*) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
echo "共 $SVC_COUNT 条激活服务"
log "激活服务总计: $SVC_COUNT"

pause

# ── Step 3 ────────────────────────────────────────────────
echo ""
echo "[3/6] 检查未支付续费账单..."
UNPAID=$(mq "SELECT COUNT(*) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  JOIN service_invoices si ON si.service_id = s.id
  JOIN invoices i ON i.id = si.invoice_id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND si.type = 'renewal'
  AND i.status = 'active'
  AND i.paid < i.total;")
log "未支付续费账单: $UNPAID 条"

if [ "$UNPAID" -gt 0 ]; then
  echo "⚠ 发现 $UNPAID 条未支付续费账单（详见 $LOG_FILE）"
  mq "SELECT s.id, i.id, i.total, i.paid, (i.total-i.paid)
    FROM services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    JOIN service_invoices si ON si.service_id = s.id
    JOIN invoices i ON i.id = si.invoice_id
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND si.type = 'renewal'
    AND i.status = 'active'
    AND i.paid < i.total;" \
    | while IFS=$'\t' read -r sid iid total paid bal; do
        echo "  service=$sid invoice=$iid total=$total paid=$paid balance=$bal"
        logonly "  service=$sid invoice=$iid total=$total paid=$paid balance=$bal"
      done

  confirm "是否作废这 $UNPAID 条账单并将 date_renews 修正为 date_last_renewed？"

  mq "DROP TABLE IF EXISTS $USNAP"
  mq "CREATE TABLE $USNAP AS
    SELECT s.id, s.date_renews AS before_date, s.date_last_renewed
    FROM services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    JOIN service_invoices si ON si.service_id = s.id
    JOIN invoices i ON i.id = si.invoice_id
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND si.type = 'renewal'
    AND i.status = 'active'
    AND i.paid < i.total;"

  PARTIAL=$(mq "SELECT COUNT(*) FROM services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    JOIN service_invoices si ON si.service_id = s.id
    JOIN invoices i ON i.id = si.invoice_id
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND si.type = 'renewal'
    AND i.status = 'active'
    AND i.paid > 0 AND i.paid < i.total;")

  if [ "$PARTIAL" -gt 0 ]; then
    echo "发现 $PARTIAL 条部分付款，退款至账户余额..."
    mq "INSERT INTO transactions (client_id, amount, currency, type, transaction_type_id, status, date_added)
      SELECT s.client_id, i.paid, i.currency, 'other', 4, 'approved', NOW()
      FROM services s
      JOIN package_pricing pp ON s.pricing_id = pp.id
      JOIN service_invoices si ON si.service_id = s.id
      JOIN invoices i ON i.id = si.invoice_id
      WHERE pp.package_id IN ($PKG_IDS)
      AND s.status = 'active'
      AND si.type = 'renewal'
      AND i.status = 'active'
      AND i.paid > 0 AND i.paid < i.total;"
    echo "✓ 已退款 $PARTIAL 条至账户余额"
    log "部分付款退款: $PARTIAL 条"
  fi

  mq "UPDATE invoices i
    JOIN service_invoices si ON si.invoice_id = i.id
    JOIN services s ON s.id = si.service_id
    JOIN package_pricing pp ON s.pricing_id = pp.id
    SET i.status = 'void'
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND si.type = 'renewal'
    AND i.status = 'active'
    AND i.paid < i.total;"

  FIXED=$(mq "SELECT COUNT(*) FROM $USNAP WHERE date_last_renewed IS NOT NULL;")
  mq "UPDATE services s
    JOIN $USNAP b ON b.id = s.id
    SET s.date_renews = s.date_last_renewed
    WHERE s.date_last_renewed IS NOT NULL;"
  echo "✓ 已修正 $FIXED 条服务的到期时间"

  MATCH_U=$(mq "SELECT SUM(CASE WHEN s.date_renews = b.date_last_renewed THEN 1 ELSE 0 END)
    FROM $USNAP b JOIN services s ON s.id = b.id;")
  echo "比对: 正确 $MATCH_U / $UNPAID 条"
  log "未支付账单修正: 正确=$MATCH_U 总计=$UNPAID"
  mq "SELECT b.id, b.before_date, s.date_renews FROM $USNAP b JOIN services s ON s.id = b.id;" \
    | while IFS=$'\t' read -r sid bd ad; do logonly "  UNPAID_FIX sid=$sid before=$bd after=$ad"; done
  mq "DROP TABLE IF EXISTS $USNAP"
else
  echo "✓ 无未支付账单"
fi

# ── Step 3b ───────────────────────────────────────────────
echo ""
echo "[3b] 检查 date_renews 异常推进（与 date_last_renewed 差 > 100天）..."
ABNORMAL=$(mq "SELECT COUNT(*) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_last_renewed IS NOT NULL
  AND DATEDIFF(s.date_renews, s.date_last_renewed) > 100;")
log "date_renews 异常推进: $ABNORMAL 条"

if [ "$ABNORMAL" -gt 0 ]; then
  echo "⚠ 发现 $ABNORMAL 条异常（详见 $LOG_FILE）"
  mq "SELECT s.id, s.date_last_renewed, s.date_renews, DATEDIFF(s.date_renews, s.date_last_renewed) AS diff
    FROM services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND s.date_last_renewed IS NOT NULL
    AND DATEDIFF(s.date_renews, s.date_last_renewed) > 100;" \
    | while IFS=$'\t' read -r sid dlr dr diff; do
        echo "  service=$sid last_renewed=$dlr date_renews=$dr diff=${diff}天"
        logonly "  ABNORMAL sid=$sid last_renewed=$dlr date_renews=$dr diff=${diff}天"
      done

  confirm "是否将这 $ABNORMAL 条服务的 date_renews 修正为 date_last_renewed？"

  mq "DROP TABLE IF EXISTS $ABSNAP"
  mq "CREATE TABLE $ABSNAP AS
    SELECT s.id, s.date_renews AS before_date, s.date_last_renewed
    FROM services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND s.date_last_renewed IS NOT NULL
    AND DATEDIFF(s.date_renews, s.date_last_renewed) > 100;"

  mq "UPDATE services s
    JOIN package_pricing pp ON s.pricing_id = pp.id
    SET s.date_renews = s.date_last_renewed
    WHERE pp.package_id IN ($PKG_IDS)
    AND s.status = 'active'
    AND s.date_last_renewed IS NOT NULL
    AND DATEDIFF(s.date_renews, s.date_last_renewed) > 100;"

  MATCH_AB=$(mq "SELECT SUM(CASE WHEN s.date_renews = b.date_last_renewed THEN 1 ELSE 0 END)
    FROM $ABSNAP b JOIN services s ON s.id = b.id;")
  echo "✓ 已修正，比对: 正确 $MATCH_AB / $ABNORMAL 条"
  log "异常推进修正: 正确=$MATCH_AB 总计=$ABNORMAL"
  mq "SELECT b.id, b.before_date, s.date_renews FROM $ABSNAP b JOIN services s ON s.id = b.id;" \
    | while IFS=$'\t' read -r sid bd ad; do logonly "  ABNORMAL_FIX sid=$sid before=$bd after=$ad"; done
  mq "DROP TABLE IF EXISTS $ABSNAP"
else
  echo "✓ 无异常推进"
fi

pause

# ── Step 4 ────────────────────────────────────────────────
echo ""
echo "[4/6] 当前服务到期时间统计..."
SVC_COUNT=$(mq "SELECT COUNT(*) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
EARLIEST=$(mq "SELECT MIN(s.date_renews) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
LATEST=$(mq "SELECT MAX(s.date_renews) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
echo "待延期服务: $SVC_COUNT 条"
echo "最早到期: $EARLIEST"
echo "最晚到期: $LATEST"
log "待延期: $SVC_COUNT 条 | 最早: $EARLIEST | 最晚: $LATEST"
mq "SELECT s.id, pn.name, s.date_renews
  FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  JOIN package_names pn ON pp.package_id = pn.package_id AND pn.lang = 'en_us'
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW())
  ORDER BY s.date_renews ASC;" \
  | while IFS=$'\t' read -r sid pname dr; do
      logonly "  BEFORE sid=$sid package=$pname date_renews=$dr"
    done

pause

# ── Step 5 ────────────────────────────────────────────────
echo ""
echo "[5/6] 设置延期天数..."
read -p "请输入延期天数（负数为减少）: " DAYS
[[ "$DAYS" =~ ^-?[1-9][0-9]*$ ]] || { echo "无效天数，退出。"; exit 1; }
log "延期天数: $DAYS"

confirm "确认对 $SVC_COUNT 条 $KEYWORD 服务延期 $DAYS 天？"

# ── Step 6 ────────────────────────────────────────────────
echo ""
echo "[6/6] 执行延期..."
mq "DROP TABLE IF EXISTS $SNAP"
mq "CREATE TABLE $SNAP AS
  SELECT s.id, s.date_renews AS before_date
  FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());"

AFFECTED=$(mq "SELECT COUNT(*) FROM $SNAP;")

mq "UPDATE services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  SET s.date_renews = DATE_ADD(s.date_renews, INTERVAL ${DAYS} DAY)
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());"

echo "✓ 已更新 $AFFECTED 条记录"

MATCHED=$(mq "SELECT SUM(CASE WHEN DATEDIFF(s.date_renews, b.before_date) = ${DAYS} THEN 1 ELSE 0 END)
  FROM services s JOIN $SNAP b ON b.id = s.id;")
MISMATCH=$(mq "SELECT SUM(CASE WHEN DATEDIFF(s.date_renews, b.before_date) != ${DAYS} THEN 1 ELSE 0 END)
  FROM services s JOIN $SNAP b ON b.id = s.id;")
echo "比对结果: 正确 $MATCHED 条 / 异常 $MISMATCH 条"
log "比对: 正确=$MATCHED 异常=$MISMATCH | 已更新: $AFFECTED 条"

NEW_EARLIEST=$(mq "SELECT MIN(s.date_renews) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
NEW_LATEST=$(mq "SELECT MAX(s.date_renews) FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW());")
echo "更新后最早到期: $NEW_EARLIEST"
echo "更新后最晚到期: $NEW_LATEST"
log "更新后最早: $NEW_EARLIEST | 最晚: $NEW_LATEST"

mq "SELECT s.id, pn.name, s.date_renews
  FROM services s
  JOIN package_pricing pp ON s.pricing_id = pp.id
  JOIN package_names pn ON pp.package_id = pn.package_id AND pn.lang = 'en_us'
  WHERE pp.package_id IN ($PKG_IDS)
  AND s.status = 'active'
  AND s.date_renews IS NOT NULL
  AND (s.date_canceled IS NULL OR s.date_canceled > NOW())
  ORDER BY s.date_renews ASC;" \
  | while IFS=$'\t' read -r sid pname dr; do
      logonly "  AFTER sid=$sid package=$pname date_renews=$dr"
    done

mq "DROP TABLE IF EXISTS $SNAP"

hr
log "✓ 完成: $AFFECTED 条服务延期 $DAYS 天"
log "备份: $BACKUP_FILE | 日志: $LOG_FILE"
log "=== 结束 | $(date) ==="
echo ""
echo "=== 完成 ==="
echo "备份: $BACKUP_FILE"
echo "日志: $LOG_FILE"
