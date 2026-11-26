#!/bin/sh
# Installs the Sarto daemon for this user, without root:
#
#   curl -fsSL https://sarto.1o.ink/releases/latest/download/install.sh | sh
#
# It downloads the package for this system from Sarto's release source, checks it against the
# checksums from the same place, unpacks it into ~/.local/share/sarto/versions/<version>, links
# ~/.local/bin/sarto to it and sets up the daemon's service. `sarto update` runs it again for a
# newer release. Pass options after `sh -s --`:
#
#   --version <version>  Install that release instead of the latest (X.Y.Z or X.Y.Z-beta.<build>)
#   --tag <tag>          Download from release folder download/<tag> (for decoupled daemon/beta tags)
#   --sha256 <hex>       Take the package only if this is its SHA-256; may be given more than once
#   --no-service         Do not set up the service, as in a container; run `sarto run` instead
#
# SARTO_RELEASES_URL names the one place to download releases from, laid out as GitHub's.
set -eu

downloads=https://sarto.1o.ink/releases
wanted=''
tag=''
pinned=''
service=1

say() { printf '%s\n' "$*"; }
fail() {
  printf 'sarto install: %s\n' "$*" >&2
  exit 1
}
is_core_version() {
  case $1 in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    *.*.*.*) return 1 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
is_version() {
  case $1 in
    *-beta.*)
      core=${1%%-beta.*}
      pre=${1#*-beta.}
      is_core_version "$core" || return 1
      case $pre in
        '' | *[!0-9]* | 0[0-9]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *)
      is_core_version "$1"
      ;;
  esac
}
is_sha256() {
  case $1 in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ ${#1} -eq 64 ]
}
is_tag() {
  case $1 in
    '' | *..* | *[!A-Za-z0-9._-]*) return 1 ;;
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case $1 in
    --version)
      [ $# -ge 2 ] || fail '--version needs a version, such as 0.1.0'
      wanted=$2
      shift 2
      ;;
    --version=*)
      wanted=${1#--version=}
      shift
      ;;
    --tag)
      [ $# -ge 2 ] || fail '--tag needs a release tag, such as daemon-v0.4.0'
      tag=$2
      shift 2
      ;;
    --tag=*)
      tag=${1#--tag=}
      shift
      ;;
    --sha256)
      [ $# -ge 2 ] || fail '--sha256 needs a SHA-256 in hexadecimal'
      is_sha256 "$2" || fail "'$2' is not a SHA-256 in lowercase hexadecimal"
      pinned="$pinned $2"
      shift 2
      ;;
    --sha256=*)
      is_sha256 "${1#--sha256=}" || fail "'${1#--sha256=}' is not a SHA-256 in lowercase hexadecimal"
      pinned="$pinned ${1#--sha256=}"
      shift
      ;;
    --no-service)
      service=0
      shift
      ;;
    -h | --help)
      sed -n '2,16s/^# \{0,1\}//p' "$0" 2>/dev/null || say 'See https://sarto.1o.ink/releases'
      exit 0
      ;;
    *) fail "Unknown option $1" ;;
  esac
done
wanted=${wanted#v}
if [ -n "$wanted" ] && ! is_version "$wanted"; then
  fail "'$wanted' is not a version, such as 0.1.0 or 0.4.0-beta.261125143512"
fi
if [ -n "$tag" ] && ! is_tag "$tag"; then
  fail "'$tag' is not a valid release tag"
fi
[ -n "${HOME:-}" ] || fail 'HOME is not set'

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail 'The Sarto daemon runs on macOS or Linux' ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) fail "The Sarto daemon has no package for $(uname -m) processors" ;;
esac
if [ "$os" = darwin ] && [ "$arch" = x64 ]; then
  # A shell under Rosetta reports x86_64 on Apple silicon.
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    arch=arm64
  else
    fail 'The Sarto daemon runs on Macs with Apple silicon'
  fi
fi
if [ "$os" = linux ]; then
  case $(ldd --version 2>&1 || true) in
    *musl*) fail 'The Sarto daemon needs glibc; systems with musl, such as Alpine, are not supported' ;;
  esac
fi

# A place that cannot be reached, or stops sending, gives way to the next one soon.
if command -v curl > /dev/null 2>&1; then
  download() {
    curl -fsSL --retry 3 --connect-timeout 10 --speed-limit 1 --speed-time 15 -o "$2" "$1"
  }
elif command -v wget > /dev/null 2>&1; then
  download() { wget -q -T 15 -O "$2" "$1"; }
else
  fail 'Downloading needs curl or wget'
