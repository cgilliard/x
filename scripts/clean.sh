#!/bin/sh
# scripts/clean.sh -- remove everything scripts/build.sh made in bin/.

# to the repository's root, from wherever this is run; stop if that fails,
# so nothing is removed anywhere else
case $0 in */*) cd "${0%/*}/.." ;; *) cd .. ;; esac || exit 1
[ -f fam0.seed ] && [ -d bin ] || { echo "clean.sh: not in the repository" >&2; exit 1; }

rm -rf bin/*
