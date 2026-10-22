if (du -s -BG --threshold=1G ./.zig-cache 2>/dev/null | grep -q .); then
    echo "Cache is larger than 1G, clearing..."
    rm -rf .zig-cache
fi
exit 0
