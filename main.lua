-- Moni 动作「网页图片采集入 PS」：浏览器拾取图片 → 下载 → 放进 Photoshop。
--
-- 前置条件由动作自己检查：
--   1) 浏览器桥（Moni-Connector）是否在线；
--   2) 动作自带的 Photoshop 脚本是否已安装（由本动作的 setup 入口安装）。
-- Moni 只提供通用能力，不负责安装浏览器扩展或 PS 脚本。
--
-- PS 调用同样属于动作：自带 ps/runner.jsx，经 ctx.process.run 启动
-- manifest 声明过的 Photoshop（macOS 为 osascript）。

local ACTION_ID = "ps.browser-image-to-layer"
local SCRIPT_NAME = "pscoke.jsx"
local POLL_MS = 100
local MAX_POLLS = 400 -- 约 40s

-- 写 job → 启动 runner → 轮询 result.json；返回脚本的 value，失败则抛出结构化错误。
local function run_jsx(ctx, script, params)
  ctx.fs.remove("result.json")
  ctx.fs.write("job.json", ctx.json.encode({ version = 1, params = params }))
  local job_path = ctx.fs.path("job.json")
  local result_path = ctx.fs.path("result.json")
  local script_path = ctx.action_dir .. "/ps/" .. script
  local runner_path = ctx.action_dir .. "/ps/runner.jsx"

  if ctx.platform == "macos" then
    -- osascript 的环境变量不会传给 Photoshop，用 do javascript 注入 $.global。
    local inline = "__MONI_JOB='" .. job_path .. "';"
      .. "__MONI_SCRIPT='" .. script_path .. "';"
      .. "__MONI_RESULT='" .. result_path .. "';"
      .. "$.evalFile('" .. runner_path .. "');"
    ctx.process.run("osascript", {
      "-e",
      'tell application id "com.adobe.Photoshop" to do javascript "' .. inline .. '"',
    }, { wait = false })
  else
    ctx.process.run("photoshop", { "-r", runner_path }, {
      env = {
        MONI_JOB = job_path,
        MONI_SCRIPT = script_path,
        MONI_RESULT = result_path,
      },
      wait = false,
    })
  end

  for _ = 1, MAX_POLLS do
    if ctx.fs.exists("result.json") then
      local out = ctx.json.decode(ctx.fs.read("result.json"))
      if out.ok then
        return out.value or {}
      end
      local failure = out.error or {}
      error({
        code = failure.code or "A500_ACTION_FAILED",
        message = failure.message or ctx.t("error.ps_unavailable"),
      })
    end
    ctx.sleep(POLL_MS)
  end
  error({ code = "A501_TIMEOUT", message = ctx.t("error.ps_unavailable") })
end

local function dedupe(elements)
  local seen, out = {}, {}
  for _, element in ipairs(elements or {}) do
    local key = element.url
    if key and not seen[key] then
      seen[key] = true
      out[#out + 1] = element
    end
  end
  return out
end

local function browser_connected(ctx)
  local ok, bridges = pcall(ctx.bridge.list)
  if not ok or type(bridges) ~= "table" then
    return false
  end
  for _, bridge in ipairs(bridges) do
    if bridge.name == "browser" and bridge.connected then
      return true
    end
  end
  return false
end

local function ps_script_installed(ctx)
  local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
    mode = "check",
    action_id = ACTION_ID,
    file_name = SCRIPT_NAME,
  })
  if not ok then
    return false, state
  end
  return state ~= nil and state.installed == true, nil
end

local function element_name(element, index)
  local name = element and element.alt
  if not name or name == "" then
    local url = (element and element.url) or ""
    name = url:match("([^/?#]+)[^/?#]*$")
  end
  if not name or name == "" then
    name = "image-" .. index
  end
  return name
end

function run(ctx)
  if not browser_connected(ctx) then
    return {
      ok = false,
      code = "A406_BROWSER_OFFLINE",
      message = ctx.t("error.browser_offline"),
      hint = ctx.t("hint.browser_offline"),
    }
  end

  local installed, failure = ps_script_installed(ctx)
  if failure then
    return {
      ok = false,
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_unavailable"),
      detail = tostring(failure.message or failure),
    }
  end
  if not installed then
    return {
      ok = false,
      code = "A500_ACTION_FAILED",
      message = ctx.t("error.ps_setup_required"),
      hint = ctx.t("hint.ps_setup_required"),
    }
  end

  local opt = ctx.options
  local elements
  if opt.mode == "context" then
    elements = ctx.bridge.call("browser", "elements.from_context", {})
  elseif opt.mode == "selector" then
    elements = ctx.bridge.call("browser", "elements.query", {
      selector = opt.selector,
      min_width = opt.min_width,
      min_height = opt.min_height,
      limit = opt.limit,
      scroll = opt.scroll,
    })
  else
    elements = ctx.bridge.call("browser", "elements.pick", {
      multiple = true,
      hint = ctx.t("hint.pick_images"),
    })
  end

  elements = dedupe(elements)
  if #elements == 0 then
    return { ok = false, code = "A404_NO_ELEMENTS", message = ctx.t("error.no_elements") }
  end

  local assets, failures = {}, {}
  for index, element in ipairs(elements) do
    if ctx.cancelled() then
      return { ok = false, code = "A502_CANCELLED", message = ctx.t("error.cancelled") }
    end
    ctx.progress((index - 1) / #elements, ctx.t("progress.download", index, #elements))

    local ok, asset = pcall(ctx.http.download, element.url, {
      referer = element.page_url,
      use_browser_cookies = true,
      max_bytes = 30 * 1024 * 1024,
      timeout_ms = 20000,
    })
    if ok and asset and asset.asset then
      local path_ok, path = pcall(ctx.asset.path, asset.asset)
      if path_ok and path then
        assets[#assets + 1] = {
          path = path,
          name = element_name(element, index),
          url = element.url,
        }
      else
        failures[#failures + 1] = { url = element.url, error = tostring(path) }
      end
    else
      failures[#failures + 1] = { url = element.url, error = tostring(asset) }
      ctx.log("warn", "download.failed", { index = index })
    end
  end

  if #assets == 0 then
    return {
      ok = false,
      code = "A405_DOWNLOAD_FAILED",
      message = ctx.t("error.download_all_failed"),
      failures = failures,
    }
  end

  ctx.progress(0.7, ctx.t("progress.place", #assets))
  local placed = run_jsx(ctx, SCRIPT_NAME, {
    assets = assets,
    layout = opt.layout,
    columns = opt.columns,
    gap = opt.gap,
    fit = opt.fit,
    group = opt.group,
    group_name = "Moni Collect " .. ctx.run_id,
    run_id = ctx.run_id,
  })

  return {
    ok = true,
    assets = assets,
    layers = placed.layers,
    failures = failures,
  }
end
