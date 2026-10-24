# JustMarkdown 品牌资源

字形和配色集中维护在本目录：

| 维护源 | 内容 |
| --- | --- |
| `mark.svg` | 唯一字形母版；填充使用 `currentColor`，画布紧贴图形边界 |
| `brand.json` | 首页与 App 图标共用的浅色、深色配色，以及图标画布 |

标志为小写 `.md` 合字，不依赖字体。竖笔以 98 为粗细基准，d 的字腹上下沿为 88；m、d 的字宽比例约为 1.25∶1，共用基线和端部圆角。
字形设计参考见 `approved-reference.png`。

## 生成与检查

修改母版或配色后，在仓库根目录运行现有资源命令：

```sh
python3 scripts/build_native_web.py
python3 scripts/build_native_web.py --check
```

该命令调用 `scripts/build_brand_assets.swift`，用 macOS AppKit 生成 1024 × 1024、sRGB PNG，并统一生成以下资源。生成文件随源码提交；不要手动修改。

| 生成位置（仓库根目录下） | 内容 |
| --- | --- |
| `design/brand/production/` | 透明标志、黑白版本、浅深色 App 图标、Icon Composer 图标包及导出清单 |
| `JustMarkdown/Assets.xcassets/BrandMark.imageset` | 首页模板矢量与资源描述 |
| `JustMarkdown/Assets.xcassets/BrandMarkTint.colorset` | 首页浅深色配色 |

`--check` 重新生成并比较所有资源，遗漏更新、直接修改或遗留文件都会使检查失败。CI 和模拟器验证复用同一入口。

在 Icon Composer 中核对 `production/JustMarkdown.icon` 的浅色、深色与着色外观；调整回到母版与配色。输入不烘焙圆角、阴影或高光，由系统处理外形。
