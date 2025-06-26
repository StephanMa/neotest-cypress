---@diagnostic disable: undefined-field
local async = require("neotest.async")
local logger = require("neotest.logging")
local util = require("neotest-cypress.util")
local lib = require("neotest.lib")

---@class neotest.CypressOptions
---@field cypressCommand? string|fun(): string
---@field env? table<string, string>|fun(): table<string, string>
---@field cwd? string|fun(): string
---@field strategy_config? table<string, unknown>|fun(): table<string, unknown>

---@type neotest.Adapter
local adapter = { name = "neotest-cypress" }

local rootPackageJson = vim.fn.getcwd() .. "/package.json"
-- check if os is windows
local is_windows = uv.os_uname().version:match("Windows")

local getCypressCommand = function(path)

  -- if os is windows, use command cypress; otherwise use npx cypress
  if is_windows then
    return = "cypress"
  else
    return "npx cypress"
  end
  
end

local function getEnv(specEnv)
  return specEnv
end

---@param path string
---@return string|nil
local function getCwd(path)
  return nil
end

local function getStrategyConfig(default_strategy_config, args)
  return default_strategy_config
end

local function get_default_strategy_config(strategy, command, cwd)
  local config = {
    dap = function()
      return {
        name = "Debug Cypress Tests",
        type = "pwa-node",
        request = "launch",
        args = { unpack(command, 2) },
        runtimeExecutable = command[1],
        console = "integratedTerminal",
        internalConsoleOptions = "neverOpen",
        rootPath = "${workspaceFolder}",
        cwd = cwd or "${workspaceFolder}",
      }
    end,
  }
  if config[strategy] then
    return config[strategy]()
  end
end

local function cleanAnsi(s)
  return s:gsub("\x1b%[%d+;%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+m", "")
    :gsub("\x1b%[%d+m", "")
end

local function findErrorPosition(file, errStr)
  -- Look for: /path/to/file.js:123:987
  local regexp = file:gsub("([^%w])", "%%%1") .. "%:(%d+)%:(%d+)"
  local _, _, errLine, errColumn = string.find(errStr, regexp)

  return errLine, errColumn
end

local function parsed_json_to_results(data, output_file, consoleOut)
  local tests = {}

  for _, testResult in pairs(data.testResults) do
    local testFn = testResult.name
    for _, assertionResult in pairs(testResult.assertionResults) do
      local status, name = assertionResult.status, assertionResult.title

      if name == nil then
        logger.error("Failed to find parsed test result ", assertionResult)
        return {}
      end

      local keyid = testFn

      for _, value in ipairs(assertionResult.ancestorTitles) do
        keyid = keyid .. "::" .. value
      end

      keyid = keyid .. "::" .. name

      if status == "pending" then
        status = "skipped"
      end

      tests[keyid] = {
        status = status,
        short = name .. ": " .. status,
        output = consoleOut,
        location = assertionResult.location,
      }

      if not vim.tbl_isempty(assertionResult.failureMessages) then
        local errors = {}

        for i, failMessage in ipairs(assertionResult.failureMessages) do
          local msg = cleanAnsi(failMessage)
          local errorLine, errorColumn = findErrorPosition(testFn, msg)

          errors[i] = {
            line = (errorLine or assertionResult.location.line) - 1,
            column = (errorColumn or 1) - 1,
            message = msg,
          }

          tests[keyid].short = tests[keyid].short .. "\n" .. msg
        end

        tests[keyid].errors = errors
      end
    end
  end

  return tests
end

adapter.root = function(path)
  return lib.files.match_root_pattern("package.json")(path)
end

function adapter.filter_dir(name)
  return name ~= "node_modules"
end

---@return boolean
local function rootProjectHasCypressDependency()
  local path = rootPackageJson

  local success, packageJsonContent = pcall(lib.files.read, path)
  if not success then
    print("cannot read package.json")
    return false
  end

  local parsedPackageJson = vim.json.decode(packageJsonContent)

  if parsedPackageJson["dependencies"] then
    for key, _ in pairs(parsedPackageJson["dependencies"]) do
      if key == "cypress" then
        return true
      end
    end
  end

  if parsedPackageJson["devDependencies"] then
    for key, _ in pairs(parsedPackageJson["devDependencies"]) do
      if key == "cypress" then
        return true
      end
    end
  end

  return false
end

