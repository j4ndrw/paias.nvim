local job = require("plenary.job")
local Config = require("chatgpt.config")
local logger = require("chatgpt.common.logger")
local Utils = require("chatgpt.utils")

local Api = {}

function Api.completions(custom_params, cb)
  local openai_params = Utils.collapsed_openai_params(Config.options.openai_params)
  local params = vim.tbl_extend("keep", custom_params, openai_params)
  Api.make_call(Api.COMPLETIONS_URL, params, cb)
end

function Api.chat_completions(custom_params, cb, should_stop)
  local openai_params = Utils.collapsed_openai_params(Config.options.openai_params)
  local params = vim.tbl_extend("keep", custom_params, openai_params)
  -- the custom params contains <dynamic> if model is not constant but function
  -- therefore, use collapsed openai params (with function evaluated to get model) if that is the case
  if params.model == "<dynamic>" then
    params.model = openai_params.model
  end
  Api.make_call(Api.CHAT_COMPLETIONS_URL, params, cb)
end

function Api.edits(custom_params, cb)
  local openai_params = Utils.collapsed_openai_params(Config.options.openai_params)
  local params = vim.tbl_extend("keep", custom_params, openai_params)
  if params.model == "text-davinci-edit-001" or params.model == "code-davinci-edit-001" then
    vim.notify("Edit models are deprecated", vim.log.levels.WARN)
    Api.make_call(Api.EDITS_URL, params, cb)
    return
  end

  Api.make_call(Api.CHAT_COMPLETIONS_URL, params, cb)
end

function Api.make_call(url, params, cb)
  TMP_MSG_FILENAME = os.tmpname()
  local f = io.open(TMP_MSG_FILENAME, "w+")
  if f == nil then
    vim.notify("Cannot open temporary message file: " .. TMP_MSG_FILENAME, vim.log.levels.ERROR)
    return
  end
  f:write(vim.fn.json_encode(params))
  f:close()

  local args = {
    url,
    "-H",
    "Content-Type: application/json",
    "-H",
    Api.AUTHORIZATION_HEADER,
    "-d",
    "@" .. TMP_MSG_FILENAME,
  }

  local extra_curl_params = Config.options.extra_curl_params
  if extra_curl_params ~= nil then
    for _, param in ipairs(extra_curl_params) do
      table.insert(args, param)
    end
  end

  Api.job = job
    :new({
      command = "curl",
      args = args,
      on_exit = vim.schedule_wrap(function(response, exit_code)
        Api.handle_response(response, exit_code, cb)
      end),
    })
    :start()
end

Api.handle_response = vim.schedule_wrap(function(response, exit_code, cb)
  os.remove(TMP_MSG_FILENAME)
  if exit_code ~= 0 then
    vim.notify("An Error Occurred ...", vim.log.levels.ERROR)
    cb("ERROR: API Error")
  end

  local result = table.concat(response:result(), "\n")
  local json = vim.fn.json_decode(result)
  if json == nil then
    cb("No Response.", "END")
  elseif json.error then
    cb("// API ERROR: " .. json.error.message)
  else
    local message = json[1].message
    if message ~= nil then
      cb(message, "END")
    else
      cb("No response", "END")
    end
  end
end)

function Api.close()
  if Api.job then
    job:shutdown()
  end
end

local splitCommandIntoTable = function(command)
  local cmd = {}
  for word in command:gmatch("%S+") do
    table.insert(cmd, word)
  end
  return cmd
end

