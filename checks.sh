#!/bin/bash

# checks.sh - Quality checks for meshtastic.el
# Usage: ./checks.sh

set -e

OVERALL_STATUS=0

echo "=== MESHTASTIC.EL QUALITY CHECKS ==="
echo ""

# 1. checkdoc
echo "[1/5] Running checkdoc..."
emacs --batch \
      --eval "(progn (require 'checkdoc) (checkdoc-file \"meshtastic.el\"))" 2>&1
echo "✓ Checkdoc completed"
echo ""

# 2. package-lint
echo "[2/5] Running package-lint..."
emacs --batch \
      --eval "(require 'package)" \
      --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t)" \
      --eval "(package-initialize)" \
      --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
      --eval "(require 'package-lint)" \
      -f package-lint-batch-and-exit meshtastic.el 2>&1
echo "✓ Package-lint completed"
echo ""

# 3. melpazoid
echo "[3/5] Running melpazoid..."
if command -v docker >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    if [ ! -d "melpazoid" ]; then
        echo "  Cloning melpazoid..."
        git clone https://github.com/riscy/melpazoid.git 2>&1 | grep -v "Cloning" || true
    fi
    RECIPE='(meshtastic :fetcher github :repo "androsfenollosa/meshtastic.el" :files ("meshtastic.el" "meshtastic-bridge.py"))'
    if RECIPE="$RECIPE" LOCAL_REPO="$(pwd)" make -C melpazoid 2>&1; then
        echo "✓ Melpazoid completed"
    else
        echo "⚠ Melpazoid had warnings or errors"
        OVERALL_STATUS=1
    fi
else
    echo "⚠ docker or python3 not found, skipping melpazoid"
fi
echo ""

# 4. Format
echo "[4/5] Formatting meshtastic.el..."
if emacs --batch meshtastic.el \
         --eval "(progn (emacs-lisp-mode) (indent-region (point-min) (point-max)) (save-buffer))" 2>&1 \
         | grep -q "error"; then
    echo "✗ Formatting failed"
    OVERALL_STATUS=1
else
    echo "✓ Formatted"
fi
echo ""

# 5. Compile
echo "[5/5] Compiling meshtastic.el..."
if emacs --batch -L . \
         --eval "(setq byte-compile-error-on-warn nil)" \
         -f batch-byte-compile meshtastic.el 2>&1 \
         | grep -i "^meshtastic.el:[0-9]*:[0-9]*: Error"; then
    echo "✗ Compilation errors"
    OVERALL_STATUS=1
else
    echo "✓ Compiled"
fi
echo ""

echo "=== CHECKS COMPLETED ==="
if [ $OVERALL_STATUS -eq 0 ]; then
    echo "✓ All checks passed!"
else
    echo "✗ Some checks failed"
fi

exit $OVERALL_STATUS
