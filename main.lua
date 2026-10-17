--[[--
AI Lookup

Al seleccionar una palabra o frase mientras lees, anade un boton "AI Lookup"
al menu de resaltado de KOReader. Envia la seleccion junto con el contexto
cercano (palabras anteriores y posteriores, es decir, el parrafo) a un modelo
de IA gratuito con API compatible con OpenAI y muestra la respuesta.

Por defecto usa Groq, que es gratuito y solo necesita una API key
(https://console.groq.com). El endpoint y el modelo se pueden cambiar desde el
menu para usar Gemini, OpenRouter u otro proveedor compatible.

@module koplugin.ai_lookup
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Valores por defecto: Groq es gratuito y solo requiere pegar una API key.
local DEFAULT_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
local DEFAULT_MODEL = "openai/gpt-oss-120b"
local DEFAULT_LANGUAGE = "Spanish"
local DEFAULT_CONTEXT_WORDS = 40

-- Idiomas comunes ofrecidos en el selector de idioma de respuesta.
local LANGUAGES = {
    "English", "Spanish", "French", "German", "Italian", "Portuguese",
    "Dutch", "Polish", "Russian", "Ukrainian", "Turkish", "Arabic",
    "Chinese", "Japanese", "Korean", "Hindi", "Catalan", "Galician",
    "Basque", "Swedish", "Norwegian", "Danish", "Finnish", "Czech",
    "Greek", "Romanian", "Hungarian", "Hebrew", "Indonesian", "Vietnamese",
    "Thai",
}

local REQUEST_BLOCK_TIMEOUT = 30
local REQUEST_TOTAL_TIMEOUT = 90
local MAX_ANSWER_CHARS = 4000
local MAX_CONTEXT_CHARS = 1500

-- Filtro por nombre para la lista de modelos: la API no expone si un modelo
-- es de pago, de audio o preview, asi que descartamos los que no son modelos
-- de chat (audio, moderacion, embeddings, guard, preview, etc.).
local MODEL_ID_DENYLIST = {
    "whisper", "tts", "orpheus", "guard", "embed", "moderation",
    "safeguard", "speech", "rerank", "preview", "audio", "canary",
}

local function is_usable_chat_model(id)
    local lower = id:lower()
    for _, word in ipairs(MODEL_ID_DENYLIST) do
        if lower:find(word, 1, true) then
            return false
        end
    end
    return true
end

-- Quita el formato Markdown que algunos modelos devuelven aunque se les pida
-- texto plano, para que no salgan asteriscos o almohadillas literales.
local function strip_markdown(text)
    if not text then
        return text
    end
    text = text:gsub("```[%w]*\n?", "")
    text = text:gsub("```", "")
    text = text:gsub("`(.-)`", "%1")
    -- Encabezados al inicio de linea
    text = text:gsub("\n#+%s*", "\n")
    text = text:gsub("^#+%s*", "")
    -- Vinetas de lista -> punto medio
    text = text:gsub("\n%s*[%*%-]%s+", "\n• ")
    text = text:gsub("^%s*[%*%-]%s+", "• ")
    -- Negrita y cursiva
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("__(.-)__", "%1")
    text = text:gsub("%*(.-)%*", "%1")
    return text
end

local AILookup = WidgetContainer:extend{
    name = "ai_lookup",
    is_doc_only = true,
}

function AILookup:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ai_lookup.lua")

    -- Boton en el menu que aparece al seleccionar texto.
    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("20_ai_lookup", function(reader_highlight)
            return {
                text = _("AI Lookup"),
                callback = function()
                    self:lookup(reader_highlight)
                end,
            }
        end)
    end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

--==========================================================================
-- Configuracion
--==========================================================================

-- Permite preconfigurar el plugin con un archivo configuration.lua opcional
-- dentro de la carpeta del plugin.
function AILookup:getConfigFileDefaults()
    if not self.path then
        return {}
    end
    local ok, conf = pcall(dofile, self.path .. "/configuration.lua")
    if ok and type(conf) == "table" then
        return conf
    end
    return {}
end

function AILookup:getConfig()
    local file_defaults = self:getConfigFileDefaults()
    local function pick(key, default)
        local value = self.settings:readSetting(key)
        if value == nil or value == "" then
            value = file_defaults[key]
        end
        if value == nil or value == "" then
            value = default
        end
        return value
    end
    return {
        api_key = pick("api_key", ""),
        endpoint = pick("endpoint", DEFAULT_ENDPOINT),
        model = pick("model", DEFAULT_MODEL),
        language = pick("language", DEFAULT_LANGUAGE),
        context_words = pick("context_words", DEFAULT_CONTEXT_WORDS),
    }
end

--==========================================================================
-- Consulta
--==========================================================================

function AILookup:getBookDescription()
    local props = self.ui and self.ui.doc_props
    if not props or not props.title or props.title == "" then
        return ""
    end
    local authors = props.authors
    if type(authors) == "table" then
        authors = table.concat(authors, ", ")
    end
    if authors and authors ~= "" then
        return T(_("The book is «%1» by %2. "), props.title, authors)
    end
    return T(_("The book is «%1». "), props.title)
end

function AILookup:buildUserPrompt(config, selection, before, after)
    local context = ((before or "") .. " [[" .. selection .. "]] " .. (after or "")):gsub("%s+", " ")
    context = context:gsub("^%s+", ""):gsub("%s+$", "")
    if #context > MAX_CONTEXT_CHARS then
        context = context:sub(1, MAX_CONTEXT_CHARS) .. "…"
    end
    return T(
        "%1Selected word or phrase: \"%2\"\n" ..
        "Context where it appears in the book: \"%3\"\n\n" ..
        "Answer in %4:\n" ..
        "1) Explain the general meaning of the word or phrase (add synonyms when useful).\n" ..
        "2) Explain its precise meaning in this specific context, taking the surrounding text into account.\n" ..
        "Be concise and clear. Do not ask questions.",
        self:getBookDescription(), selection, context, config.language
    )
end

-- Solo hace red: se ejecuta en un subproceso, asi que no debe tocar la UI.
function AILookup:queryModel(config, prompt)
    local request_body = {
        model = config.model,
        messages = {
            {
                role = "system",
                content = "You are a helpful reading assistant and dictionary. "
                    .. "Answer in plain text only: do not use Markdown or any formatting "
                    .. "syntax (no asterisks, hashes, underscores or backticks). "
                    .. "Answer clearly and concisely.",
            },
            {
                role = "user",
                content = prompt,
            },
        },
        temperature = 0.3,
        stream = false,
    }

    local ok_encode, encoded = pcall(json.encode, request_body)
    if not ok_encode or not encoded then
        return { ok = false, error = _("Could not encode the request.") }
    end

    local sink = {}
    socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
    local request = {
        url = config.endpoint,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#encoded),
            ["Authorization"] = "Bearer " .. config.api_key,
        },
        source = ltn12.source.string(encoded),
        sink = socketutil.table_sink(sink),
    }

    local client = config.endpoint:lower():sub(1, 7) == "http://" and http.request or https.request

    local ok_request, code, headers, status = pcall(function()
        return socket.skip(1, client(request))
    end)
    socketutil:reset_timeout()

    if not ok_request then
        return { ok = false, error = tostring(code) }
    end
    if headers == nil then
        return { ok = false, error = tostring(status or code or _("network unreachable")) }
    end
    if code ~= 200 then
        local body = table.concat(sink)
        if #body > 600 then
            body = body:sub(1, 600) .. "…"
        end
        -- socketutil.describe_error no existe en todas las versiones de KOReader.
        local reason
        if socketutil.describe_error then
            reason = socketutil.describe_error(code, REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
        end
        local detail = body ~= "" and body or (reason or tostring(status or ""))
        logger.warn("AI Lookup HTTP error:", tostring(code), body)
        return {
            ok = false,
            error = T(_("The server returned HTTP %1.\n%2"), tostring(code), detail),
        }
    end

    local content = table.concat(sink)
    local ok_decode, decoded = pcall(json.decode, content)
    if not ok_decode or type(decoded) ~= "table" then
        return { ok = false, error = _("The response is not valid JSON.") }
    end
    if decoded.error then
        local message = decoded.error.message or decoded.error
        return { ok = false, error = _("The API returned an error: ") .. tostring(message) }
    end

    local answer = decoded.choices
        and decoded.choices[1]
        and decoded.choices[1].message
        and decoded.choices[1].message.content
    if not answer or answer == "" then
        return { ok = false, error = _("The model returned an empty answer.") }
    end

    return { ok = true, text = tostring(answer) }
end

function AILookup:lookup(reader_highlight)
    local selected = reader_highlight.selected_text
    if not selected or not selected.text or selected.text == "" then
        UIManager:show(InfoMessage:new{ text = _("Select a word or phrase first.") })
        return
    end

    local config = self:getConfig()
    if not config.api_key or config.api_key == "" then
        UIManager:show(InfoMessage:new{
            text = _("No API key configured yet.\nOpen the menu: Search → AI Lookup settings."),
        })
        return
    end

    local selection = util.cleanupSelectedText(selected.text)
    local before, after = reader_highlight:getSelectedWordContext(config.context_words)
    local prompt = self:buildUserPrompt(config, selection, before, after)
    local request_config = {
        api_key = config.api_key,
        endpoint = config.endpoint,
        model = config.model,
    }

    local function finish(result)
        if not result or not result.ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not get an answer:\n%1"), (result and result.error) or _("unknown error")),
            })
            return
        end
        self:showResult(selection, result.text)
    end

    -- La consulta se hace siempre en un subproceso (Trapper). Es importante
    -- NO bloquear el hilo principal con la peticion de red: en Android eso
    -- hace crashear el hilo de render (hwuiTask) del proceso.
    local function run()
        Trapper:wrap(function()
            logger.dbg("AI Lookup:", request_config.endpoint, request_config.model)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local query_ok, res = xpcall(function()
                    return self:queryModel(request_config, prompt)
                end, function(err)
                    logger.warn("AI Lookup query error:", err, debug.traceback("", 2))
                    return tostring(err)
                end)
                if not query_ok then
                    return { ok = false, error = res }
                end
                return res
            end, _("Consulting the AI…"))

            if not completed then
                UIManager:show(InfoMessage:new{ text = _("Consultation interrupted.") })
                return
            end
            if result == nil then
                logger.warn("AI Lookup: the subprocess did not return a result")
                UIManager:show(InfoMessage:new{ text = _("Could not get an answer: the consultation failed.") })
                return
            end
            finish(result)
        end)
    end

    if NetworkMgr:willRerunWhenOnline(run) then
        return
    end
    run()
