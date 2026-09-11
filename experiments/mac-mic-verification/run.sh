#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
pip3 install -r requirements.txt --quiet
python3 verify.py "$@"
