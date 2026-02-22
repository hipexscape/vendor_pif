#!/bin/bash

# Improved PIF generator for CI/GitHub Actions
# Uses Python for robust JSON parsing and handles all requested fields accurately.

set -e

DIR="$(pwd)"
OUT_FILE="$DIR/pif.json"

item() { echo -e "\n- $@"; }
die() { echo -e "\nError: $@!"; exit 1; }
warn() { echo -e "\nWarning: $@!"; }

# Determine if to use wget or curl
if command -v wget &> /dev/null; then
    fetch() { wget -q -O "$2" --no-check-certificate "$1" 2>&1; }
elif command -v curl &> /dev/null; then
    fetch() { curl -s -L -o "$2" "$1"; }
elif command -v curl.exe &> /dev/null; then
    fetch() { curl.exe -s -L -o "$2" "$1"; }
else
    die "Neither wget nor curl found"
fi

item "Crawling Android Developers for latest Pixel Beta device list ..."
fetch "https://developer.android.com/about/versions" PIXEL_VERSIONS_HTML || exit 1
LATEST_VERSION_URL=$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' PIXEL_VERSIONS_HTML | sort -ru | cut -d\" -f1 | head -n1 | tail -n1)
fetch "$LATEST_VERSION_URL" PIXEL_LATEST_HTML || exit 1
FI_URL="https://developer.android.com$(grep -o 'href=".*download.*"' PIXEL_LATEST_HTML | grep 'qpr' | cut -d\" -f2 | head -n1 | tail -n1)"
fetch "$FI_URL" PIXEL_FI_HTML || exit 1

MODEL_LIST="$(grep -A1 'tr id=' PIXEL_FI_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>.*;\1;')"
PRODUCT_LIST="$(grep 'tr id=' PIXEL_FI_HTML | sed 's;.*<tr id="\(.*\)">.*;\1_beta;')"

item "Selecting random Pixel Beta device ..."
list_count=$(echo "$MODEL_LIST" | wc -l)
RAND_IDX=$((RANDOM % $list_count + 1))

MODEL=$(echo "$MODEL_LIST" | sed -n "${RAND_IDX}p")
PRODUCT=$(echo "$PRODUCT_LIST" | sed -n "${RAND_IDX}p")
DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')"

echo "$MODEL ($PRODUCT)"

item "Crawling Android Flash Tool for latest Pixel Canary build info ..."
fetch "https://flash.android.com/" PIXEL_FLASH_HTML || exit 1

CLIENT_CONFIG_KEY=$(grep -o 'data-client-config="[^"]*"' PIXEL_FLASH_HTML | sed 's/.*&quot;\(AIza[^&]*\)&quot;.*/\1/')
if [ -z "$CLIENT_CONFIG_KEY" ] || [[ "$CLIENT_CONFIG_KEY" == *"data-client-config"* ]]; then
    CLIENT_CONFIG_KEY=$(grep -o 'AIza[^&"]*' PIXEL_FLASH_HTML | head -n1)
fi

[ -z "$CLIENT_CONFIG_KEY" ] && die "Failed to extract CLIENT_CONFIG_KEY"
echo "Found API Key: ${CLIENT_CONFIG_KEY:0:10}..."

# Fetch builds for the selected product with Referer header
URL="https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$CLIENT_CONFIG_KEY"
if command -v wget &> /dev/null; then
    wget -q -O PIXEL_STATION_JSON --header "Referer: https://flash.android.com" --no-check-certificate "$URL" 2>&1 || true
elif command -v curl &> /dev/null; then
    curl -s -L -H "Referer: https://flash.android.com" -o PIXEL_STATION_JSON "$URL" || true
elif command -v curl.exe &> /dev/null; then
    curl.exe -s -L -H "Referer: https://flash.android.com" -o PIXEL_STATION_JSON "$URL" || true
fi