end

function AILookup:showResult(selection, text)
    text = strip_markdown(text)
    if #text > MAX_ANSWER_CHARS then
        text = text:sub(1, MAX_ANSWER_CHARS) .. "…"
    end

    local buttons_table = nil
    if Device:hasClipboard() then
        buttons_table = { {
            {
                text = _("Copy"),
                callback = function()
                    Device.input.setClipboardText(text)
                    UIManager:show(InfoMessage:new{ text = _("Copied to clipboard.") })
                end,
            },
        } }
    end

    UIManager:show(TextViewer:new{
        title = _("AI Lookup") .. ": " .. selection,
        title_multilines = true,
        text = text,
        justified = true,
        add_default_buttons = true,
        buttons_table = buttons_table,
    })
end

--==========================================================================
-- Ajustes (menu)
--==========================================================================

function AILookup:addToMainMenu(menu_items)
    menu_items.ai_lookup_settings = {
        text = _("AI Lookup settings"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text_func = function()
                    local key = self:getConfig().api_key
                    if not key or key == "" then
                        return _("Set API key")
                    end
                    return T(_("Change API key (current: %1…)"), key:sub(1, 4))
                end,
                callback = function(touchmenu_instance)
                    self:editSetting(_("API key"), "api_key", touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Model: %1"), self:getConfig().model)
                end,
                callback = function(touchmenu_instance)
                    self:editSetting(_("Model"), "model", touchmenu_instance)
                end,
            },
            {
                text = _("Choose model from available list"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:fetchAndChooseModel(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("API endpoint: %1"), self:getConfig().endpoint)
                end,
                callback = function(touchmenu_instance)
                    self:editSetting(_("API endpoint"), "endpoint", touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Answer language: %1"), self:getConfig().language)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showLanguagePicker(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("Context words: %1"), self:getConfig().context_words)
                end,
                callback = function(touchmenu_instance)
                    self:editContextWords(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("How to get a free API key"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Create a free account at console.groq.com, generate an API key and paste it here.\nGroq is free and needs no credit card."),
                    })
                end,
            },
            {
                text = _("Restore default settings"),
                callback = function(touchmenu_instance)
                    self.settings:reset()
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{ text = _("Settings restored to defaults.") })
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        },
    }
end

function AILookup:editSetting(title, key, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(self.settings:readSetting(key) or self:getConfig()[key] or ""),
        allow_newline = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        self.settings:saveSetting(key, dialog:getInputText())
                        self.settings:flush()
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AILookup:editContextWords(touchmenu_instance)
    UIManager:show(SpinWidget:new{
        title_text = _("Context words"),
        info_text = _("How many words before and after the selection are sent as context."),
        value = self:getConfig().context_words,
        value_min = 0,
        value_max = 200,
        value_step = 5,
        value_hold_step = 20,
        default_value = DEFAULT_CONTEXT_WORDS,
        callback = function(spin)
            self.settings:saveSetting("context_words", spin.value)
            self.settings:flush()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })
end

--==========================================================================
-- Lista de modelos disponibles (GET <base>/models, compatible con OpenAI)
--==========================================================================

function AILookup:getModelsUrl(endpoint)
    local base = endpoint:gsub("/chat/completions/*$", "")
    if base == endpoint then
        base = endpoint:gsub("/*$", "")
    end
    return base .. "/models"
end

function AILookup:fetchModels(config)
    local url = self:getModelsUrl(config.endpoint)
    local sink = {}
    socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. config.api_key },
        sink = socketutil.table_sink(sink),
    }
    local client = url:lower():sub(1, 7) == "http://" and http.request or https.request

    local ok_request, code, headers, status = pcall(function()
        return socket.skip(1, client(request))
    end)
    socketutil:reset_timeout()

    if not ok_request then
        return { ok = false, error = tostring(code) }
    end
    if headers == nil then
        return { ok = false, error = tostring(status or code or _("network unreachable")) }
    end
    if code ~= 200 then
        local body = table.concat(sink)
        if #body > 600 then
            body = body:sub(1, 600) .. "…"
        end
        logger.warn("AI Lookup models HTTP error:", tostring(code), body)
        return { ok = false, error = T(_("The server returned HTTP %1.\n%2"), tostring(code), body) }
    end

    local content = table.concat(sink)
    local ok_decode, decoded = pcall(json.decode, content)
    if not ok_decode or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
        return { ok = false, error = _("Could not parse the model list.") }
    end

    local ids = {}
    for _, entry in ipairs(decoded.data) do
        if type(entry) == "table" and entry.id then
            local id = tostring(entry.id)
            if is_usable_chat_model(id) then
                table.insert(ids, id)
            end
        end
    end
    table.sort(ids)
    if #ids == 0 then
        return { ok = false, error = _("No models available for this API key.") }
    end
    return { ok = true, models = ids }
end

function AILookup:fetchAndChooseModel(touchmenu_instance)
    local config = self:getConfig()
    if not config.api_key or config.api_key == "" then
        UIManager:show(InfoMessage:new{ text = _("Set your API key first.") })
        return
    end

    local function run()
        Trapper:wrap(function()
            local ok, err = xpcall(function()
                local completed, result = Trapper:dismissableRunInSubprocess(function()
                    return self:fetchModels(config)
                end, _("Fetching models…"))

                if not completed then
                    return
                end
                if type(result) ~= "table" then
                    UIManager:show(InfoMessage:new{
                        text = _("Could not fetch the model list (no response from the subprocess)."),
                    })
                    return
                end
                if not result.ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not fetch models:\n%1"), tostring(result.error or "unknown error")),
                    })
                    return
                end
                self:showModelPicker(result.models, touchmenu_instance)
            end, debug.traceback)

            if not ok then
                logger.warn("AI Lookup fetch error:", err)
                UIManager:show(InfoMessage:new{
                    text = T(_("AI Lookup error:\n%1"), tostring(err)),
                })
            end
        end)
    end

    if NetworkMgr:willRerunWhenOnline(run) then
        return
    end
    run()
