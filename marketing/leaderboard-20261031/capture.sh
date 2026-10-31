#!/bin/bash
# Re-capture the real UI. Pass an isolated, booted simulator with a Debug build installed.
# Nothing here writes to Supabase. Do not run against a physical device.
set -euo pipefail
simulator_id="${1:?Usage: capture.sh SIMULATOR_UDID}"
media_dir="$(cd "$(dirname "$0")" && pwd)"
app_data="$(xcrun simctl get_app_container "$simulator_id" com.juggledude data)"
mkdir -p "$app_data/Documents/StorefrontPortraits" "$media_dir/screens"
cp "$media_dir"/sources/portraits/*.png "$app_data/Documents/StorefrontPortraits/"
xcrun simctl status_bar "$simulator_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
for language in en de fr es pt-BR; do
  case "$language" in
    en) region=en_US ;;
    de) region=de_DE ;;
    fr) region=fr_FR ;;
    es) region=es_ES ;;
    pt-BR) region=pt_BR ;;
  esac
  xcrun simctl launch --terminate-running-process "$simulator_id" com.juggledude --session-design leaderboard --leaderboard-preview storefront -AppleLanguages "($language)" -AppleLocale "$region"
  # Let the real pennant entrance animation settle before taking a still.
  sleep 4
  xcrun simctl io "$simulator_id" screenshot "$media_dir/screens/$language.png"
done
xcrun swiftc "$media_dir/render.swift" -o "$media_dir/render"
"$media_dir/render" "$media_dir"
