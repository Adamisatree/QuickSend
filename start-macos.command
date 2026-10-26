#!/bin/bash
cd "$(dirname "$0")"
if ! command -v node >/dev/null 2>&1; then
  echo "Please install Node.js 20 or newer, then run this file again."
  read -r -p "Press Enter to close..."
  exit 1
fi
if [ ! -d node_modules ]; then
  echo "Installing QuickSend dependencies..."
  npm install || { read -r -p "Install failed. Press Enter to close..."; exit 1; }
fi
npm start
read -r -p "Press Enter to close..."