end

function AILookup:showModelPicker(models, touchmenu_instance)
    local current = self:getConfig().model
    local current_label = _("current")
    local picker
    local kv_pairs = {}
    for _idx, model in ipairs(models) do
        table.insert(kv_pairs, {
            model,
            model == current and current_label or "",
            callback = function()
                self.settings:saveSetting("model", model)
                self.settings:flush()
                UIManager:close(picker)
                UIManager:show(InfoMessage:new{ text = T(_("Model set to %1."), model) })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        })
    end
    picker = KeyValuePage:new{
        title = _("Choose a model"),
        kv_pairs = kv_pairs,
    }
    UIManager:show(picker)
end

function AILookup:showLanguagePicker(touchmenu_instance)
    local current = self:getConfig().language
    local current_label = _("current")
    local picker
    local kv_pairs = {}
    for _idx, lang in ipairs(LANGUAGES) do
        table.insert(kv_pairs, {
            lang,
            lang == current and current_label or "",
            callback = function()
                self.settings:saveSetting("language", lang)
                self.settings:flush()
                UIManager:close(picker)
                UIManager:show(InfoMessage:new{ text = T(_("Answer language set to %1."), lang) })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        })
    end
    table.insert(kv_pairs, {
        _("Other (type manually)"),
        "",
        callback = function()
            UIManager:close(picker)
            self:editSetting(_("Answer language"), "language", touchmenu_instance)
        end,
    })
    picker = KeyValuePage:new{
        title = _("Answer language"),
        kv_pairs = kv_pairs,
    }
    UIManager:show(picker)
end

return AILookup
