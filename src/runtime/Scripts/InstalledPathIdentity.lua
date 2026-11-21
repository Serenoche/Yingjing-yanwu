local Identity = {}
local compare

function Identity.same(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
    if compare == nil then
        local source = debug.getinfo(1, "S").source
        local directory = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)[/\\][^/\\]+$")
        compare = directory and package.loadlib(directory .. "/PBZPathIdentity.dll", "PBZSamePath") or false
    end
    return compare and compare(left, right) == true or false
end

function Identity.installRoot(install, path, accountPrefix)
    local configured = path:match("^(.*)" .. accountPrefix .. "[^/]+/pbzsavegame%.sav$")
    if configured and configured ~= install and Identity.same(install, configured) then return configured end
    return install
end

function Identity.sameSave(expected, actual)
    local suffix = expected:match("(/projectpbz/saved/savegames/.*)$")
    return suffix ~= nil and actual:sub(-#suffix) == suffix and Identity.same(expected, actual)
end

return Identity
