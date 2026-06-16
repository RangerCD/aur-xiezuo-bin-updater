#!/usr/bin/env bash
set -euo pipefail

cd $(dirname "${BASH_SOURCE[0]}")
AUR_XIEZUO_BIN_DIR="./aur-xiezuo-bin"
PKGBUILD="${AUR_XIEZUO_BIN_DIR}/PKGBUILD"

# extract version from filename
extract_version() {
	local filename="$1"
	if [[ "$filename" =~ -stable-([0-9]+\.[0-9]+\.[0-9]+)\.deb$ ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		printf 'error: failed to extract version from filename: %s\n' "${filename}" >&2
		exit 1
	fi
}

# download package from url
download_pkg() {
	local url="$1"
	local outdir="$2"
	local headers tmpfile filename

	mkdir -p "${outdir}"
	headers="${outdir}/.headers"
	tmpfile="${outdir}/.download.tmp"

	printf '==> downloading %s\n' "${url}" >&2
	curl -fsSL -D "${headers}" -o "${tmpfile}" "${url}"

	filename=$(grep -i '^content-disposition:' "${headers}" | tail -1 \
		| sed -n "s/.*filename\\*=utf-8''\\([^[:space:]]*\\).*/\\1/p")
	rm -f "${headers}"

	[[ -n "${filename}" ]] || { printf 'error: failed to get filename from response headers: %s\n' "${url}" >&2; exit 1; }

	mv "${tmpfile}" "${outdir}/${filename}"
	echo "${outdir}/${filename}"
}

# 0. prepare submodule
git submodule update --init --recursive
git submodule update --remote

# 1. parse PKGBUILD
[[ -f "${PKGBUILD}" ]] || { printf 'error: PKGBUILD not found: %s\n' "${PKGBUILD}" >&2; exit 1; }

URL_X64=$(grep '^source_x86_64=' "${PKGBUILD}" | sed 's/.*:://; s/").*//')
URL_ARM64=$(grep '^source_aarch64=' "${PKGBUILD}" | sed 's/.*:://; s/").*//')
[[ -n "${URL_X64}" ]] || { printf 'error: failed to parse source_x86_64 URL from PKGBUILD\n' >&2; exit 1; }
[[ -n "${URL_ARM64}" ]] || { printf 'error: failed to parse source_aarch64 URL from PKGBUILD\n' >&2; exit 1; }

local_pkgver=$(grep '^pkgver=' "${PKGBUILD}" | cut -d= -f2)
local_pkgrel=$(grep '^pkgrel=' "${PKGBUILD}" | cut -d= -f2)
local_hash_x64=$(grep '^sha256sums_x86_64=' "${PKGBUILD}" | sed "s/^sha256sums_x86_64=('\\(.*\\)')/\\1/")
local_hash_arm64=$(grep '^sha256sums_aarch64=' "${PKGBUILD}" | sed "s/^sha256sums_aarch64=('\\(.*\\)')/\\1/")

printf '==> local version: %s\n' "${local_pkgver}" >&2
printf '==> local pkgrel: %s\n' "${local_pkgrel}" >&2
printf '==> local sha256 x86_64: %s\n' "${local_hash_x64}" >&2
printf '==> local sha256 aarch64: %s\n' "${local_hash_arm64}" >&2

# 2. download packages
file_x64="$(download_pkg "${URL_X64}" "tmp/x64")"
file_arm64="$(download_pkg "${URL_ARM64}" "tmp/arm64")"

# 3. extract version and checksum
name_x64="$(basename "${file_x64}")"
name_arm64="$(basename "${file_arm64}")"

printf '==> file x86_64: %s\n' "${name_x64}" >&2
printf '==> file aarch64: %s\n' "${name_arm64}" >&2

version_x64="$(extract_version "${name_x64}")"
version_arm64="$(extract_version "${name_arm64}")"

if [[ "${version_x64}" != "${version_arm64}" ]]; then
	printf 'error: version mismatch: x86_64=%s, aarch64=%s\n' "${version_x64}" "${version_arm64}" >&2
	exit 1
fi

new_version="${version_x64}"
hash_x64="$(sha256sum "${file_x64}" | awk '{print $1}')"
hash_arm64="$(sha256sum "${file_arm64}" | awk '{print $1}')"

printf '==> source version: %s\n' "${new_version}" >&2
printf '==> source sha256 x86_64:  %s\n' "${hash_x64}" >&2
printf '==> source sha256 aarch64: %s\n' "${hash_arm64}" >&2

# 4. update PKGBUILD and generate .SRCINFO if needed
if [[ "${new_version}" == "${local_pkgver}" \
	&& "${hash_x64}" == "${local_hash_x64}" \
	&& "${hash_arm64}" == "${local_hash_arm64}" ]]; then
	printf '==> already up to date (%s)\n' "${new_version}" >&2
	exit 0
fi

new_pkgrel="${local_pkgrel}"
if [[ "${new_version}" != "${local_pkgver}" ]]; then
	printf '==> new version: %s -> %s\n' "${local_pkgver}" "${new_version}" >&2
	new_pkgrel=1
elif [[ "${hash_x64}" != "${local_hash_x64}" || "${hash_arm64}" != "${local_hash_arm64}" ]]; then
	new_pkgrel=$((local_pkgrel + 1))
	printf '==> version unchanged (%s), but checksums differ, bumping pkgrel %s -> %s\n' "${new_version}" "${local_pkgrel}" "${new_pkgrel}" >&2
fi

sed -i "s/^pkgver=.*/pkgver=${new_version}/" "${PKGBUILD}"
sed -i "s/^pkgrel=.*/pkgrel=${new_pkgrel}/" "${PKGBUILD}"
sed -i "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${hash_x64}')/" "${PKGBUILD}"
sed -i "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${hash_arm64}')/" "${PKGBUILD}"

printf '==> updated PKGBUILD\n' >&2
printf '==> generating .SRCINFO\n' >&2
rm -rf tmp/${AUR_XIEZUO_BIN_DIR}
cp -r ${AUR_XIEZUO_BIN_DIR} tmp/${AUR_XIEZUO_BIN_DIR}
chown -R nobody:nobody tmp/${AUR_XIEZUO_BIN_DIR}
cd tmp/${AUR_XIEZUO_BIN_DIR}
BUILDDIR=/tmp sudo -u nobody makepkg --printsrcinfo > .SRCINFO
cd -
mv tmp/${AUR_XIEZUO_BIN_DIR}/.SRCINFO ${AUR_XIEZUO_BIN_DIR}/.SRCINFO

printf '==> done\n' >&2
