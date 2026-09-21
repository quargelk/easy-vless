-- Easy VLESS: ported near-verbatim from PassWall2 25.5.15-1 (commit 394f3842969161ddd888187e72db4b493b3310b4)
-- Static metadata table for sing-box/xray/geoview binaries. Most fields (get_url,
-- file_tree, match_fmt_str, zipped, zipped_suffix) are unused now that the GitHub
-- self-update infrastructure was removed from api.lua; only cmd_version, default_path
-- and name are still read, by api.lua's version-display helper (get_app_version/get_app_path).
-- The whole table is kept intact rather than pruning fields, per project decision.
local _M = {}

local function gh_release_url(self)
	--return "https://api.github.com/repos/" .. self.repo .. "/releases/latest"
	return "https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/api-cache/" .. string.lower(self.name) .. "-release-api.json"
end

local function gh_pre_release_url(self)
	--return "https://api.github.com/repos/" .. self.repo .. "/releases?per_page=1"
	return "https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/api-cache/" .. string.lower(self.name) .. "-pre-release-api.json"
end

_M["sing-box"] = {
	name = "Sing-Box",
	repo = "SagerNet/sing-box",
	get_url = gh_release_url,
	cmd_version = "version | awk '{print $3}' | sed -n 1P",
	zipped = true,
	zipped_suffix = "tar.gz",
	default_path = "/usr/bin/sing-box",
	match_fmt_str = "linux%%-%s",
	file_tree = {
		x86_64 = "amd64%-musl",
		x86     = "386%-musl",
		aarch64 = "arm64%-musl",
		rockchip = "arm64%-musl",
		mips    = "mips%-softfloat",
		mips64  = "mips64%-softfloat",
		mipsel  = "mipsle%-softfloat%-musl",
		mips64el = "mips64le%-softfloat",
		armv7   = "armv7%-musl",
		armv8   = "arm64%-musl",
		riscv64 = "riscv64%-musl"
	}
}

_M.xray = {
	name = "Xray",
	repo = "XTLS/Xray-core",
	get_url = gh_pre_release_url,
	cmd_version = "version | awk '{print $2}' | sed -n 1P",
	zipped = true,
	default_path = "/usr/bin/xray",
	match_fmt_str = "linux%%-%s",
	file_tree = {
		x86_64 = "64",
		x86    = "32",
		mips   = "mips32",
		mipsel = "mips32le",
		mips64el = "mips64le"
	}
}

_M.geoview = {
	name = "Geoview",
	repo = "snowie2000/geoview",
	get_url = gh_release_url,
	cmd_version = '-version 2>/dev/null | awk \'NR==1 && $1=="Geoview" {print $2}\'',
	zipped = false,
	default_path = "/usr/bin/geoview",
	match_fmt_str = "linux%%-%s",
	file_tree = {
		mipsel = "mipsle",
		mips64el = "mips64le"
	}
}

return _M
