-- wizard rewrite wip

local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local util = require "luci.util"
local ip = require "luci.ip"

local community = "profile_" .. (uci:get("freifunk", "community", "name") or "Freifunk")
mesh_network = ip.IPv4(uci:get_first(community, "community", "mesh_network") or "10.0.0.0/8")

m = Map("meshwizard", translate("Wizard"), translate("This wizard will assist you in setting up your router for Freifunk " ..
	"or another similar wireless community network."))
--m:chain("meshwizard")

n = m:section(TypedSection, "netconfig", translate("Interfaces"))
n.anonymous = true

-- common functions

function cbi_configure(device)
	local configure = n:taboption(device, Flag, device .. "_config", translate("Configure this interface"))
end

function cbi_ip4addr(device)
	local ip4addr = n:taboption(device, Value, device .. "_ip4addr", translate("Mesh IP address"),
		translate("This is a unique address in the mesh (e.g. 10.1.1.1) and has to be registered at your local community."))
		ip4addr:depends(device .. "_config", 1)
		ip4addr.datatype = "ip4addr"
	function ip4addr.validate(self, value)
		local x = ip.IPv4(value)
		if mesh_network:contains(x) then
			return value
		else
			return nil, translate("The given IP address is not inside the mesh network range ") ..
			"(" .. mesh_network:string() .. ")."
		end
	end
end

function cbi_dhcp(device)
	local dhcp = n:taboption(device, Flag, device .. "_dhcp", translate("Enable DHCP"),
		translate("DHCP will automatically assign ip addresses to clients"))
	dhcp:depends(device .. "_config", 1)
	dhcp.rmempty = true
end

function cbi_dhcprange(device)
	local dhcprange = n:taboption(device, Value, device .. "_dhcprange", translate("DHCP IP range"),
		translate("The IP range from which clients are assigned ip addresses (e.g. 10.1.2.1/28). " ..
		"If this is a range inside your mesh network range, then it will be announced as HNA. Any other range will use NAT. " ..
		"If left empty then the defaults from the community profile will be used."))
	dhcprange:depends(device .. "_dhcp", "1")
	dhcprange.rmempty = true
	dhcprange.datatype = "ip4addr"
end
-- create tabs and config for wireless
local nets={}
uci:foreach("wireless", "wifi-device", function(section)
        local device = section[".name"]
	table.insert(nets, device)
end)

local wired_nets = {}
uci:foreach("network", "interface", function(section)
	local device = section[".name"]
	if not util.contains(nets, device) and device ~= "loopback" then
		table.insert(nets, device)
		table.insert(wired_nets, device)
	end
end)

for _, net in util.spairs(nets, function(a,b) return (nets[a] < nets[b]) end) do
	n:tab(net, net)
end

-- create cbi config for wireless
uci:foreach("wireless", "wifi-device", function(section)
	local device = section[".name"]
	local hwtype = section.type
	local syscc = section.country or uci:get(community, "wifi_device", "country") or
		uci:get("freifunk", "wifi_device", "country")

	cbi_configure(device)

	-- Channel selection

	if hwtype == "atheros" then
		local cc = util.trim(sys.exec("grep -i '" .. syscc .. "' /lib/wifi/cc_translate.txt |cut -d ' ' -f 2")) or 0
		sys.exec('"echo " .. cc .. " > /proc/sys/dev/" .. device .. "/countrycode"')
	elseif hwtype == "mac80211" then
		sys.exec("iw reg set " .. syscc)
	elseif hwtype == "broadcom" then
		sys.exec ("wlc country " .. syscc)
	end

	local chan = n:taboption(device, ListValue, device .. "_channel", translate("Channel"),
		translate("Your device and neighbouring nodes have to use the same channel."))
	chan:depends(device .. "_config", 1)
	chan:value('default')

	local iwinfo = sys.wifi.getiwinfo(device)
	if iwinfo then
		for _, f in ipairs(iwinfo.freqlist) do
			if not f.restricted then
				chan:value(f.channel)
			end
		end
	end
	-- IPv4 address
	cbi_ip4addr(device)

	-- DHCP enable
	cbi_dhcp(device)

	-- DHCP range
	cbi_dhcprange(device)

	-- Enable VAP
	if hwtype == "atheros" then
		local vap = n:taboption(device, Flag, device .. "_vap", translate("Virtual Access Point (VAP)"),
			translate("This will setup a new virtual wireless interface in Access Point mode."))
		vap:depends(device .. "_dhcp", "1")
                vap.rmempty = true
	end
end)

for _, device in pairs(wired_nets) do
	cbi_configure(device)
	cbi_ip4addr(device)
	cbi_dhcp(device)
	cbi_dhcprange(device)
end

g = m:section(TypedSection, "general", translate("General Settings"))
g.anonymous = true

local cleanup = g:option(Flag, "cleanup", translate("Cleanup config"),
        translate("If this is selected then config is cleaned before setting new config options."))
cleanup.default = "1"

local restrict = g:option(Flag, "local_restrict", translate("Protect LAN"), 
	translate("Check this to protect your LAN from other nodes or clients") .. " (" .. translate("recommended") .. ").")

local share = g:option(Flag, "sharenet", translate("Share your internet connection"),
	translate("Select this to allow others to use your connection to access the internet."))
	share.rmempty = true

--function m.on_after_commit (self)
--	sys.call("/usr/bin/mesh-wizard/wizard.sh >/dev/null")
--end

return m
