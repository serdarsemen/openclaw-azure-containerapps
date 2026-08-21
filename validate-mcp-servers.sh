#!/bin/bash
#
# MCP Server Validation Script
# Comprehensive test suite for all MCP servers in the openclaw-azure-containerapps project
#
# Usage: bash validate-mcp-servers.sh [--verbose] [--fix-symlinks]
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

VERBOSE=false
FIX_SYMLINKS=false
UPGRADE_OLLAMA_OLD=false
FAILED_CHECKS=0
PASSED_CHECKS=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose) VERBOSE=true; shift ;;
    --fix-symlinks) FIX_SYMLINKS=true; shift ;;
    --upgrade-ollama-old) UPGRADE_OLLAMA_OLD=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Helper functions
print_header() {
  echo -e "${CYAN}=== $1 ===${NC}"
}

print_success() {
  echo -e "${GREEN}✅ $1${NC}"
  ((PASSED_CHECKS++))
}

print_error() {
  echo -e "${RED}❌ $1${NC}"
  ((FAILED_CHECKS++))
}

print_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
  echo -e "${CYAN}ℹ️  $1${NC}"
}

print_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "   $1"
  fi
}

normalize_semver() {
  local raw=${1:-}
  raw=$(echo "$raw" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
  raw=${raw#v}
  if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

version_lt() {
  local left=$1
  local right=$2
  [ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n1)" != "$right" ]
}

get_latest_ollama_version() {
  local payload tag
  if ! payload=$(curl -fsSL --max-time 8 "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null); then
    echo ""
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    tag=$(echo "$payload" | jq -r '.tag_name // empty' 2>/dev/null || true)
  else
    tag=$(echo "$payload" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  fi

  if [ -z "$tag" ]; then
    echo ""
    return 1
  fi

  normalize_semver "$tag"
}

get_wsl_ollama_version() {
  if ! command -v ollama >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  local out
  out=$(ollama --version 2>/dev/null | head -n1 || true)
  normalize_semver "$out"
}

get_windows_ollama_version() {
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo ""
    return 1
  fi

  local out
  out=$(powershell.exe -NoProfile -Command "& {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
      (ollama --version | Select-Object -First 1)
    }
  }" 2>/dev/null | tr -d '\r' | head -n1 || true)
  normalize_semver "$out"
}

print_wsl_ollama_upgrade_guidance() {
  echo "  WSL Ollama upgrade steps:"
  echo "    curl -fsSL https://ollama.com/install.sh | sh"
  echo "    ollama --version"
  echo "    pkill -f \"ollama serve\" || true"
  echo "    export OLLAMA_HOST=0.0.0.0:11434"
  echo "    nohup ollama serve >/dev/null 2>&1 &"
}

print_windows_ollama_upgrade_guidance() {
  echo "  Windows Ollama upgrade steps:"
  echo "    winget upgrade --id Ollama.Ollama -e"
  echo "    ollama --version"
  echo "    taskkill /IM ollama.exe /F"
  echo "    setx OLLAMA_HOST \"0.0.0.0:11434\""
  echo "    ollama serve"
}

upgrade_ollama_wsl() {
  print_info "Triggering WSL Ollama upgrade..."
  if bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'; then
    print_success "WSL Ollama upgrade completed"
    return 0
  fi
  print_error "WSL Ollama upgrade failed"
  return 1
}

upgrade_ollama_windows() {
  print_info "Triggering Windows Ollama upgrade..."
  if powershell.exe -NoProfile -Command "winget upgrade --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements" >/dev/null 2>&1; then
    print_success "Windows Ollama upgrade completed"
    return 0
  fi
  print_error "Windows Ollama upgrade failed"
  return 1
}

check_ollama_versions() {
  print_header "0. Ollama Version Health"

  local latest wsl windows
  latest=$(get_latest_ollama_version || true)
  wsl=$(get_wsl_ollama_version || true)
  windows=$(get_windows_ollama_version || true)

  if [ -z "$latest" ]; then
    print_warning "Could not determine latest Ollama version from GitHub API."
    print_info "Network access to api.github.com is required for old-version detection."
    return 0
  fi

  print_info "Latest Ollama release: $latest"

  if [ -n "$wsl" ]; then
    if version_lt "$wsl" "$latest"; then
      print_warning "WSL Ollama is old ($wsl < $latest)."
      print_wsl_ollama_upgrade_guidance
      if [ "$UPGRADE_OLLAMA_OLD" = true ]; then
        upgrade_ollama_wsl || true
      fi
    else
      print_success "WSL Ollama is current ($wsl)"
    fi
  else
    print_warning "WSL Ollama not found in PATH."
    print_wsl_ollama_upgrade_guidance
  fi

  if [ -n "$windows" ]; then
    if version_lt "$windows" "$latest"; then
      print_warning "Windows Ollama is old ($windows < $latest)."
      print_windows_ollama_upgrade_guidance
      if [ "$UPGRADE_OLLAMA_OLD" = true ]; then
        upgrade_ollama_windows || true
      fi
    else
      print_success "Windows Ollama is current ($windows)"
    fi
  else
    print_warning "Windows Ollama not detected via powershell.exe."
    print_windows_ollama_upgrade_guidance
  fi

  if [ "$UPGRADE_OLLAMA_OLD" = true ]; then
    print_info "Auto-upgrade trigger enabled via --upgrade-ollama-old"
  else
    print_info "Dry-run mode: no upgrades executed. Use --upgrade-ollama-old to trigger upgrades."
  fi
}

check_npm_package() {
  local package=$1
  local name=${2:-$package}

  if npm list -g "$package" >/dev/null 2>&1; then
    local version=$(npm list -g "$package" 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '()')
    print_success "NPM package $name installed (version: $version)"
    print_verbose "  npm list -g $package"
    return 0
  else
    print_error "NPM package $name NOT installed"
    print_verbose "  npm list -g $package"
    return 1
  fi
}

check_executable() {
  local cmd=$1

  if command -v "$cmd" &>/dev/null; then
    local path=$(which "$cmd")
    print_success "Executable '$cmd' found at $path"
    print_verbose "  which $cmd → $path"

    # Try to get version
    if "$cmd" --version >/dev/null 2>&1; then
      local version=$("$cmd" --version 2>&1 | head -1)
      print_verbose "  $cmd --version → $version"
    fi
    return 0
  else
    print_error "Executable '$cmd' NOT found in PATH"
    return 1
  fi
}

check_symlink() {
  local source=$1
  local target=$2

  if [ -L "$target" ]; then
    local resolved=$(readlink -f "$target")
    print_success "Symlink $target → $resolved"
    print_verbose "  ls -la $target"
    return 0
  else
    print_error "Symlink $target does NOT exist"
    print_verbose "  ls -la $target"
    return 1
  fi
}

create_symlinks() {
  local npm_bin="$HOME/.openclaw/npm-global/bin"
  local local_bin="$HOME/.local/node_modules/.bin"

  mkdir -p "$local_bin"

  for cmd in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do
    if [ -x "$npm_bin/$cmd" ]; then
      ln -sf "$npm_bin/$cmd" "$local_bin/$cmd"
      print_success "Created/updated symlink: $local_bin/$cmd"
    else
      print_warning "Cannot symlink $cmd — executable not found at $npm_bin/$cmd"
    fi
  done
}

check_service() {
  local url=$1
  local name=$2

  if curl -fs --max-time 5 "$url" >/dev/null 2>&1; then
    print_success "Service $name is reachable at $url"
    print_verbose "  curl -fs $url"
    return 0
  else
    print_warning "Service $name NOT reachable at $url (may not be running)"
    print_verbose "  curl -fs $url"
    return 1
  fi
}

check_docker_container() {
  local container_name=$1

  if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
    local image=$(docker inspect "$container_name" --format='{{.Config.Image}}' 2>/dev/null || echo "unknown")
    local status=$(docker inspect "$container_name" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    print_success "Docker container '$container_name' is running ($status)"
    print_verbose "  Image: $image"
    return 0
  else
    print_warning "Docker container '$container_name' is NOT running"
    print_verbose "  Run: docker-compose -f docker-compose-wsl.yaml up -d"
    return 1
  fi
}

# Main validation flow

print_header "MCP Server Validation"
check_ollama_versions

echo ""
print_header "1. Environment Setup"
print_info "User: $(whoami)"
print_info "Home: $HOME"
print_info "PATH: $(echo $PATH | head -c 100)..."
print_info "NPM prefix: $(npm config get prefix)"

echo ""
print_header "2. NPM Packages"
print_info "Checking if all MCP packages are installed globally..."
check_npm_package "@microsoft/learn-cli" "microsoft/learn-cli" || true
check_npm_package "@upstash/context7-mcp" "upstash/context7-mcp" || true
check_npm_package "mcp-finance" "mcp-finance" || true
check_npm_package "searxng-search" "searxng-search" || true
check_npm_package "devdocs-mcp" "devdocs-mcp" || true

echo ""
print_header "3. Executables in PATH"
print_info "Checking if all MCP executables are accessible..."
check_executable "mslearn" || true
check_executable "context7-mcp" || true
check_executable "mcp-finance-server" || true
check_executable "searxng-search" || true
check_executable "devdocs-mcp" || true

echo ""
print_header "4. Symlinks"
print_info "Checking symlinks in $HOME/.local/node_modules/.bin/ ..."
if [ -d "$HOME/.local/node_modules/.bin" ]; then
  check_symlink "$HOME/.openclaw/npm-global/bin/mslearn" "$HOME/.local/node_modules/.bin/mslearn" || true
  check_symlink "$HOME/.openclaw/npm-global/bin/context7-mcp" "$HOME/.local/node_modules/.bin/context7-mcp" || true
  check_symlink "$HOME/.openclaw/npm-global/bin/mcp-finance-server" "$HOME/.local/node_modules/.bin/mcp-finance-server" || true
  check_symlink "$HOME/.openclaw/npm-global/bin/searxng-search" "$HOME/.local/node_modules/.bin/searxng-search" || true
  check_symlink "$HOME/.openclaw/npm-global/bin/devdocs-mcp" "$HOME/.local/node_modules/.bin/devdocs-mcp" || true
else
  print_warning "Directory $HOME/.local/node_modules/.bin does not exist"
fi

echo ""
print_header "5. Service Connectivity"
print_info "Checking connectivity to service backends..."
check_service "http://127.0.0.1:6379" "Redis" || true
check_service "http://127.0.0.1:8080/healthz" "SearXNG" || true
check_service "http://127.0.0.1:3000" "CRW" || true
check_service "http://127.0.0.1:18789/healthz" "OpenClaw Gateway" || true

echo ""
print_header "6. Docker Containers"
print_info "Checking if Docker containers are running..."
check_docker_container "openclaw-redis" || true
check_docker_container "searxng" || true
check_docker_container "openclaw-crw" || true
check_docker_container "openclaw" || true

echo ""
if [ "$FIX_SYMLINKS" = true ]; then
  print_header "7. Fixing Symlinks"
  create_symlinks
fi

echo ""
print_header "Summary"
echo -e "Passed checks: ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Failed checks: ${RED}$FAILED_CHECKS${NC}"

if [ $FAILED_CHECKS -eq 0 ]; then
  echo ""
  print_success "All MCP servers are valid and properly configured!"
  exit 0
else
  echo ""
  print_error "Some checks failed. Review output above and run with --verbose for details."
  echo ""
  echo "Common fixes:"
  echo "1. Install MCP packages: npm install -g @microsoft/learn-cli @upstash/context7-mcp mcp-finance searxng-search devdocs-mcp"
  echo "2. Fix symlinks: bash validate-mcp-servers.sh --fix-symlinks"
  echo "3. Start Docker containers: docker-compose -f docker-compose-wsl.yaml up -d"
  echo "4. WSL Ollama upgrade: curl -fsSL https://ollama.com/install.sh | sh"
  echo "5. Windows Ollama upgrade: winget upgrade --id Ollama.Ollama -e"
  echo "6. Auto-trigger old-version upgrades: bash validate-mcp-servers.sh --upgrade-ollama-old"
  exit 1
fi
