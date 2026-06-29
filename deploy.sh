#!/bin/bash
# Committa och pusha repots egen index.html direkt
cd ~/Downloads/gastro-research
git add index.html
git commit -m "${1:-Deploy}"
git push
