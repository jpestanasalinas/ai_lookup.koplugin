--[[--
updater.lua — actualizacion de AI Lookup desde el propio dispositivo.

Comprueba la ultima release en GitHub, descarga el zip del tag correspondiente y
lo instala de forma atomica sobre la carpeta del plugin, preservando la
configuracion local del usuario (configuration.lua).

Las funciones que hacen red o tocan el disco estan pensadas para ejecutarse en
un subproceso (Trapper), ya que en Android hacer red en el hilo principal
provoca el cierre del proceso de render de KOReader.
--]]

local Archiver = require("ffi/archiver")
local logger = require("logger")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = util.template

local REQUEST_BLOCK_TIMEOUT = 30
local REQUEST_TOTAL_TIMEOUT = 120

local Updater = {
    owner = "jpestanasalinas",
    repo = "ai_lookup.koplugin",
}

function Updater:releasesUrl()
    return "https://github.com/" .. self.owner .. "/" .. self.repo .. "/releases/latest"
end

function Updater:zipUrl(tag)
    return "https://codeload.github.com/" .. self.owner .. "/" .. self.repo
        .. "/zip/refs/tags/" .. tag
end

function Updater:normalizeVersion(version)
    if version == nil then
        return nil
    end
    return (tostring(version):gsub("^v", ""))
end

