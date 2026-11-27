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
#   --channel <name>     Install the latest release on that channel: stable (default) or beta
#   --version <version>  Install that release instead of the latest (X.Y.Z or X.Y.Z-beta.<build>)
#   --tag <tag>          Download from release folder download/<tag> (for decoupled daemon/beta tags)
#   --sha256 <hex>       Take the package only if this is its SHA-256; may be given more than once
#   --no-service         Do not set up the service, as in a container; run `sarto run` instead
#
# SARTO_RELEASES_URL names the one place to download releases from, laid out as GitHub's.
set -eu

downloads=https://sarto.1o.ink/releases
channel=''
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
    --channel)
      [ $# -ge 2 ] || fail '--channel needs stable or beta'
      channel=$2
      shift 2
      ;;
    --channel=*)
      channel=${1#--channel=}
      shift
      ;;
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
      sed -n '2,17s/^# \{0,1\}//p' "$0" 2>/dev/null || say 'See https://sarto.1o.ink/releases'
      exit 0
      ;;
    *) fail "Unknown option $1" ;;
  esac
done
if [ -n "$channel" ]; then
  case $channel in
    stable | beta) ;;
    *) fail "--channel must be stable or beta, not '$channel'" ;;
  esac
  if [ -n "$wanted" ] || [ -n "$tag" ]; then
    fail '--channel cannot be combined with --version or --tag'
  fi
fi
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
  ldd_out=$(ldd --version 2>&1 || true)
  case $ldd_out in
    *musl*) fail 'The Sarto daemon needs glibc; systems with musl, such as Alpine, are not supported' ;;
  esac
  libc=''
  if command -v getconf > /dev/null 2>&1; then
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
  fi
  # Only fall back to scanning ld-musl when neither ldd nor getconf confirms glibc, so glibc hosts
  # with musl-tools installed for cross-compilation are not rejected.
  case "$ldd_out|$libc" in
    *GNU* | *GLIBC* | *glibc*) ;;
    *)
      for musl in /lib/ld-musl-*.so* /usr/lib/ld-musl-*.so*; do
        if [ -e "$musl" ]; then
          fail 'The Sarto daemon needs glibc; systems with musl, such as Alpine, are not supported'
        fi
      done
      ;;
  esac
  case $libc in
    glibc\ [0-9]*.[0-9]*)
      libc_ver=${libc#glibc }
      libc_major=${libc_ver%%.*}
      libc_rest=${libc_ver#*.}
      libc_minor=${libc_rest%%.*}
      if [ "$libc_major" -lt 2 ] || { [ "$libc_major" -eq 2 ] && [ "$libc_minor" -lt 28 ]; }; then
        fail "The Sarto daemon needs glibc 2.28 or later (found glibc $libc_major.$libc_minor)"
      fi
      ;;
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
command -v tar > /dev/null 2>&1 || fail 'Unpacking the download needs tar'

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
# Extracts a top-level string field from a 2-space formatted release manifest JSON without jq.
manifest_field() {
  awk -v key="$2" '
    { sub(/\r$/, "") }
    index($0, "  \"" key "\": \"") == 1 {
      line = substr($0, length("  \"" key "\": \"") + 1)
      sub(/",?$/, "", line)
      print line
      exit
    }
  ' "$1"
}
# Compares two X.Y.Z or X.Y.Z-beta.<build> versions; exits 0 when $1 > $2 (SemVer precedence).
is_newer_version() {
  a_core=${1%%-*}
  b_core=${2%%-*}
  a_maj=${a_core%%.*}
  a_rem=${a_core#*.}
  a_min=${a_rem%%.*}
  a_pat=${a_rem#*.}
  b_maj=${b_core%%.*}
  b_rem=${b_core#*.}
  b_min=${b_rem%%.*}
  b_pat=${b_rem#*.}
  if [ "$a_maj" -ne "$b_maj" ]; then [ "$a_maj" -gt "$b_maj" ]; return; fi
  if [ "$a_min" -ne "$b_min" ]; then [ "$a_min" -gt "$b_min" ]; return; fi
  if [ "$a_pat" -ne "$b_pat" ]; then [ "$a_pat" -gt "$b_pat" ]; return; fi
  case $1 in
    *-beta.*) a_pre=${1#*-beta.} ;;
    *) a_pre='' ;;
  esac
  case $2 in
    *-beta.*) b_pre=${2#*-beta.} ;;
    *) b_pre='' ;;
  esac
  if [ -z "$a_pre" ] && [ -n "$b_pre" ]; then return 0; fi
  if [ -n "$a_pre" ] && [ -z "$b_pre" ]; then return 1; fi
  if [ -z "$a_pre" ] && [ -z "$b_pre" ]; then return 1; fi
  # Compare arbitrary-length positive integer build numbers without 32-bit shell overflow.
  if [ "${#a_pre}" -ne "${#b_pre}" ]; then
    [ "${#a_pre}" -gt "${#b_pre}" ]
    return
  fi
  [ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | LC_ALL=C sort | tail -n 1)" = "$a_pre" ] && [ "$a_pre" != "$b_pre" ]
}
resolve_channel() {
  base=$1
  best_ver=''
  best_tag=''
  for mname in beta-daemon.json latest-daemon.json; do
    if [ "$channel" = stable ] && [ "$mname" = beta-daemon.json ]; then continue; fi
    mfile=$work/$mname
    if ! download "$base/latest/download/$mname" "$mfile"; then continue; fi
    mver=$(manifest_field "$mfile" version)
    mtag=$(manifest_field "$mfile" tag)
    [ -n "$mtag" ] || mtag=v$mver
    if ! is_version "$mver" || ! is_tag "$mtag"; then continue; fi
    if [ "$channel" = stable ]; then
      case $mver in
        *-beta.*) continue ;;
      esac
    fi
    if [ -z "$best_ver" ] || is_newer_version "$mver" "$best_ver"; then
      best_ver=$mver
      best_tag=$mtag
    fi
  done
  if [ -z "$best_tag" ]; then
    why="Could not resolve a $channel daemon release from $base"
    return 1
  fi
  wanted=$best_ver
  tag=$best_tag
  return 0
}
# Downloads the package and the checksums from one place and checks them, or sets why not.
fetch() {
  if [ -n "$channel" ]; then
    if ! resolve_channel "$1"; then
      if [ "$channel" = stable ]; then
        fetch_from "$1/latest/download"
        return
      fi
      return 1
    fi
  fi
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
  say 'Next steps: run `sarto status` to inspect the daemon, and `sarto login` to connect via Sarto Cloud (or add this host over SSH from Sarto on macOS).'
else
  say 'Start it with sarto run, or set up its service with sarto service install.'
fi
