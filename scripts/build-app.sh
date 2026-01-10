#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Building Beamy McBeamface...${NC}"

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo -e "${RED}Error: xcodegen not found. Install with: brew install xcodegen${NC}"
    exit 1
fi

# Generate Xcode project from YAML
echo -e "${YELLOW}Generating Xcode project...${NC}"
xcodegen generate --spec project.yml

# Build CLI
echo -e "${YELLOW}Building CLI...${NC}"
swift build -c release

# Build App
echo -e "${YELLOW}Building App...${NC}"
xcodebuild -project BeamyMcBeamface.xcodeproj \
    -scheme BeamyMcBeamface \
    -configuration Release \
    -derivedDataPath .build/DerivedData \
    build

echo -e "${GREEN}Build complete!${NC}"
echo ""
echo "CLI location: .build/release/beamy"
echo "App location: .build/DerivedData/Build/Products/Release/Beamy McBeamface.app"
echo ""
echo "To create a DMG, run: ./scripts/build-dmg.sh"