local function loadConfigFromCommand(command, optionName, callback, defaultValue)
  local cmd = splitCommandIntoTable(command)
  job
    :new({
      command = cmd[1],
      args = vim.list_slice(cmd, 2, #cmd),
      on_exit = function(j, exit_code)
        if exit_code ~= 0 then
          logger.warn("Config '" .. optionName .. "' did not return a value when executed")
          return
        end
        local value = j:result()[1]:gsub("%s+$", "")
        if value ~= nil and value ~= "" then
          callback(value)
        elseif defaultValue ~= nil and defaultValue ~= "" then
          callback(defaultValue)
        end
      end,
    })
    :start()
end

local function loadConfigFromEnv(envName, configName, callback)
  local variable = os.getenv(envName)
  if not variable then
    return
  end
  local value = variable:gsub("%s+$", "")
  Api[configName] = value
  if callback then
    callback(value)
  end
end

local function loadOptionalConfig(envName, configName, optionName, callback, defaultValue)
  loadConfigFromEnv(envName, configName)
  if Api[configName] then
    callback(Api[configName])
  elseif Config.options[optionName] ~= nil and Config.options[optionName] ~= "" then
    loadConfigFromCommand(Config.options[optionName], optionName, callback, defaultValue)
  else
    callback(defaultValue)
  end
end

local function loadRequiredConfig(envName, configName, optionName, callback, defaultValue)
  loadConfigFromEnv(envName, configName, callback)
  if not Api[configName] then
    if Config.options[optionName] ~= nil and Config.options[optionName] ~= "" then
      loadConfigFromCommand(Config.options[optionName], optionName, callback, defaultValue)
    else
      logger.warn(configName .. " variable not set")
      return
    end
  end
end

local function loadAzureConfigs()
  loadRequiredConfig("OPENAI_API_BASE", "OPENAI_API_BASE", "azure_api_base_cmd", function(base)
    Api.OPENAI_API_BASE = base

    loadRequiredConfig("OPENAI_API_AZURE_ENGINE", "OPENAI_API_AZURE_ENGINE", "azure_api_engine_cmd", function(engine)
      Api.OPENAI_API_AZURE_ENGINE = engine

      loadOptionalConfig(
        "OPENAI_API_AZURE_VERSION",
        "OPENAI_API_AZURE_VERSION",
        "azure_api_version_cmd",
        function(version)
          Api.OPENAI_API_AZURE_VERSION = version

          if Api["OPENAI_API_BASE"] and Api["OPENAI_API_AZURE_ENGINE"] then
            Api.COMPLETIONS_URL = Api.OPENAI_API_BASE
              .. "/openai/deployments/"
              .. Api.OPENAI_API_AZURE_ENGINE
              .. "/completions?api-version="
              .. Api.OPENAI_API_AZURE_VERSION
            Api.CHAT_COMPLETIONS_URL = Api.OPENAI_API_BASE
              .. "/openai/deployments/"
              .. Api.OPENAI_API_AZURE_ENGINE
              .. "/chat/completions?api-version="
              .. Api.OPENAI_API_AZURE_VERSION
          end
        end,
        "2023-05-15"
      )
    end)
  end)
end

local function startsWith(str, start)
  return string.sub(str, 1, string.len(start)) == start
end

local function ensureUrlProtocol(str)
  if startsWith(str, "https://") or startsWith(str, "http://") then
    return str
  end

  return "https://" .. str
end

function Api.setup()
  loadOptionalConfig("OPENAI_API_HOST", "OPENAI_API_HOST", "api_host_cmd", function(host)
    Api.OPENAI_API_HOST = host
    Api.COMPLETIONS_URL = ensureUrlProtocol(Api.OPENAI_API_HOST .. "/v1/completions")
    Api.CHAT_COMPLETIONS_URL = ensureUrlProtocol(Api.OPENAI_API_HOST .. "/v1/chat/completions")
    Api.EDITS_URL = ensureUrlProtocol(Api.OPENAI_API_HOST .. "/v1/edits")
  end, "api.openai.com")

  loadRequiredConfig("OPENAI_API_KEY", "OPENAI_API_KEY", "api_key_cmd", function(key)
    Api.OPENAI_API_KEY = key

    loadOptionalConfig("OPENAI_API_TYPE", "OPENAI_API_TYPE", "api_type_cmd", function(type)
      if type == "azure" then
        loadAzureConfigs()
        Api.AUTHORIZATION_HEADER = "api-key: " .. Api.OPENAI_API_KEY
      else
        Api.AUTHORIZATION_HEADER = "Authorization: Bearer " .. Api.OPENAI_API_KEY
      end
    end, "")
  end)
end

function Api.exec(cmd, args, on_stdout_chunk, on_complete, should_stop, on_stop)
  local stdout = vim.loop.new_pipe()
  local stderr = vim.loop.new_pipe()
  local stderr_chunks = {}

  local handle, err
  local function on_stdout_read(_, chunk)
    if chunk then
      vim.schedule(function()
        if should_stop and should_stop() then
          if handle ~= nil then
            handle:kill(2) -- send SIGINT
            stdout:close()
            stderr:close()
            handle:close()
            on_stop()
          end
          return
        end
        on_stdout_chunk(chunk)
      end)
    end
  end

  local function on_stderr_read(_, chunk)
    if chunk then
      table.insert(stderr_chunks, chunk)
    end
  end

  handle, err = vim.loop.spawn(cmd, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    stdout:close()
    stderr:close()
    if handle ~= nil then
      handle:close()
    end

    vim.schedule(function()
      if code ~= 0 then
        on_complete(vim.trim(table.concat(stderr_chunks, "")))
      end
    end)
  end)

  if not handle then
    on_complete(cmd .. " could not be started: " .. err)
  else
    stdout:read_start(on_stdout_read)
    stderr:read_start(on_stderr_read)
  end
end

return Api
