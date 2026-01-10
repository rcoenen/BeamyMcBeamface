#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="Beamy McBeamface"
APP_PATH=".build/DerivedData/Build/Products/Release/${APP_NAME}.app"
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')
DMG_NAME="BeamyMcBeamface-v${VERSION}.dmg"
VOLUME_NAME="${APP_NAME}"
BACKDROP="assets/dmg-backdrop-600x400.png"

echo -e "${YELLOW}Creating DMG for ${APP_NAME} v${VERSION}...${NC}"

# Check app exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: App not found at ${APP_PATH}${NC}"
    echo "Run ./scripts/build-app.sh first"
    exit 1
fi

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
    echo -e "${RED}Error: create-dmg not found. Install with: brew install create-dmg${NC}"
    exit 1
fi

# Check backdrop exists
if [ ! -f "$BACKDROP" ]; then
    echo -e "${RED}Error: Backdrop not found at ${BACKDROP}${NC}"
    exit 1
fi

# Remove old DMG if exists
rm -f "$DMG_NAME"

# Create DMG with create-dmg
echo -e "${YELLOW}Running create-dmg...${NC}"
create-dmg \
    --volname "$VOLUME_NAME" \
    --background "$BACKDROP" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --text-size 14 \
    --icon "$APP_NAME.app" 150 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 450 200 \
    --no-internet-enable \
    --format UDBZ \
    "$DMG_NAME" \
    "$APP_PATH"

echo -e "${GREEN}DMG created: ${DMG_NAME}${NC}"
ls -lh "$DMG_NAME"