---@param path string
---@return boolean
local function hasCypressDependency(path)
  local rootPath = lib.files.match_root_pattern("package.json")(path)

  if not rootPath then
    return false
  end

  local success, packageJsonContent = pcall(lib.files.read, rootPath .. "/package.json")
  if not success then
    print("cannot read package.json")
    return false
  end

  local parsedPackageJson = vim.json.decode(packageJsonContent)

  if parsedPackageJson["dependencies"] then
    for key, _ in pairs(parsedPackageJson["dependencies"]) do
      if key == "cypress" then
        return true
      end
    end
  end

  if parsedPackageJson["devDependencies"] then
    for key, _ in pairs(parsedPackageJson["devDependencies"]) do
      if key == "cypress" then
        return true
      end
    end
  end

  if parsedPackageJson["scripts"] then
    for _, value in pairs(parsedPackageJson["scripts"]) do
      if value == "cypress" then
        return true
      end
    end
  end

  return rootProjectHasCypressDependency()
end

---@param file_path? string
---@return boolean
function adapter.is_test_file(file_path)
  if file_path == nil then
    return false
  end
  local is_test_file = false

  for _, x in ipairs({ "cy" }) do
    for _, ext in ipairs({ "js", "jsx", "ts", "tsx" }) do
      if string.match(file_path, "%." .. x .. "%." .. ext .. "$") then
        is_test_file = true
        goto matched_pattern
      end
    end
  end
  ::matched_pattern::
  return is_test_file and hasCypressDependency(file_path)
end

---@async
---@return neotest.Tree | nil
function adapter.discover_positions(path)
  local query = [[
    ; -- Namespaces --
    ; Matches: `describe('context', () => {})`
    ((call_expression
      function: (identifier) @func_name (#eq? @func_name "describe")
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe('context', function() {})`
    ((call_expression
      function: (identifier) @func_name (#eq? @func_name "describe")
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition
    ; Matches: `describe.only('context', () => {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe.only('context', function() {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition

    ; -- Tests --
    ; Matches: `it('test')`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "it")
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `it.only('test')`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "it")
      )
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
  ]]

  local positions = lib.treesitter.parse_positions(path, query, {
    nested_tests = false,
  })

  return positions
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function adapter.build_spec(args)
  local results_path = async.fn.tempname() .. ".json"
  local tree = args.tree

  if not tree then
    return
  end

  local pos = args.tree:data()

  local binary = args.cypressCommand or getCypressCommand(pos.path)
  local command = vim.split(binary, "%s+")

  local reporterOutputOption = "output=" .. results_path

  vim.list_extend(command, {
    "--quiet",
    "--spec=" .. vim.fs.normalize(pos.path),
    "--reporter=json",
    "--reporter-options=" .. reporterOutputOption,
  })

  local cwd = getCwd(pos.path)

  -- creating empty file for streaming results
  lib.files.write(results_path, "")
  local stream_data, stop_stream = util.stream(results_path)

  return {
    command = command,
    cwd = cwd,
    context = {
      results_path = results_path,
      file = pos.path,
      stop_stream = stop_stream,
    },
    stream = function()
      return function()
        local new_results = stream_data()
        local ok, parsed = pcall(vim.json.decode, new_results, { luanil = { object = true } })

        if not ok or not parsed.testResults then
          return {}
        end

        return parsed_json_to_results(parsed, results_path, nil)
      end
    end,
    strategy = getStrategyConfig(
      get_default_strategy_config(args.strategy, command, cwd) or {},
      args
    ),
    env = getEnv(args[2] and args[2].env or {}),
  }
end

---@async
---@param spec neotest.RunSpec
---@return neotest.Result[]
function adapter.results(spec, b, tree)
  spec.context.stop_stream()

  local output_file = spec.context.results_path

  local success, data = pcall(lib.files.read, output_file)

  if not success then
    logger.error("No test output file found ", output_file)
    return {}
  end

  local ok, parsed = pcall(vim.json.decode, data, { luanil = { object = true } })

  if not ok then
    logger.error("Failed to parse test output json ", output_file)
    return {}
  end

  local results = parsed_json_to_results(parsed, output_file, b.output)

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(adapter, {
  ---@param opts neotest.CypressOptions
  __call = function(_, opts)
    if is_callable(opts.cypressCommand) then
      getCypressCommand = opts.cypressCommand
    elseif opts.cypressCommand then
      getCypressCommand = function()
        return opts.cypressCommand
      end
    end
    if is_callable(opts.env) then
      getEnv = opts.env
    elseif opts.env then
      getEnv = function(specEnv)
        return vim.tbl_extend("force", opts.env, specEnv)
      end
    end
    if is_callable(opts.cwd) then
      getCwd = opts.cwd
    elseif opts.cwd then
      getCwd = function()
        return opts.cwd
      end
    end
    if is_callable(opts.strategy_config) then
      getStrategyConfig = opts.strategy_config
    elseif opts.strategy_config then
      getStrategyConfig = function()
        return opts.strategy_config
      end
    end

    return adapter
  end,
})

return adapter
