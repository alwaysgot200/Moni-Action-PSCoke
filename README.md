# Moni-Action-PSCoke

Moni 的第三方动作示例（类 PSCoke）：**在浏览器里拾取图片 → 下载 → 放入 Photoshop 当前文档**，
按网格或整幅画布排布，保持智能对象，可继续缩放/替换素材。

本仓库包含：

- Moni 动作（Lua）与选项 schema；
- 动作自带的 Photoshop 脚本（ExtendScript / JSX）；
- 动作自己的「设置 PS 脚本」入口（`setup.lua`）；
- 纯 JS 单元测试（`node --test`）。

> 设计原则：**外部软件的安装/检查是动作自己的工作，不是 Moni 的工作。**
> Moni 只提供通用能力：浏览器桥（`ctx.bridge.call`）与按 `action.json` 的 `programs`
> 启动外部程序（`ctx.process.run`）+ 临时工作目录（`ctx.fs.*`）。

## 前置条件

1. **Moni-Connector 浏览器扩展**已安装、已与 Moni 配对，Moni 首页浏览器桥显示已连接；
2. **Photoshop 22.0+**，建议先启动并打开一个文档；
3. 在本动作的设置里点击 **「设置 PS 脚本」**，把 `pscoke.jsx` 安装到
   `Presets/Scripts/Moni/ps.browser-image-to-layer/`。

运行时会按顺序检查：浏览器桥在线 → PS 脚本已安装。任一缺失就提示并中止，
不会在用户不知情的情况下尝试安装。

## 工作流程

```
检查 browser 桥（未连接 → A406_BROWSER_OFFLINE，提示安装 Moni-Connector）
  └─ 检查 pscoke.jsx 是否已安装（未安装 → A500_ACTION_FAILED + hint，提示去动作设置）
       └─ 拾取/查询/右键图片 → ctx.http.download（带页面 Cookie/Referer）
            └─ ctx.asset.path 取本地路径 → 自带 runner 执行 ps/pscoke.jsx
                 └─ PS 当前文档：placeEvent 智能对象 + 网格/画布排布 + 组 + 一次撤销
```

## 选项

| 选项 | 取值 | 说明 |
|---|---|---|
| `mode` | `picker` / `selector` / `context` | 点选 / CSS 选择器批量 / 最近一次右键图片 |
| `selector` | CSS 选择器 | `mode=selector` 时使用 |
| `min_width` / `min_height` | 像素 | 过滤小图标 |
| `limit` | 1–200 | 最多采集数量 |
| `scroll` | 布尔 | 查询前先滚动加载懒加载图片 |
| `layout` | `grid` / `layers` | 网格排布 / 每张占满画布 |
| `columns` | 1–8 | 网格列数 |
| `gap` | 0–400 | 边距与间距（像素） |
| `fit` | `contain` / `original` | 等比缩放到单元内 / 保持原始尺寸 |
| `group` | 布尔 | 是否把图层放进一个组 |

## 权限

| 权限 | 用途 |
|---|---|
| `bridge.call:browser` | 调用 Moni-Connector 的元素拾取接口 |
| `net.fetch` | 下载图片 |
| `asset` | 把下载结果落到本地工件库并取路径 |
| `process.spawn:photoshop` | 启动 `programs.photoshop`（Windows：`Photoshop.exe -r runner.jsx`） |
| `process.spawn:osascript` | 启动 `programs.osascript`（macOS：`do javascript`） |

不申请 `bridge.call:photoshop`——Photoshop 侧完全走本地 JSX，不再需要 UXP 插件或 PS 桥。

## JSX 契约

```js
function moniRun(job) {
  // job.params = { assets:[{path,name}], layout, columns, gap, fit, group, group_name }
  return { layers: [{ id, name }], warnings: [] };
}
```

- 抛错用 `throw { code: "A401_PS_NO_DOC", message: "..." }`；
- 放置图片使用 `executeAction(charIDToTypeID("Plc "), ...)`，得到的是智能对象；
- 整批操作包在 `doc.suspendHistory(...)` 中，一次 Ctrl+Z 撤回。

## 开发与测试

```bash
node --test "tests/**/*.test.mjs"
```

测试通过 Node `vm` 加载 `ps/pscoke.jsx` 里的纯函数（网格计算、画布单元、图层命名），
不依赖 Photoshop。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `A406_BROWSER_OFFLINE` | Moni-Connector 未安装/未配对/未连接，先在浏览器启用扩展并配对 |
| `A500_ACTION_FAILED` + hint「还没有安装 Photoshop 脚本」 | 动作设置 →「设置 PS 脚本」 |
| `A407_PS_OFFLINE` | 找不到 Photoshop；启动一次，或让动作 `programs.photoshop.candidates` 覆盖你的安装路径 |
| `A404_NO_ELEMENTS` | 用户没选中图片 |
| `A405_DOWNLOAD_FAILED` | 图片需要登录/防盗链；确认 `use_browser_cookies` 生效 |
| 图片大小不一致 | `fit=contain` 会等比缩放到单元内；要原尺寸选 `original` |

## 许可

MIT