local function parseVersion(version)
    local numbers = {}
    for number in tostring(version or ""):gmatch("%d+") do
        numbers[#numbers + 1] = tonumber(number)
    end
    return numbers
end

-- Devuelve -1 si a<b, 0 si son iguales y 1 si a>b.
function Updater:compareVersions(a, b)
    local pa, pb = parseVersion(a), parseVersion(b)
    local count = math.max(#pa, #pb)
    for i = 1, count do
        local left, right = (pa[i] or 0), (pb[i] or 0)
        if left < right then
            return -1
        elseif left > right then
            return 1
        end
    end
    return 0
end

-- Hace una peticion a "releases/latest": GitHub responde con un 302 al tag mas
-- reciente. LuaSocket sigue la redireccion y deja la URL de destino en
-- headers.location (el cuerpo, que no nos interesa, se descarta).
function Updater:getLatestTag()
    local url = self:releasesUrl()
    socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = "ai_lookup.koplugin" },
    }
    local client = url:lower():sub(1, 7) == "http://" and http.request or https.request
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, client(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return nil, T(_("Could not reach GitHub: %1"), tostring(code))
    end
    if headers == nil then
        return nil, tostring(status or code or _("network unreachable"))
    end
    local location = headers.location
    if not location or location == "" then
        return nil, _("Could not determine the latest version.")
    end
    local tag = location:match("/releases/tag/([^/?#]+)")
    if not tag then
        logger.warn("AI Lookup updater: unexpected redirect location:", location)
        return nil, _("Could not determine the latest version.")
    end
    return tag
end

-- Descarga una URL a un archivo. Devuelve { ok = true } o { ok = false, error }.
function Updater:downloadFile(url, dest_path)
    local file, ferr = io.open(dest_path, "wb")
    if not file then
        return { ok = false, error = T(_("Could not create %1: %2"), dest_path, tostring(ferr)) }
    end
    socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = "ai_lookup.koplugin" },
        sink = ltn12.sink.file(file),
    }
    local client = url:lower():sub(1, 7) == "http://" and http.request or https.request
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, client(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return { ok = false, error = tostring(code) }
    end
    if headers == nil then
        return { ok = false, error = tostring(status or code or _("network unreachable")) }
    end
    if code ~= 200 then
        return { ok = false, error = T(_("The server returned HTTP %1."), tostring(code)) }
    end
    return { ok = true }
end

local function mkdir_p(path)
    if not path or path == "" then
        return true
    end
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    mkdir_p(path:match("(.*)[/\\][^/\\]+$"))
    return lfs.mkdir(path)
end

-- Extrae un zip a dest_dir, recreando la estructura de carpetas.
function Updater:extractZip(zip_path, dest_dir)
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        return false, arc.err or _("Could not open the downloaded file.")
    end
    local extracted_ok = true
    local extract_err
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local relative = entry.path:gsub("^%./", "")
            local target = dest_dir .. "/" .. relative
            mkdir_p(target:match("(.*)[/\\][^/\\]+$"))
            if not arc:extractToPath(entry.path, target) then
                extract_err = arc.err
                extracted_ok = false
                break
            end
        end
    end
    arc:close()
    if not extracted_ok then
        return false, extract_err or _("Could not extract the archive.")
    end
    return true
end

-- Localiza la carpeta que contiene _meta.lua (los zips de GitHub anidan el
-- contenido en una subcarpeta con el nombre del tag).
function Updater:findPluginRoot(dir)
    if lfs.attributes(dir .. "/_meta.lua", "mode") == "file" then
        return dir
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local sub = dir .. "/" .. name
            if lfs.attributes(sub, "mode") == "directory"
                and lfs.attributes(sub .. "/_meta.lua", "mode") == "file" then
                return sub
            end
        end
    end
    return nil
end

function Updater:readVersion(dir)
    local ok, meta = pcall(dofile, dir .. "/_meta.lua")
    if ok and type(meta) == "table" then
        return meta.version
    end
    return nil
end

-- Descarga e instala el tag indicado sobre plugin_path. Devuelve
-- { ok = true, version = ... } o { ok = false, error = ... }.
-- Debe ejecutarse en un subproceso.
function Updater:installUpdate(plugin_path, tag)
    plugin_path = tostring(plugin_path):gsub("[/\\]+$", "")
    local parent = plugin_path:match("(.*)[/\\][^/\\]+$")
    if not parent or parent == "" then
        return { ok = false, error = _("Could not determine the plugins folder.") }
    end
    local zip_path = parent .. "/ai_lookup.koplugin_update.zip"
    local staging = parent .. "/ai_lookup.koplugin_staging"
    local backup = parent .. "/ai_lookup.koplugin.backup"
    local preserved = parent .. "/ai_lookup.koplugin_configuration.lua"

    local function cleanup()
        pcall(os.remove, zip_path)
        pcall(os.remove, preserved)
        pcall(util.purgeDir, staging)
        pcall(util.purgeDir, backup)
    end

    local expected = self:normalizeVersion(tag)

    -- 1. Descarga
    pcall(os.remove, zip_path)
    local download = self:downloadFile(self:zipUrl(tag), zip_path)
    if not download.ok then
        cleanup()
        return { ok = false, error = T(_("Download failed: %1"), tostring(download.error)) }
    end

    -- 2. Extraccion a una carpeta temporal
    pcall(util.purgeDir, staging)
    if not lfs.mkdir(staging) then
        cleanup()
        return { ok = false, error = _("Could not create a temporary folder. Is the plugins folder writable?") }
    end
    local extract_ok, extract_err = self:extractZip(zip_path, staging)
    if not extract_ok then
        cleanup()
        return { ok = false, error = T(_("Could not extract the update: %1"), tostring(extract_err)) }
    end

    -- 3. Verificacion
    local root = self:findPluginRoot(staging)
    if not root or lfs.attributes(root .. "/main.lua", "mode") ~= "file" then
        cleanup()
        return { ok = false, error = _("The downloaded update does not contain the expected files.") }
    end
    local new_version = self:normalizeVersion(self:readVersion(root))
    if new_version ~= expected then
        cleanup()
        return {
            ok = false,
            error = T(_("Version mismatch: downloaded %1, expected %2."),
                tostring(new_version), tostring(expected)),
        }
    end

    -- 4. Preserva la configuracion local del usuario (API key, etc.)
    local config_src = plugin_path .. "/configuration.lua"
    local has_config = lfs.attributes(config_src, "mode") == "file"
    if has_config then
        pcall(os.remove, preserved)
        local copy_err = util.copyFile(config_src, preserved)
        if copy_err then
            has_config = false
            logger.warn("AI Lookup updater: could not preserve configuration.lua:", tostring(copy_err))
        end
    end

    -- 5. Reemplazo atomico: version actual -> backup, staging -> version actual
    pcall(util.purgeDir, backup)
    if not os.rename(plugin_path, backup) then
        cleanup()
        return { ok = false, error = _("Could not move the current plugin. Is the plugins folder writable?") }
    end
    if not os.rename(root, plugin_path) then
        os.rename(backup, plugin_path) -- rollback
        cleanup()
        return { ok = false, error = _("Could not install the new version. The previous version was restored.") }
    end

    -- 6. Restaura la configuracion del usuario
    if has_config then
        local restore_err = util.copyFile(preserved, plugin_path .. "/configuration.lua")
        if restore_err then
            logger.warn("AI Lookup updater: could not restore configuration.lua:", tostring(restore_err))
        end
    end

    -- 7. Limpieza (version antigua y staging restante)
    cleanup()

    return { ok = true, version = new_version }
end

return Updater
