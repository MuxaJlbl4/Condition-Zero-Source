#!/bin/bash

# ============================================================
#  Installer.sh - Condition Zero: Source installer
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_info()   { echo -e "${CYAN}[INFO]${NC}  $1"; }
print_ok()     { echo -e "${GREEN}[OK]${NC}    $1"; }
print_error()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# 1. Argument validation
# ============================================================
echo -e "\n${BOLD}==> Argument validation${NC}"

if [ -z "$1" ]; then
    print_error "Installation path not provided."
    echo "Usage: $0 <path/to/cstrike>"
    exit 1
fi

# Normalize: strip trailing slash or backslash
INSTALL_DIR="${1%/}"
INSTALL_DIR="${INSTALL_DIR%\\}"

BASENAME="$(basename "$INSTALL_DIR")"

if [ "$BASENAME" != "cstrike" ]; then
    print_error "The target folder must be named 'cstrike', got '$BASENAME' instead."
    echo "Example: $0 \"/home/user/.local/share/Steam/steamapps/common/Counter-Strike Source/cstrike/\""
    exit 1
fi

print_ok "Path is valid: $INSTALL_DIR"

if [ ! -d "$INSTALL_DIR" ]; then
    print_error "Directory '$INSTALL_DIR' does not exist. Please create it first."
    exit 1
fi

print_ok "Directory exists."

# ============================================================
# 2. Download Metamod Source
# ============================================================
echo -e "\n${BOLD}==> Downloading Metamod Source (master)${NC}"

MM_PAGE="https://www.sourcemm.net/downloads.php/?branch=master"
print_info "Fetching Metamod Source download page..."

MM_URL=$(curl -fsSL "$MM_PAGE" \
    | grep -oP 'https://[^"]+mmsource[^"]+linux\.tar\.gz' \
    | head -n 1)

if [ -z "$MM_URL" ]; then
    MM_URL=$(curl -fsSL "$MM_PAGE" \
        | grep -oP 'href="([^"]+\.tar\.gz)"' \
        | grep -i linux \
        | head -n 1 \
        | grep -oP '"([^"]+)"' \
        | tr -d '"')
fi

if [ -z "$MM_URL" ]; then
    print_error "Could not find a Metamod Source download link. Check your internet connection or the site availability."
    exit 1
fi

print_info "Found URL: $MM_URL"
MM_FILE="$INSTALL_DIR/$(basename "$MM_URL")"

print_info "Downloading $(basename "$MM_URL")..."
if curl -fL --progress-bar -o "$MM_FILE" "$MM_URL"; then
    print_ok "Metamod Source downloaded successfully → $(basename "$MM_FILE")"
else
    print_error "Failed to download Metamod Source."
    exit 1
fi

# ============================================================
# 3. Download SourceMod
# ============================================================
echo -e "\n${BOLD}==> Downloading SourceMod (dev)${NC}"

SM_PAGE="https://www.sourcemod.net/downloads.php?branch=dev"
print_info "Fetching SourceMod download page..."

SM_URL=$(curl -fsSL "$SM_PAGE" \
    | grep -oP 'https://[^"]+sourcemod[^"]+linux\.tar\.gz' \
    | head -n 1)

if [ -z "$SM_URL" ]; then
    SM_URL=$(curl -fsSL "$SM_PAGE" \
        | grep -oP 'href="([^"]+\.tar\.gz)"' \
        | grep -i linux \
        | head -n 1 \
        | grep -oP '"([^"]+)"' \
        | tr -d '"')
fi

if [ -z "$SM_URL" ]; then
    print_error "Could not find a SourceMod download link. Check your internet connection or the site availability."
    exit 1
fi

print_info "Found URL: $SM_URL"
SM_FILE="$INSTALL_DIR/$(basename "$SM_URL")"

print_info "Downloading $(basename "$SM_URL")..."
if curl -fL --progress-bar -o "$SM_FILE" "$SM_URL"; then
    print_ok "SourceMod downloaded successfully → $(basename "$SM_FILE")"
else
    print_error "Failed to download SourceMod."
    exit 1
fi

# ============================================================
# 4. Extract archives
# ============================================================
echo -e "\n${BOLD}==> Extracting archives${NC}"

print_info "Extracting Metamod Source..."
if tar -xzf "$MM_FILE" -C "$INSTALL_DIR"; then
    print_ok "Metamod Source extracted successfully into '$INSTALL_DIR'."
else
    print_error "Failed to extract Metamod Source."
    exit 1
fi

print_info "Extracting SourceMod..."
if tar -xzf "$SM_FILE" -C "$INSTALL_DIR"; then
    print_ok "SourceMod extracted successfully into '$INSTALL_DIR'."
else
    print_error "Failed to extract SourceMod."
    exit 1
fi

# ============================================================
# 5. Remove downloaded archives
# ============================================================
echo -e "\n${BOLD}==> Cleanup${NC}"

rm -f "$MM_FILE" && print_ok "Removed archive: $(basename "$MM_FILE")"
rm -f "$SM_FILE" && print_ok "Removed archive: $(basename "$SM_FILE")"

# ============================================================
# 6. Copy Resources → cstrike/custom/condition_zero
# ============================================================
echo -e "\n${BOLD}==> Copying Resources${NC}"
 
RESOURCES_SRC="$SCRIPT_DIR/Resources"
CUSTOM_DIR="$INSTALL_DIR/custom"
CZ_DIR="$CUSTOM_DIR/condition_zero"
 
if [ ! -d "$RESOURCES_SRC" ]; then
    print_error "Resources folder not found at '$RESOURCES_SRC'. Skipping."
else
    if [ ! -d "$CZ_DIR" ]; then
        print_info "Directory '$CZ_DIR' does not exist — creating..."
        mkdir -p "$CZ_DIR" || { print_error "Failed to create '$CZ_DIR'."; exit 1; }
        print_ok "Directory '$CZ_DIR' created."
    fi
 
    print_info "Copying Resources/ → $CZ_DIR ..."
    if cp -r "$RESOURCES_SRC"/. "$CZ_DIR/"; then
        print_ok "Resources copied successfully into '$CZ_DIR'."
    else
        print_error "Failed to copy Resources."
        exit 1
    fi
fi

# ============================================================
# 7. Copy plugin folders → cstrike
# ============================================================
echo -e "\n${BOLD}==> Copying Plugins${NC}"

for PLUGIN_SUBDIR in "bot2player" "condition-zero"; do
    PLUGIN_SRC="$SCRIPT_DIR/Plugins/$PLUGIN_SUBDIR"

    if [ ! -d "$PLUGIN_SRC" ]; then
        print_error "Plugin folder not found: '$PLUGIN_SRC'. Skipping."
        continue
    fi

    print_info "Copying Plugins/$PLUGIN_SUBDIR/ → $INSTALL_DIR ..."
    if cp -r "$PLUGIN_SRC"/. "$INSTALL_DIR/"; then
        print_ok "Plugins/$PLUGIN_SUBDIR copied successfully into '$INSTALL_DIR'."
    else
        print_error "Failed to copy Plugins/$PLUGIN_SUBDIR."
        exit 1
    fi
done

# ============================================================
# 8. Done
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}============================================${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
echo -e "${GREEN}${BOLD}  Install directory: $INSTALL_DIR${NC}"
echo -e "${YELLOW}${BOLD}  Run the game with argument: -insecure"
echo -e "${GREEN}${BOLD}============================================${NC}"
echo ""
