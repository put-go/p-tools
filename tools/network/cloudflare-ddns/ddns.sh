#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# Debian/Ubuntu: sudo bash ddns.sh TOKEN ZONE_ID DNS_NAME [optional arguments]
# Cron uses --run and never prompts or installs packages.
STATE_DIR='/var/lib/cloudflare-ddns-index'
CONFIG_FILE="$STATE_DIR/config.sh"
API='https://api.cloudflare.com/client/v4'
log(){ printf '%s [ddns] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail(){ log "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail '请使用 sudo bash ddns.sh 加参数运行'
usage(){
 cat >&2 <<'USAGE'
用法（Debian/Ubuntu）：
  sudo bash ddns.sh TOKEN ZONE_ID DNS_NAME [A_INDEX] [AAAA_INDEX] [INTERVAL] [AUTO_CREATE] [PROXIED] [TTL]
必填：Cloudflare API Token、Zone ID、完整域名。
默认：A_INDEX=1，AAAA_INDEX=0，INTERVAL=1，AUTO_CREATE=true，PROXIED=false，TTL=60。
记录序号 0 禁用该地址类型；1 表示最早创建的记录。至少启用一种地址类型。
INTERVAL 可选 1/2/5/10/15/30 分钟；布尔值为 true/false。
TTL 为 1（自动）或 60–86400 秒；启用代理时固定为 1。
定时任务内部调用：ddns.sh --run
USAGE
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if [[ $# == 1 && "$1" == --run ]]; then
 MODE=--run
else
 (( $# >= 3 && $# <= 9 )) || { usage; exit 1; }
 MODE=--install
 CF_TOKEN="$1"
 ZONE_ID="$2"
 DNS_NAME="$3"
 A_RECORD_INDEX="${4:-1}"
 AAAA_RECORD_INDEX="${5:-0}"
 CRON_INTERVAL="${6:-1}"
 AUTO_CREATE="${7:-true}"
 NEW_RECORD_PROXIED="${8:-false}"
 NEW_RECORD_TTL="${9:-60}"
 [[ "$NEW_RECORD_PROXIED" != true ]] || NEW_RECORD_TTL=1
fi
if [[ "$MODE" == --run ]]; then
 [[ -f "$CONFIG_FILE" ]] || fail '未找到配置，请先传入参数安装'
 # Generated with shell escaping; only root can write this file.
 source "$CONFIG_FILE"
fi
[[ -n "${CF_TOKEN:-}" && "${ZONE_ID:-}" =~ ^[0-9a-fA-F]{32}$ ]] || fail '配置中的 Token 或 Zone ID 无效'
[[ "${DNS_NAME:-}" =~ ^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)+\.?$ ]] || fail '域名无效'
[[ "$A_RECORD_INDEX" =~ ^[0-9]{1,5}$ && "$AAAA_RECORD_INDEX" =~ ^[0-9]{1,5}$ ]] || fail '记录序号无效'
((10#$A_RECORD_INDEX <= 10000 && 10#$AAAA_RECORD_INDEX <= 10000)) || fail '记录序号超出范围'
[[ "$AUTO_CREATE" == true || "$AUTO_CREATE" == false ]] || fail 'AUTO_CREATE 无效'
[[ "$NEW_RECORD_PROXIED" == true || "$NEW_RECORD_PROXIED" == false ]] || fail 'NEW_RECORD_PROXIED 无效'
[[ "$CRON_INTERVAL" =~ ^(1|2|5|10|15|30)$ ]] || fail '更新间隔无效'
[[ "$NEW_RECORD_TTL" =~ ^[0-9]{1,5}$ ]] && ((10#$NEW_RECORD_TTL == 1 || (10#$NEW_RECORD_TTL >= 60 && 10#$NEW_RECORD_TTL <= 86400))) || fail 'TTL 无效'
((10#$A_RECORD_INDEX > 0 || 10#$AAAA_RECORD_INDEX > 0)) || fail 'IPv4 和 IPv6 至少启用一个'
[[ "$CF_TOKEN" != *[[:space:]]* ]] || fail 'Token 不能包含空白字符'
if [[ "$MODE" == --install ]]; then
 command -v apt-get >/dev/null || fail '此安装脚本支持 Debian/Ubuntu（需要 apt-get）'
 apt-get update -qq
 apt-get install -y -qq curl jq cron util-linux ca-certificates
fi
for cmd in curl jq flock crontab; do command -v "$cmd" >/dev/null || fail "Missing $cmd"; done
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "Another run holds $STATE_DIR/lock; inspect with: fuser -v $STATE_DIR/lock"; exit 1; }
request(){
 local method="$1" path="$2" payload="${3:-}" response
 local -a args=(--silent --show-error --connect-timeout 8 --max-time 30 -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' -X "$method" -w $'\n%{http_code}')
 [[ -z "$payload" ]] || args+=(--data "$payload")
 response="$(curl "${args[@]}" "$API$path")" || return 1
 STATUS="${response##*$'\n'}"; BODY="${response%$'\n'*}"
 [[ "$STATUS" =~ ^[0-9]{3}$ ]] && jq -e 'type=="object"' >/dev/null <<<"$BODY"
}
list_records(){
 local family="$1" page=1 pages=1 chunk
 RECORDS='[]'
 while (( page <= pages )); do
   request GET "/zones/$ZONE_ID/dns_records?type=$family&name=$DNS_NAME&match=all&per_page=100&page=$page" || return 1
   [[ "$STATUS" == 200 ]] && jq -e '.success==true and (.result|type=="array")' >/dev/null <<<"$BODY" || return 1
   pages="$(jq -r '.result_info.total_pages // 1' <<<"$BODY")"
   [[ "$pages" =~ ^[0-9]+$ ]] && (( pages <= 100 )) || return 1
   chunk="$(jq -c --arg family "$family" --arg name "${DNS_NAME%.}" '[.result[] | select(.type==$family and (.name|ascii_downcase)==($name|ascii_downcase))]' <<<"$BODY")"
   RECORDS="$(jq -cn --argjson a "$RECORDS" --argjson b "$chunk" '$a+$b')"
   ((page+=1))
 done
 # Explicit, deterministic ordering: creation time ascending, then ID ascending.
 RECORDS="$(jq -c 'sort_by(.created_on // "", .id)' <<<"$RECORDS")"
}
get_ip(){ if [[ "$1" == A ]]; then curl -4fsS --connect-timeout 5 --max-time 12 https://api4.ipify.org; else curl -6fsS --connect-timeout 5 --max-time 12 https://api6.ipify.org; fi; }
valid_ip(){ if [[ "$1" == A ]]; then [[ "$2" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local p; IFS=. read -ra parts <<<"$2"; for p in "${parts[@]}"; do (( 10#$p <= 255 )) || return 1; done; else [[ "$2" == *:* && "$2" != '::1' && "${2,,}" != fe80:* && "${2,,}" != fc* && "${2,,}" != fd* ]]; fi; }
update_family(){
 local family="$1" index="$2" ip count state id record current payload chosen_id
 (( 10#$index > 0 )) || return 0
 ip="$(get_ip "$family")" && valid_ip "$family" "$ip" || { log "WARN: no valid public $family address"; return 0; }
 list_records "$family" || { log "ERROR: cannot list $family records"; return 1; }
 count="$(jq 'length' <<<"$RECORDS")"
 state="$STATE_DIR/${DNS_NAME//\//_}.$family.index$index.id"
 if [[ -s "$state" ]]; then
   id="$(cat "$state")"
   record="$(jq -c --arg id "$id" '.[]|select(.id==$id)' <<<"$RECORDS")"
   if [[ -z "$record" ]]; then log "ERROR: pinned $family record $id missing; refusing to switch targets automatically. Remove $state manually to reselect."; return 1; fi
 elif (( count == 0 )); then
   [[ "$AUTO_CREATE" == true ]] || { log "ERROR: no $family records"; return 1; }
   (( 10#$index == 1 )) || { log "ERROR: cannot create record at index $index when list is empty; only index 1 supports creation"; return 1; }
   payload="$(jq -nc --arg name "${DNS_NAME%.}" --arg type "$family" --arg ip "$ip" --argjson proxied "$NEW_RECORD_PROXIED" --argjson ttl "$NEW_RECORD_TTL" '{name:$name,type:$type,content:$ip,proxied:$proxied,ttl:$ttl}')"
   request POST "/zones/$ZONE_ID/dns_records" "$payload" || return 1
   [[ "$STATUS" == 200 || "$STATUS" == 201 ]] && jq -e '.success==true and (.result.id|type=="string")' >/dev/null <<<"$BODY" || return 1
   id="$(jq -r '.result.id' <<<"$BODY")"; printf '%s\n' "$id" >"$state"; chmod 600 "$state"
   log "Created $family $DNS_NAME -> $ip; pinned ID $id"; return 0
 else
   (( 10#$index <= count )) || { log "ERROR: requested $family index $index but only $count records exist"; return 1; }
   record="$(jq -c --argjson i "$((10#$index - 1))" '.[$i]' <<<"$RECORDS")"
   id="$(jq -r '.id' <<<"$record")"
   # Pin before updating so transient API failures cannot cause a different target to be selected.
   printf '%s\n' "$id" >"$state"; chmod 600 "$state"
   log "Selected $family index $index of $count; pinned ID $id"
 fi
 current="$(jq -r '.content' <<<"$record")"
 [[ "$current" != "$ip" ]] || { log "$family unchanged: $ip (ID $id)"; return 0; }
 payload="$(jq -nc --arg ip "$ip" '{content:$ip}')"
 request PATCH "/zones/$ZONE_ID/dns_records/$id" "$payload" || return 1
 [[ "$STATUS" == 200 ]] && jq -e --arg ip "$ip" '.success==true and .result.content==$ip' >/dev/null <<<"$BODY" || return 1
 log "Updated $family: $current -> $ip (ID $id)"
}
if [[ "$MODE" == --install ]]; then
 script="$STATE_DIR/ddns.sh"
 config_tmp="$(mktemp "$STATE_DIR/config.XXXXXX")"
 trap 'rm -f -- "$config_tmp"' EXIT
 for name in CF_TOKEN ZONE_ID DNS_NAME A_RECORD_INDEX AAAA_RECORD_INDEX AUTO_CREATE CRON_INTERVAL NEW_RECORD_PROXIED NEW_RECORD_TTL; do
  printf '%s=%q\n' "$name" "${!name}"
 done >"$config_tmp"
 chmod 600 "$config_tmp"
 mv -f -- "$config_tmp" "$CONFIG_FILE"
 trap - EXIT
 if [[ "$(readlink -f "$0")" != "$(readlink -m "$script")" ]]; then
  install -m 700 "$(readlink -f "$0")" "$script"
 fi
 chmod 700 "$script"
 marker="# cloudflare-ddns-index:$STATE_DIR"
 line="*/$CRON_INTERVAL * * * * /usr/bin/flock -n $STATE_DIR/cron.lock /bin/bash $script --run >> $STATE_DIR/ddns.log 2>&1 $marker"
 { crontab -l 2>/dev/null | grep -Fv "$marker" || true; printf '%s\n' "$line"; } | crontab -
 if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
  # Do not let a background service inherit the DDNS lock.
  systemctl enable --now cron 9>&- || fail '定时任务已保存，但 cron 启动失败，请检查服务'
 else
  service cron start 9>&- || fail '定时任务已保存，但 cron 启动失败，请检查服务'
 fi
 log "安装完成：每 $CRON_INTERVAL 分钟更新；配置 $CONFIG_FILE；日志 $STATE_DIR/ddns.log"
 log '现在执行首次更新。'
fi
failed=0
update_family A "$A_RECORD_INDEX" || failed=1
update_family AAAA "$AAAA_RECORD_INDEX" || failed=1
exit "$failed"
