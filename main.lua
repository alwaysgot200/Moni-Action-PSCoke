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
local MAX_POLLS = 450 -- 约 45s：由动作启动 PS 时含冷启动
local PROBE_POLLS = 30 -- 已在运行时 3s 内必须响应，否则判定通道不通
local LAUNCH_POLLS = 450 -- 等进程出现最多 45s（PS 冷启动较慢）

-- 依赖软件是否在运行：只问宿主「进程在不在」，不涉及权限或软件语义。
local function app_online(ctx)
  local ok, info = pcall(ctx.process.inspect, "photoshop")
  return ok and type(info) == "table" and info.running == true
end

-- 前置条件：Photoshop 在线，不在线时按动作选项决定是否由宿主启动。
local function ensure_app(ctx)
  if app_online(ctx) then
    return false, nil
  end
  if ctx.options.launch_app == false then
    return false, {
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_not_running"),
      hint = ctx.t("hint.ps_not_running"),
    }
  end
  ctx.notify(ctx.t("notice.launching_ps"))
  local started, err = pcall(ctx.process.run, "photoshop", {}, { wait = false })
  if not started then
    return false, {
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_launch_failed"),
      detail = tostring(err),
    }
  end
  for _ = 1, LAUNCH_POLLS do
    if app_online(ctx) then
      return true, nil
    end
    ctx.sleep(POLL_MS)
  end
  return false, { code = "A407_PS_OFFLINE", message = ctx.t("error.ps_launch_timeout") }
end

-- 写 job → 启动 runner → 轮询 result.json；返回脚本的 value，失败则抛出结构化错误。
local function run_jsx(ctx, script, params, max_polls)
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
    -- Windows 的 -r 在已运行的 Photoshop 进程里执行，进程环境变量传不过去；
    -- 把路径写进一次性包装脚本，由它设置全局变量后再调用 runner。
    local wrapper = "$.global.__MONI_JOB='" .. job_path:gsub("\\", "/") .. "';"
      .. "$.global.__MONI_SCRIPT='" .. script_path:gsub("\\", "/") .. "';"
      .. "$.global.__MONI_RESULT='" .. result_path:gsub("\\", "/") .. "';"
      .. "$.evalFile('" .. runner_path:gsub("\\", "/") .. "');"
    ctx.fs.write("runner_wrapper.jsx", wrapper)
    ctx.process.run("photoshop", { "-r", ctx.fs.path("runner_wrapper.jsx") }, { wait = false })
  end

  for _ = 1, max_polls or MAX_POLLS do
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
  local ok, list = pcall(ctx.bridge.list)
  if not ok or type(list) ~= "table" then
    return false
  end
  -- ctx.bridge.list() 返回 `{bridges=[{name,online,...}]}`，不是数组本身。
  for _, bridge in ipairs(list.bridges or {}) do
    if bridge.name == "browser" and bridge.online then
      return true
    end
  end
  return false
end

local function ps_script_installed(ctx, max_polls)
  local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
    mode = "check",
    action_id = ACTION_ID,
    file_name = SCRIPT_NAME,
  }, max_polls)
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

  local launched, offline = ensure_app(ctx)
  if offline then
    return {
      ok = false,
      code = offline.code,
      message = offline.message,
      hint = offline.hint,
      detail = offline.detail,
    }
  end

  -- 进程在跑却 3s 无响应：脚本通道被阻塞（PS 弹窗/反射未就绪）或进程假死，提示重启 PS。
  local installed, failure = ps_script_installed(ctx, launched and MAX_POLLS or PROBE_POLLS)
  if failure then
    if failure.code == "A501_TIMEOUT" then
      return {
        ok = false,
        code = "A407_PS_OFFLINE",
        message = ctx.t("error.ps_comm_failed"),
        hint = ctx.t("hint.ps_comm_failed"),
      }
    end
    return {
      ok = false,
      code = "A407_PS_OFFLINE",
      message = ctx.t("error.ps_unavailable"),
      detail = tostring(failure.message or failure),
    }
  end
  if not installed then
    -- 用户只点「运行」：脚本没装就由动作自己装到 PS 脚本目录，下次运行只做检查。
    ctx.notify(ctx.t("notice.installing_script"))
    local ok, state = pcall(run_jsx, ctx, "setup.jsx", {
      mode = "install",
      action_id = ACTION_ID,
      file_name = SCRIPT_NAME,
    }, MAX_POLLS)
    if not ok or type(state) ~= "table" or state.installed ~= true then
      return {
        ok = false,
        code = "A500_ACTION_FAILED",
        message = ctx.t("error.ps_setup_required"),
        hint = ctx.t("hint.ps_setup_required"),
        detail = tostring(ok and "install reported not installed" or state),
      }
    end
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
