-- 动作自己的「设置 PS」入口：由 Moni 的动作设置页调用（manifest.setup）。
-- 安装逻辑全部在 ps/setup.jsx 里；本文件只负责前置条件、写 job、启动 runner、读结果。

local POLL_MS = 100
local MAX_POLLS = 450 -- 约 45s（PS 冷启动时脚本引擎就绪较慢）
local PROBE_POLLS = 30 -- 已在运行时 3s 内必须响应
local LAUNCH_POLLS = 450

local function app_online(ctx)
  local ok, info = pcall(ctx.process.inspect, "photoshop")
  return ok and type(info) == "table" and info.running == true
end

-- 与运行期一致的前置条件：PS 在线（必要时按选项启动），否则立即给出可读原因。
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

function setup(ctx)
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

  ctx.fs.remove("result.json")
  ctx.fs.write("job.json", ctx.json.encode({
    version = 1,
    params = {
      mode = "install",
      action_id = "ps.browser-image-to-layer",
      file_name = "pscoke.jsx",
    },
  }))
  local job_path = ctx.fs.path("job.json")
  local result_path = ctx.fs.path("result.json")
  local script_path = ctx.action_dir .. "/ps/setup.jsx"
  local runner_path = ctx.action_dir .. "/ps/runner.jsx"

  if ctx.platform == "macos" then
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

  for _ = 1, launched and MAX_POLLS or PROBE_POLLS do
    if ctx.fs.exists("result.json") then
      local out = ctx.json.decode(ctx.fs.read("result.json"))
      if out.ok then
        local value = out.value or {}
        return {
          ok = true,
          installed = value.installed == true,
          paths = value.paths or {},
        }
      end
      local failure = out.error or {}
      return {
        ok = false,
        code = failure.code or "A500_ACTION_FAILED",
        message = failure.message or ctx.t("error.ps_unavailable"),
      }
    end
    ctx.sleep(POLL_MS)
  end

  return {
    ok = false,
    code = "A407_PS_OFFLINE",
    message = ctx.t("error.ps_comm_failed"),
    hint = ctx.t("hint.ps_comm_failed"),
  }
end