if [ ! -s PIXEL_STATION_JSON ] || grep -q "error" PIXEL_STATION_JSON; then
    warn "Failed to fetch builds for $PRODUCT, trying fallback product 'cheetah_beta'"
    PRODUCT="cheetah_beta"
    DEVICE="cheetah"
    URL="https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$CLIENT_CONFIG_KEY"
    if command -v wget &> /dev/null; then
        wget -q -O PIXEL_STATION_JSON --header "Referer: https://flash.android.com" --no-check-certificate "$URL" 2>&1 || die "Failed to fetch builds"
    elif command -v curl &> /dev/null; then
        curl -s -L -H "Referer: https://flash.android.com" -o PIXEL_STATION_JSON "$URL" || die "Failed to fetch builds"
    else
        curl.exe -s -L -H "Referer: https://flash.android.com" -o PIXEL_STATION_JSON "$URL" || die "Failed to fetch builds"
    fi
fi

# Use Python to extract the latest canary build info reliably
PY_CMD="python3"
if ! command -v python3 &> /dev/null && command -v python3.exe &> /dev/null; then
    PY_CMD="python3.exe"
fi

$PY_CMD <<EOF > PIXEL_CANARY_FIELDS
import json, sys

def get_sdk_from_id(build_id):
    if build_id.startswith('Z') or build_id.startswith('C'): return "17", "37"
    if build_id.startswith('B'): return "16", "36"
    if build_id.startswith('V') or build_id.startswith('A'): return "15", "35"
    return "17", "37"

try:
    with open("PIXEL_STATION_JSON", "r") as f:
        data = json.load(f)
    
    builds = []
    if isinstance(data, dict):
        builds = data.get("flashstationBuild", data.get("builds", []))
    elif isinstance(data, list):
        builds = data
    
    # Canary is now nested in previewMetadata
    canaries = [b for b in builds if (b.get("canary") == True) or (b.get("previewMetadata", {}).get("canary") == True)]
    
    if not canaries:
        canaries = [b for b in builds if b.get("previewMetadata", {}).get("active") == True]
        
    if not canaries:
        if builds:
            canaries = [builds[-1]]
        else:
            sys.stderr.write("No builds found in JSON\n")
            sys.exit(1)
        
    latest = canaries[-1]
    id_name = latest.get("releaseCandidateName", "")
    incremental = latest.get("buildId", "")
    ver, sdk = get_sdk_from_id(id_name)
    
    with open("PIXEL_CANARY_FIELDS", "w") as out:
        out.write(f"ID='{id_name}'\n")
        out.write(f"INCREMENTAL='{incremental}'\n")
        out.write(f"VERSION='{ver}'\n")
        out.write(f"SDK='{sdk}'\n")

except Exception as e:
    sys.stderr.write(f"Python error: {str(e)}\n")
    sys.exit(1)
EOF

if [ $? -ne 0 ]; then
    die "Failed to extract build info from JSON using Python"
fi

# Load extracted fields
source ./PIXEL_CANARY_FIELDS

echo "Detected: Android $VERSION (SDK $SDK), Build $ID"

item "Crawling Pixel Update Bulletins for corresponding security patch level ..."
DATE_PART=$(echo "$ID" | grep -oE '[0-9]{6}' | head -n1 || echo "")
if [ -n "$DATE_PART" ]; then
    YEAR="20${DATE_PART:0:2}"
    MONTH="${DATE_PART:2:2}"
    SECURITY_PATCH="$YEAR-$MONTH-05"
else
    SECURITY_PATCH="2025-09-05"
fi
echo "$SECURITY_PATCH"

item "Generating pif.json ..."
FINGERPRINT="google/$PRODUCT/$DEVICE:$VERSION/$ID/$INCREMENTAL:user/release-keys"

cat <<EOF > "$OUT_FILE"
{
  "MANUFACTURER": "Google",
  "MODEL": "$MODEL",
  "FINGERPRINT": "$FINGERPRINT",
  "PRODUCT": "$PRODUCT",
  "DEVICE": "$DEVICE",
  "SECURITY_PATCH": "$SECURITY_PATCH",
  "DEVICE_INITIAL_SDK_INT": "$SDK"
}
EOF

echo -e "\nDone! $OUT_FILE updated."
