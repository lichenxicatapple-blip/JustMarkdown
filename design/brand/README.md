# MarkdownIt! 品牌资源

图形和配色集中维护在本目录：

| 维护源 | 内容 |
| --- | --- |
| `mark.svg` | 唯一矢量母版；纸页、`.md` 排版与卷页分组，画布紧贴纸页边界 |
| `brand.json` | 墨色、浅深色背景渐变、系统图标画布与首页图标圆角 |

标志为印有 `.md` 后缀和三行正文的白色纸页，右下角翻起。文字已转为路径，不依赖字体；墨色通过 `currentColor` 绑定配色，纸张与卷页的色阶在母版中维护。定稿参考见 `approved-reference.png`。

## 生成与检查

修改母版或配色后，在仓库根目录运行现有资源命令：

```sh
python3 scripts/build_native_web.py
python3 scripts/build_native_web.py --check
```

该命令调用 `scripts/build_brand_assets.swift`，用 macOS AppKit 生成 1024 × 1024、sRGB PNG，并统一生成以下资源。生成文件随源码提交；不要手动修改。

| 生成位置（仓库根目录下） | 内容 |
| --- | --- |
| `design/brand/production/` | 透明纸页标志、浅深色 App 图标、Icon Composer 图标包及导出清单 |
| `MarkdownIt/Assets.xcassets/BrandMark.imageset` | 包含背景的浅深色首页矢量与资源描述；保留原始颜色 |

`--check` 重新生成并比较所有资源，遗漏更新、直接修改或遗留文件都会使检查失败。CI 和模拟器验证复用同一入口。

Icon Composer 图标包从母版生成纸页、排版和卷页三层，背景渐变取自同一配色。在 Icon Composer 中核对 `production/MarkdownIt.icon` 的浅色、深色与着色外观；调整回到母版与配色。系统图标不包含外部白边或圆角遮罩，由系统处理外形；首页矢量包含独立的圆角背景。
