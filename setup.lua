-- 动作自己的「设置 PS」入口：由 Moni 的动作设置页调用（manifest.setup）。
-- 安装逻辑全部在 ps/setup.jsx 里；本文件只负责写 job、启动 runner、读结果。

function setup(ctx)
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
    ctx.process.run("photoshop", { "-r", runner_path }, {
      env = {
        MONI_JOB = job_path,
        MONI_SCRIPT = script_path,
        MONI_RESULT = result_path,
      },
      wait = false,
    })
  end

  for _ = 1, 400 do
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
    ctx.sleep(100)
  end

  return {
    ok = false,
    code = "A501_TIMEOUT",
    message = ctx.t("error.ps_unavailable"),
    hint = ctx.t("hint.ps_setup_required"),
  }
end