fi
if command -v sha256sum > /dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum > /dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
  fail 'Checking the download needs sha256sum or shasum'
fi

share=${XDG_DATA_HOME:-}
case $share in
  /*) ;;
  *) share=$HOME/.local/share ;;
esac
versions=$share/sarto/versions
bin=$HOME/.local/bin
link=$bin/sarto

# A link of ours, or nothing: another program's sarto stays where it is.
previous=''
if [ -L "$link" ]; then
  previous=$(readlink "$link")
  case $previous in
    "$versions"/*/bin/sarto) previous=${previous%/bin/sarto} ;;
    *) fail "$link links to $previous, not to a Sarto daemon; move it and run this again" ;;
  esac
elif [ -e "$link" ]; then
  fail "$link is not the Sarto daemon's; move it and run this again"
fi

mkdir -p "$versions"
# Unpacked beside the versions, so the package moves into place with a rename.
work=$(mktemp -d "$versions/.install.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

file=sarto-daemon-$os-$arch.tar.gz
# Downloads the package and checksums from one candidate release folder, or sets why not.
fetch_from() {
  from=$1
  say "Downloading $file from $from"
  if ! download "$from/$file" "$work/$file"; then
    why="Could not download $from/$file"
    return 1
  fi
  # Checksums `sarto update` took from the release's signed manifest come before the ones beside
  # the package, which nothing signs: the package is one of them, or it is not installed.
  if [ -n "$pinned" ]; then
    actual=$(sha256 "$work/$file")
    for one in $pinned; do
      if [ "$actual" = "$one" ]; then return 0; fi
    done
    why="$file from $from is not the package its release's signed manifest names"
    return 1
  fi
  if ! download "$from/sarto-daemon-sha256sums.txt" "$work/sums"; then
    why="Could not download $from/sarto-daemon-sha256sums.txt"
    return 1
  fi
  expected=$(awk -v name="$file" '$2 == name || $2 == "*" name { print $1; exit }' "$work/sums")
  if [ -z "$expected" ]; then
    why="The checksums at $from list no $file"
    return 1
  fi
  if [ "$(sha256 "$work/$file")" != "$expected" ]; then
    why="$file from $from does not match its checksum"
    return 1
  fi
}
# Downloads the package and the checksums from one place and checks them, or sets why not.
fetch() {
  if [ -n "$tag" ]; then
    fetch_from "$1/download/$tag"
  elif [ -n "$wanted" ]; then
    fetch_from "$1/download/daemon-v$wanted" || fetch_from "$1/download/v$wanted"
  else
    fetch_from "$1/latest/download"
  fi
}
why=''
fetch "${SARTO_RELEASES_URL:-$downloads}" || fail "$why; nothing was installed"

tar -xzf "$work/$file" -C "$work"
package=$work/sarto-daemon-$os-$arch
[ -x "$package/bin/sarto" ] || fail "$file holds no bin/sarto; nothing was installed"
if ! version=$("$package/bin/sarto" --version 2>&1); then
  printf '%s\n' "$version" >&2
  if [ "$os" = linux ]; then say 'The Sarto daemon needs glibc 2.28 or later.' >&2; fi
  fail 'This computer cannot run the Sarto daemon; nothing was installed'
fi
if ! is_version "$version"; then
  fail "The package reports '$version' as its version; nothing was installed"
fi
if [ -n "$wanted" ] && [ "$version" != "$wanted" ]; then
  fail "The package for $wanted reports $version; nothing was installed"
fi

target=$versions/$version
if [ -e "$target" ]; then mv "$target" "$work/replaced"; fi
mv "$package" "$target"
mkdir -p "$bin"
ln -s "$target/bin/sarto" "$work/link"
mv -f "$work/link" "$link"

# The version before stays, to go back to; older ones go.
if [ -n "$previous" ] && [ "$previous" != "$target" ]; then
  for dir in "$versions"/*; do
    case $dir in
      "$target" | "$previous") ;;
      *) if [ -d "$dir" ]; then rm -rf "$dir"; fi ;;
    esac
  done
fi

say "Installed the Sarto daemon $version in $target"
case :$PATH: in
  *:"$bin":*) ;;
  *)
    say "$bin is not on your PATH. Add it in your shell's profile, such as ~/.profile:"
    say "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

if [ "$service" = 1 ]; then
  if ! "$target/bin/sarto" service install; then
    fail 'The daemon is installed, but its service is not set up; run sarto service install again, or sarto run in the foreground'
  fi
else
  say 'Start it with sarto run, or set up its service with sarto service install.'
fi
