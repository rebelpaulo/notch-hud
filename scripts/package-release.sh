#!/bin/sh

# Produces the three signed assets required by vibenotch-update:
#   Vibenotch-X.Y.Z.tar.gz
#   Vibenotch-X.Y.Z.tar.gz.sha256
#   Vibenotch-X.Y.Z.tar.gz.sha256.sig

set -eu

tag=${1:-}
if ! printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "usage: scripts/package-release.sh v1.2.3" >&2
    exit 64
fi

script_dir=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd) || exit 1
repo_root=$(CDPATH= cd -P "$script_dir/.." 2>/dev/null && pwd) || exit 1
version=${tag#v}
private_key=${VIBENOTCH_RELEASE_SIGNING_KEY:-"$HOME/Library/Application Support/Vibenotch/release-signing-private.pem"}
public_key=$script_dir/release-signing-public.pem
output_root=${VIBENOTCH_RELEASE_OUTPUT_DIR:-"$repo_root/dist"}
release_dir=$output_root/$tag

[ -f "$private_key" ] || {
    printf '%s\n' "vibenotch-release: signing key not found: $private_key" >&2
    exit 1
}
key_mode=$(/usr/bin/stat -f '%Lp' "$private_key")
case $key_mode in
    400|600) ;;
    *)
        printf '%s\n' "vibenotch-release: signing key permissions must be 400 or 600 (found $key_mode)" >&2
        exit 1
        ;;
esac
[ -f "$public_key" ] || {
    printf '%s\n' "vibenotch-release: trusted public key is missing" >&2
    exit 1
}
[ ! -e "$release_dir" ] || {
    printf '%s\n' "vibenotch-release: output already exists: $release_dir" >&2
    exit 1
}

if [ -n "$(/usr/bin/git -C "$repo_root" status --porcelain)" ]; then
    printf '%s\n' "vibenotch-release: the worktree must be clean" >&2
    exit 1
fi

head_commit=$(/usr/bin/git -C "$repo_root" rev-parse HEAD)
tag_commit=$(/usr/bin/git -C "$repo_root" rev-parse "$tag^{commit}" 2>/dev/null) || {
    printf '%s\n' "vibenotch-release: tag does not exist: $tag" >&2
    exit 1
}
[ "$head_commit" = "$tag_commit" ] || {
    printf '%s\n' "vibenotch-release: $tag does not point at HEAD" >&2
    exit 1
}

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Sources/Vibenotch/Info.plist")
[ "$plist_version" = "$version" ] || {
    printf '%s\n' "vibenotch-release: Info.plist is $plist_version, expected $version" >&2
    exit 1
}
if ! /usr/bin/grep -Fq \
    "<key>CFBundleShortVersionString</key><string>$version</string>" \
    "$repo_root/scripts/make-app.sh"; then
    printf '%s\n' "vibenotch-release: scripts/make-app.sh does not bundle version $version" >&2
    exit 1
fi

staging=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vibenotch-release.XXXXXX") || exit 1
cleanup() {
    [ -z "${staging:-}" ] || /bin/rm -rf -- "$staging"
}
trap cleanup EXIT HUP INT TERM

derived_public=$staging/derived-public.pem
/usr/bin/openssl pkey -in "$private_key" -pubout -out "$derived_public" >/dev/null 2>&1
if ! /usr/bin/cmp -s "$derived_public" "$public_key"; then
    printf '%s\n' "vibenotch-release: signing key does not match the trusted public key" >&2
    exit 1
fi

archive_name=Vibenotch-$version.tar.gz
manifest_name=$archive_name.sha256
signature_name=$manifest_name.sig
archive=$staging/$archive_name
manifest=$staging/$manifest_name
signature=$staging/$signature_name

/usr/bin/git -C "$repo_root" archive \
    --format=tar.gz \
    --prefix="notch-hud-$version/" \
    --output="$archive" \
    "$tag"
(
    cd "$staging"
    /usr/bin/shasum -a 256 "$archive_name" > "$manifest_name"
)
/usr/bin/openssl dgst -sha256 -sign "$private_key" -out "$signature" "$manifest"
/usr/bin/openssl dgst -sha256 -verify "$public_key" \
    -signature "$signature" "$manifest" >/dev/null

/bin/mkdir -p "$output_root"
/bin/mv "$staging" "$release_dir"
staging=

printf '%s\n' "Signed release assets created in $release_dir:"
printf '  %s\n' "$archive_name" "$manifest_name" "$signature_name"
